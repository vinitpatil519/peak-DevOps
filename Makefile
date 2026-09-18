# CloudForge Platform — common tasks. Run `make help`.
SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
HELM ?= helm
ENV  ?= local

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------- app
.PHONY: test test-backend test-frontend lint
test: test-backend test-frontend ## Run all unit tests

test-backend: ## Backend lint + tests
	cd app-backend && python -m pip install -q -r requirements-dev.txt && ruff check app tests && pytest

test-frontend: ## Frontend lint + tests + build
	cd app-frontend && npm ci && npm run lint && npm test && npm run build

# ---------------------------------------------------------------- docker compose
.PHONY: up down logs
up: ## Start the stack with docker compose (http://localhost:3000)
	@test -f .env || cp .env.example .env
	docker compose up --build -d

up-obs: ## Compose stack + Prometheus/Grafana (http://localhost:3001)
	@test -f .env || cp .env.example .env
	docker compose --profile observability up --build -d

down: ## Stop compose stack (keeps volumes)
	docker compose --profile observability down

logs: ## Tail compose logs
	docker compose logs -f --tail=100

# ---------------------------------------------------------------- kubernetes
.PHONY: kind-up kind-gitops kind-down smoke canary render lint-charts dashboards
kind-up: ## kind cluster + Istio + add-ons + apps (Helm mode)
	MODE=helm HELM=$(HELM) scripts/bootstrap-local.sh

kind-gitops: ## kind cluster + Istio + Argo CD app-of-apps (GitOps mode)
	MODE=gitops HELM=$(HELM) scripts/bootstrap-local.sh

kind-down: ## Delete kind cluster + local registry
	scripts/teardown-local.sh

smoke: ## End-to-end smoke test (BASE=http://cloudforge.local)
	scripts/smoke-test.sh $(BASE)

canary: ## Trigger backend canary + frontend blue/green with a new build
	scripts/demo-canary.sh

render: ## Render Helm charts into k8s-manifests/rendered/
	HELM=$(HELM) scripts/render-manifests.sh

lint-charts: ## helm lint every chart for ENV (local|eks)
	@for c in platform postgres redis backend apache-proxy frontend; do \
	  $(HELM) lint helm-charts/charts/$$c -f gitops/environments/$(ENV)/$$c.yaml || exit 1; done

dashboards: ## Regenerate Grafana dashboard JSON
	python monitoring/grafana/generate_dashboards.py

# ---------------------------------------------------------------- AWS
.PHONY: tf-bootstrap tf-plan tf-apply eks-up eks-down
tf-bootstrap: ## Create the Terraform state bucket (one time)
	cd infra-terraform/bootstrap && terraform init && terraform apply

tf-plan: ## terraform plan (dev)
	cd infra-terraform/environments/dev && terraform init -backend-config=backend.hcl && terraform plan -out=tfplan

tf-apply: ## terraform apply the saved plan (dev)  — COSTS MONEY
	cd infra-terraform/environments/dev && terraform apply tfplan

eks-up: ## Configure kubectl + Istio + Argo CD on EKS
	HELM=$(HELM) scripts/bootstrap-eks.sh

eks-down: ## Tear down EKS in the safe order
	scripts/teardown-eks.sh

# ---------------------------------------------------------------- security
.PHONY: scan
scan: ## Trivy fs + IaC scan (needs docker)
	docker run --rm -v "$$PWD:/src:ro" aquasec/trivy:0.66.0 fs --scanners vuln,secret --severity HIGH,CRITICAL /src
	docker run --rm -v "$$PWD:/src:ro" aquasec/trivy:0.66.0 config --config /src/security/trivy.yaml /src
