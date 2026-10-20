# One-command entry points. Needs: terraform >= 1.10, AWS CLI (authenticated), gh, python3.
PREFIX  ?= pf-hello-devops
BRANCH  ?= prod-hardening
REPO    ?= mabdullah679/hello-devops
TF      ?= terraform

.PHONY: test lint run bootstrap rebuild destroy destroy-bootstrap

test:
	python3 -m unittest discover -s tests -v

lint:
	ruff check .

run:  ## local server on :8080 with an in-memory chaos flag; admin token "local"
	ADMIN_TOKEN=local python3 app.py

bootstrap:  ## once per account: state bucket, ECR repo, GitHub OIDC deploy role (local state)
	cd infra/bootstrap && $(TF) init && $(TF) apply

rebuild:  ## deploy/redeploy the whole stack through the GitHub Actions pipeline
	gh workflow run cd --repo $(REPO) --ref $(BRANCH)

destroy:  ## tear the running stack down (VPC, ALB, ECS, alarms...); keeps state bucket + ECR
	cd infra && $(TF) init && $(TF) destroy -var image_tag=destroy

destroy-bootstrap:  ## LAST: state bucket, ECR repo (with images), deploy role
	cd infra/bootstrap && $(TF) destroy
