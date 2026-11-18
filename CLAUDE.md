# CLAUDE.md

Python 3 standard-library HTTP service (`app.py`, no web framework) with a break/recover "chaos" switch, deployed to AWS ECS Fargate behind an ALB by Terraform (`infra/`) and GitHub Actions (OIDC, no stored keys). Details and design decisions: `README.md`.
Global working rules: `~/.claude/CLAUDE.md` (not copied here).

## Commands (run and verified)
- `make test` (17 unittest tests, no network/AWS) and `make lint` (`pip install -r requirements-dev.txt`, ruff).
- `make run` serves on :8080 with admin token `local`.
- Container: `docker build -t hello-devops .`; CI runs it and probes `/livez`, `/healthz`, `/readyz`.
- `make bootstrap`, `make rebuild`, `make destroy`, `make destroy-bootstrap` touch real AWS (account in `infra/versions.tf`). Do not run them without the owner's explicit yes: they provision or delete cloud resources and cost money.

## Conventions
- A logic change in `app.py` needs a test seen failing first (mutate the guard, watch red, reverse the exact edit). The README lists the 7 guards that were mutation-checked.
- Terraform is formatted (`terraform fmt -check -recursive infra`) and validated in CI without a backend.
- Third-party actions in `.github/workflows/` are pinned to full commit SHAs; keep that when bumping.
- Resources are prefixed `pf-hello-devops`; the deploy role trusts only this repo's `prod-hardening` branch.

## Do not touch
- `.github/workflows/cd.yml` deploys to AWS on push to `prod-hardening`; changes there need owner review. `infra/.terraform.lock.hcl` files are intentional.
- `notes/` and `win-scripts/` are the owner's notes/scripts (Windows scripts were never run on Windows).
- Never push to `main` directly (branch + PR).
