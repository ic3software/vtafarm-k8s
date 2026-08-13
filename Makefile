SHELL      := /usr/bin/env bash
ROOT       := $(shell pwd)
INFRA      := $(ROOT)/stacks/01-infra
PLATFORM   := $(ROOT)/stacks/02-platform
KUBECONFIG_FILE := $(ROOT)/kubeconfig

export KUBECONFIG := $(KUBECONFIG_FILE)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- stack 01: infrastructure + k3s ----------------------------------------

.PHONY: lint
lint: ## Check Terraform formatting and Markdown style
	terraform -chdir=$(INFRA) fmt -recursive -check
	terraform -chdir=$(PLATFORM) fmt -recursive -check
	terraform -chdir=$(INFRA) validate
	terraform -chdir=$(PLATFORM) validate
	markdownlint-cli2

.PHONY: fmt
fmt: ## Auto-format Terraform and Markdown in place
	terraform -chdir=$(INFRA) fmt -recursive
	terraform -chdir=$(PLATFORM) fmt -recursive
	markdownlint-cli2 --fix

.PHONY: init
init: ## Download providers for both stacks
	terraform -chdir=$(INFRA) init
	terraform -chdir=$(PLATFORM) init

.PHONY: plan
plan: ## Show what stack 01 would change
	terraform -chdir=$(INFRA) plan

.PHONY: apply
apply: ## Create/update the cluster (stack 01)
	terraform -chdir=$(INFRA) apply

.PHONY: kubeconfig
kubeconfig: ## Re-fetch the kubeconfig from the first server
	terraform -chdir=$(INFRA) apply -replace=null_resource.kubeconfig -auto-approve

.PHONY: kubeconfig-merge
kubeconfig-merge: ## Merge the cluster into ~/.kube/config so you can switch contexts
	@bash $(ROOT)/scripts/merge-kubeconfig.sh $(KUBECONFIG_FILE)

.PHONY: kubeconfig-delete
kubeconfig-delete: ## Delete the merged cluster context from ~/.kube/config
	@bash $(ROOT)/scripts/delete-kube-context.sh $(KUBECONFIG_FILE)

.PHONY: outputs
outputs: ## Print stack 01 outputs (LB IPs, node IPs, DNS records)
	terraform -chdir=$(INFRA) output

.PHONY: token
token: ## Print the k3s join/encryption token - store this somewhere safe
	@terraform -chdir=$(INFRA) output -raw k3s_token; echo

# --- stack 02: cert-manager + Rancher --------------------------------------

.PHONY: plan-platform
plan-platform: ## Show what stack 02 would change
	terraform -chdir=$(PLATFORM) plan

.PHONY: apply-platform
apply-platform: ## Install/upgrade cert-manager, Rancher, backups, upgrade controller
	terraform -chdir=$(PLATFORM) apply

.PHONY: rancher-password
rancher-password: ## Print the Rancher bootstrap password
	@terraform -chdir=$(PLATFORM) output -raw rancher_bootstrap_password; echo

# --- day-2 ------------------------------------------------------------------

.PHONY: status
status: ## Quick health overview of the cluster
	@echo "== nodes ==";        kubectl get nodes -o wide
	@echo; echo "== etcd members ==";  kubectl get nodes -l node-role.kubernetes.io/etcd=true
	@echo; echo "== not running ==";   kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true
	@echo; echo "== rancher ==";       kubectl -n cattle-system get deploy,pods,ingress 2>/dev/null || true
	@echo; echo "== certificates =="; kubectl get certificate -A 2>/dev/null || true

.PHONY: snapshot
snapshot: ## Take an on-demand etcd snapshot on the first server
	@bash $(ROOT)/scripts/etcd-snapshot.sh save

.PHONY: snapshots
snapshots: ## List etcd snapshots (local + S3)
	@bash $(ROOT)/scripts/etcd-snapshot.sh list

.PHONY: upgrade-os
export TARGET_IMAGE
upgrade-os: ## Replace nodes one at a time with TARGET_IMAGE (for example ubuntu-26.04)
	@bash $(ROOT)/scripts/upgrade-os.sh

.PHONY: ssh
ssh: ## SSH into the first control-plane node
	@$$(terraform -chdir=$(INFRA) output -raw ssh_command)

.PHONY: destroy
destroy: ## Tear everything down (platform first, then infrastructure)
	-terraform -chdir=$(PLATFORM) destroy
	terraform -chdir=$(INFRA) destroy
