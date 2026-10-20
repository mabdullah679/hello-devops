# hello-devops

A small Python HTTP service with health/readiness probes and a token-protected "break / recover" switch, deployed to AWS (ECS Fargate behind an ALB) by Terraform and a GitHub Actions pipeline that authenticates with OIDC (no stored AWS keys).

Pipeline spec followed: lint/test/build -> `terraform fmt/validate/plan` -> apply -> smoke test (`.github/workflows/ci.yml`, `.github/workflows/cd.yml`).

## How it runs

```
 git push (prod-hardening)
        |
        v
 GitHub Actions --OIDC--> IAM role pf-hello-devops-github-deploy (trust: this repo + this branch only)
   ci: ruff, unittest, docker build+probe, terraform validate
   cd: build image -> ECR (tag = git sha) -> terraform plan -> apply -> smoke test
        |
        v
 internet --:80--> ALB (2 AZs) --:8080--> ECS Fargate tasks x2 (public subnets, SG admits ALB only)
                    health check /readyz     |  logs  -> CloudWatch Logs /ecs/pf-hello-devops
                                             |  secret-> SSM SecureString /pf-hello-devops/admin-token
                                             +  flag  -> SSM String       /pf-hello-devops/chaos
 EventBridge (1/min) -> Lambda synthetic check -> GET ALB/healthz -> metric Up
 CloudWatch alarms (5xx, unhealthy targets, synthetic down) -> SNS topic
```

Not contained in this repo: an AWS account with the GitHub OIDC provider and the `portfolio-ci-boundary` IAM policy already created (both were pre-provisioned and are only referenced here), and a GitHub repository to run the pipeline.

## Prerequisites

- Local app and tests: Python 3.13 (3.12 also runs the tests). No packages are needed to run the tests; `boto3` is only needed for the SSM chaos store in AWS.
- Lint: `pip install -r requirements-dev.txt` (ruff).
- Container: Docker.
- AWS side (only for deploying): AWS CLI authenticated to account 346208529954, Terraform >= 1.10 (the S3 backend uses `use_lockfile`; the pipeline pins 1.13.5), `gh`.
- Not needed on the host: a Terraform install for the pipeline path, any AWS access keys (CI uses OIDC).
- Region ap-southeast-2. Everything is named with the prefix `pf-hello-devops` and tagged `project=portfolio`, `repo=hello-devops`, `managed-by=terraform`.

## Run it

Locally:

1. `make test` (17 unit tests).
2. `make run` (server on `:8080`, admin token `local`, chaos flag kept in memory).
3. `curl -i localhost:8080/healthz`

In a container: `docker build -t hello-devops . && docker run --rm -p 8080:8080 -e ADMIN_TOKEN=local hello-devops`

On AWS:

1. Once per account: `make bootstrap` (state bucket, ECR repo, the OIDC deploy role; applied by hand because the pipeline needs these to exist before it can run).
2. Push to `prod-hardening` (or `make rebuild`) and the `cd` workflow builds, plans, applies and smoke-tests.
3. Break and recover (needs AWS CLI access to read the admin token from SSM; the token is never printed):
   - macOS/Linux: `./mac-scripts/break.sh`, `./mac-scripts/recover.sh`, `./mac-scripts/status.sh`, `./mac-scripts/logs.sh`
   - Windows PowerShell: `win-scripts\break.ps1`, `recover.ps1`, `status.ps1`, `logs.ps1` (written to mirror the shell scripts; not run on Windows)
4. Tear down: `make destroy`, then `make destroy-bootstrap` last.

## What it does

| Action | Expected result |
|---|---|
| `GET /` | 200 JSON: service, version (git sha in AWS), status `ok` or `degraded`, uptime |
| `GET /livez` | 200 while the process answers (used by the container health check) |
| `GET /healthz` | 200 normally, 503 while chaos mode is "broken" |
| `GET /readyz` | 200 normally, 503 while broken or while draining after SIGTERM (used by the ALB) |
| `POST /admin/chaos {"state":"break"}` with the bearer token | 200, every task starts failing health |
| `POST /admin/chaos {"state":"recover"}` with the bearer token | 200, health returns |
| Admin call with no or wrong token | 401; with no token configured on the server 503 |
| Malformed JSON, unknown state, body over 1024 bytes | 400, 400, 413 |
| Unknown path / wrong method | 404 / 405 |
| SIGTERM | `/readyz` goes 503, 5 s drain, clean exit 0 |

## Interface

| Method | Path | Auth |
|---|---|---|
| GET, HEAD | `/`, `/livez`, `/healthz`, `/readyz` | none |
| GET | `/admin/chaos` | `Authorization: Bearer <ADMIN_TOKEN>` |
| POST | `/admin/chaos` | `Authorization: Bearer <ADMIN_TOKEN>` |

Configuration (environment): `PORT` (8080), `LOG_LEVEL` (INFO), `ADMIN_TOKEN` (unset disables the admin API), `CHAOS_SSM_PARAM` (unset = in-memory flag), `APP_VERSION`, `DRAIN_SECONDS` (5). See `.env.example`.

Every response carries `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`, `Cache-Control: no-store`, `Referrer-Policy` and an `X-Request-Id`. Logs are one JSON object per line.

## Tests

- `make test` or `python3 -m unittest discover -s tests -v`. 17 tests that start a real HTTP server on an ephemeral port with a fake SSM client. No AWS or network needed.
- Covered: probe semantics, break/recover round trip, auth, input validation, body limit, store outage, cache behaviour, security headers, JSON log shape, token never logged.
- Mutation-checked: each of these edits was applied to `app.py` and the suite went red, then the exact edit was reversed: auth check bypassed, `/healthz` ignoring chaos, `/readyz` ignoring draining, body limit removed, state validation removed, admin-open-when-no-token, security headers dropped (7 of 7 caught).
- CI additionally builds the image, runs it, probes `/livez` `/healthz` `/readyz` and asserts it does not run as root.

## Layout

| Path | Role |
|---|---|
| [`app.py`](app.py) | the service: routes, JSON logging, chaos store (memory / SSM), SIGTERM drain |
| [`tests/test_app.py`](tests/test_app.py) | unit and HTTP tests |
| [`Dockerfile`](Dockerfile) | multi-stage, non-root uid 10001, exec-form CMD, HEALTHCHECK on `/livez` |
| [`infra/network.tf`](infra/network.tf) | VPC, 2 public subnets, IGW, security groups (no NAT) |
| [`infra/alb.tf`](infra/alb.tf) | ALB, target group (health check `/readyz`), HTTP listener |
| [`infra/ecs.tf`](infra/ecs.tf) | cluster, task definition, service (rolling + circuit breaker), IAM roles, log group |
| [`infra/ssm.tf`](infra/ssm.tf) | admin token (SecureString, generated) and chaos flag |
| [`infra/monitoring.tf`](infra/monitoring.tf) | 3 alarms, SNS topic, synthetic-check Lambda + schedule |
| [`infra/lambda/synthetic.py`](infra/lambda/synthetic.py) | the synthetic check |
| [`infra/bootstrap/main.tf`](infra/bootstrap/main.tf) | state bucket, ECR, GitHub OIDC deploy role (local state) |
| [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`cd.yml`](.github/workflows/cd.yml) | the pipeline |
| [`mac-scripts/`](mac-scripts), [`win-scripts/`](win-scripts) | break / recover / status / logs |
| [`notes/aws-uptime-check.txt`](notes/aws-uptime-check.txt) | how the uptime check maps from the old GCP notes |
| [`Makefile`](Makefile) | test, run, bootstrap, rebuild, destroy |

## Design decisions

- **Chaos flag in SSM, not an env var or in-process.** Env var: changing it needs a redeploy and the old `REQUIRED_TOKEN=` trick no longer works on Fargate. In-process: with 2 tasks only one would break, and a replaced task would come back healthy. A shared SSM parameter breaks the whole service and survives task replacement. Cost: tasks cycle while broken (the ALB marks them unhealthy and ECS replaces them), which is visible in the evidence below.
- **Three probe endpoints.** `/livez` ignores chaos so ECS's container check does not kill a task for a deliberate break; `/healthz` and `/readyz` report it. Only `/readyz` also goes 503 while draining, so a stopping task leaves the load balancer first.
- **Chaos store failure keeps the last known value.** Failing open (treat an SSM outage as "broken") would let an AWS API blip take the service down.
- **No NAT gateway.** Tasks sit in public subnets with public IPs, but their security group only accepts port 8080 from the ALB's security group. A NAT would cost more per hour than the whole rest of the stack.
- **Plain HTTP only.** There is no domain or certificate, so the listener is port 80. This is a gap, not a choice for production.
- **ECR and state bucket live in a separate bootstrap stack.** The image must exist before ECS can start, and the pipeline's own role must exist before the pipeline can run, so these cannot be created by the pipeline itself.
- **Admin token generated by Terraform.** It therefore also exists in the (private, encrypted, versioned) state bucket. Rotating means `terraform taint random_password.admin_token`.
- **Deploy role scope.** EC2/ELB/ECS create calls cannot be limited to a resource ARN, so those are limited by region; IAM, SSM, Logs and Lambda are limited to the `pf-hello-devops` prefix, and created roles must carry the permissions boundary.

## Deployed on AWS

Verified 2026-10-20 (account 346208529954, ap-southeast-2).

- URL pattern: `http://pf-hello-devops-alb-<id>.ap-southeast-2.elb.amazonaws.com` (the ALB DNS name is regenerated on every rebuild).
- Pipeline: GitHub Actions run 39389376156 on `prod-hardening` (checks, build, deploy, smoke all green; `Plan: 40 to add`, `Apply complete! Resources: 40 added`), then run 39389403002 on the next commit, a second rolling deploy, also green. AWS auth was OIDC only. The bootstrap stack (state bucket, ECR, deploy role) was applied by hand locally, as it has to exist first.
- Smoke test output from the pipeline: `index: / -> 200`, `healthz: /healthz -> 200`, `readyz: /readyz -> 200`, admin without token `-> 401`, unknown path `-> 404`, `X-Content-Type-Options: nosniff` present, version in the body equals the git sha.
- curl from a laptop: `GET /` 200 with security headers, `/healthz` 200, `/readyz` 200, `/livez` 200, `/nope` 404, `/admin/chaos` without token 401.
- Break / recover run with `mac-scripts/break.sh` and `recover.sh` (times local, UTC+5):

| Time | Event | /healthz | ALB targets | Alarms |
|---|---|---|---|---|
| 13:03:50 | before | 200 | 2 healthy | all OK |
| 13:03:56 | `break.sh` -> `{"state": "broken"}` | 503 | healthy | OK |
| 13:04:24 | ~30 s later | 503 | 2 unhealthy, ECS starts replacements | OK |
| 13:05-13:07 | tasks keep being replaced, replacements also unhealthy | 503 | unhealthy / draining / initial | synthetic-down ALARM at 13:06:57 |
| 13:07:31 | | 503 | 2 unhealthy | 5xx, synthetic-down, unhealthy-targets all ALARM |
| 13:07:37 | `recover.sh` -> `{"state": "ok"}` | 200 | | |
| 13:09:29 | | 200 | 2 healthy | still ALARM (metrics lag) |
| 13:09:46 | | 200 | 2 healthy | synthetic-down OK |
| 13:10:36 | | 200 | 2 healthy | unhealthy-targets OK; 5xx later cleared (OK at last check) |

  The synthetic Lambda logged `{"up": 0, "reason": "status 503"}` during the break.
- Resources (40 in Terraform state): VPC, 2 subnets, IGW, route table, 2 security groups plus locked default SG, ALB + target group + listener, ECS cluster / task definition / service, 3 IAM roles + policies (all with the permissions boundary), 2 SSM parameters, 2 log groups, SNS topic, 3 alarms, Lambda + EventBridge rule/target/permission. Bootstrap adds: S3 state bucket, ECR repo + lifecycle policy, deploy role.
- Cost estimate (list-price arithmetic, not an invoice): ALB ~$0.03/h, 2 Fargate tasks (0.25 vCPU / 0.5 GB) ~$0.03/h, 4 public IPv4 addresses ~$0.02/h, the rest negligible: roughly $0.09/h, about $2.2/day.
- Teardown and rebuild: `make destroy` (stack) then `make destroy-bootstrap` (last). Rebuild: `make bootstrap` once, then `make rebuild`.

Not established: circuit-breaker rollback (it is configured in `infra/ecs.tf` but no failing deploy was pushed to watch it trigger); SNS email delivery (no subscriber); behaviour under load; the Windows scripts; any browser rendering (the service returns JSON only; all checks were curl).

## Secret hygiene

A `.env` file was committed in the original repo with one key, `REQUIRED_TOKEN`, whose value is a single digit flag, not a credential. It is now untracked and git-ignored; `.env.example` lists the current keys. It remains in git history.
