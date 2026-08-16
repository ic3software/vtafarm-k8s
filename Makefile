SHELL      := /usr/bin/env bash
ROOT       := $(shell pwd)
INFRA      := $(ROOT)/stacks/01-infra
PLATFORM   := $(ROOT)/stacks/02-platform
RKE2_ROOT  := $(ROOT)/stacks/03-rke2-clusters/clusters
RKE2_TEMPLATE := $(ROOT)/stacks/03-rke2-clusters/_template
RKE2_CLUSTER_DIR := $(RKE2_ROOT)/$(CLUSTER)
RKE2_KUBECONFIG_FILE := $(RKE2_CLUSTER_DIR)/kubeconfig.yaml
KUBECONFIG_FILE := $(ROOT)/kubeconfig

export KUBECONFIG := $(KUBECONFIG_FILE)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# --- stack 01: infrastructure + k3s ----------------------------------------

.PHONY: lint
lint: ## Check OpenTofu formatting and Markdown style
	tofu -chdir=$(INFRA) fmt -recursive -check
	tofu -chdir=$(PLATFORM) fmt -recursive -check
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster fmt -recursive -check
	tofu -chdir=$(RKE2_TEMPLATE) fmt -recursive -check
	tofu -chdir=$(INFRA) validate
	tofu -chdir=$(PLATFORM) validate
	tofu -chdir=$(RKE2_TEMPLATE) validate
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster test
	markdownlint-cli2

.PHONY: fmt
fmt: ## Auto-format OpenTofu and Markdown in place
	tofu -chdir=$(INFRA) fmt -recursive
	tofu -chdir=$(PLATFORM) fmt -recursive
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster fmt -recursive
	tofu -chdir=$(RKE2_TEMPLATE) fmt -recursive
	markdownlint-cli2 --fix

.PHONY: init
init: ## Download providers for all stacks and module tests
	tofu -chdir=$(INFRA) init
	tofu -chdir=$(PLATFORM) init
	tofu -chdir=$(RKE2_TEMPLATE) init -backend=false
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster init -backend=false

.PHONY: plan
plan: ## Show what stack 01 would change
	tofu -chdir=$(INFRA) plan

.PHONY: apply
apply: ## Create/update the cluster (stack 01)
	tofu -chdir=$(INFRA) apply

.PHONY: kubeconfig
kubeconfig: ## Re-fetch the kubeconfig from the first server
	tofu -chdir=$(INFRA) apply -replace=null_resource.kubeconfig -auto-approve

.PHONY: kubeconfig-merge
kubeconfig-merge: ## Merge the cluster into ~/.kube/config so you can switch contexts
	@bash $(ROOT)/scripts/merge-kubeconfig.sh $(KUBECONFIG_FILE)

.PHONY: kubeconfig-delete
kubeconfig-delete: ## Delete context from ~/.kube/config (CLUSTER=name for RKE2)
	@if [[ -n "$(CLUSTER)" ]]; then \
		bash $(ROOT)/scripts/delete-kube-context.sh --context "$(CLUSTER)"; \
	else \
		bash $(ROOT)/scripts/delete-kube-context.sh $(KUBECONFIG_FILE); \
	fi

.PHONY: outputs
outputs: ## Print stack 01 outputs (LB IPs, node IPs, DNS records)
	tofu -chdir=$(INFRA) output

.PHONY: token
token: ## Print the k3s join/encryption token - store this somewhere safe
	@tofu -chdir=$(INFRA) output -raw k3s_token; echo

# --- stack 02: cert-manager + Rancher --------------------------------------

.PHONY: plan-platform
plan-platform: ## Show what stack 02 would change
	tofu -chdir=$(PLATFORM) plan

.PHONY: apply-platform
apply-platform: ## Install/upgrade cert-manager, Rancher, backups, upgrade controller
	tofu -chdir=$(PLATFORM) apply

.PHONY: destroy-platform
destroy-platform: ## Destroy stack 02 only; keep stack 01 and RKE2 infrastructure
	tofu -chdir=$(PLATFORM) destroy

.PHONY: rancher-password
rancher-password: ## Print the Rancher bootstrap password
	@tofu -chdir=$(PLATFORM) output -raw rancher_bootstrap_password; echo

# --- stack 03: Rancher-provisioned downstream RKE2 clusters ---------------

.PHONY: new-rke2-cluster
new-rke2-cluster: ## Scaffold an independent RKE2 root (CLUSTER=name)
	@bash $(ROOT)/scripts/new-rke2-cluster.sh "$(CLUSTER)"

.PHONY: check-rke2-cluster
check-rke2-cluster:
	@if [[ ! "$(CLUSTER)" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$$ ]]; then \
	  echo "set a DNS-safe cluster name, for example: make plan-rke2 CLUSTER=production" >&2; \
	  exit 2; \
	fi
	@test -d "$(RKE2_CLUSTER_DIR)" || { \
	  echo "cluster root does not exist: $(RKE2_CLUSTER_DIR)" >&2; \
	  echo "create it with: make new-rke2-cluster CLUSTER=$(CLUSTER)" >&2; \
	  exit 2; \
	}

.PHONY: init-rke2
init-rke2: check-rke2-cluster ## Initialize one RKE2 cluster (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) init

.PHONY: plan-rke2
plan-rke2: check-rke2-cluster ## Plan one RKE2 cluster (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) plan

.PHONY: apply-rke2
apply-rke2: check-rke2-cluster ## Apply one RKE2 cluster (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) apply

.PHONY: outputs-rke2
outputs-rke2: check-rke2-cluster ## Print one RKE2 cluster's outputs (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) output

.PHONY: kubeconfig-rke2
kubeconfig-rke2: check-rke2-cluster ## Write one RKE2 kubeconfig to its ignored directory
	@raw_kubeconfig="$$(mktemp "$(RKE2_CLUSTER_DIR)/.kubeconfig.raw.yaml.XXXXXX")"; \
	filtered_kubeconfig="$$(mktemp "$(RKE2_CLUSTER_DIR)/.kubeconfig.filtered.yaml.XXXXXX")"; \
	trap 'rm -f "$$raw_kubeconfig" "$$filtered_kubeconfig"' EXIT; \
	tofu -chdir=$(RKE2_CLUSTER_DIR) output -raw kube_config >"$$raw_kubeconfig"; \
	if [[ ! -s "$$raw_kubeconfig" ]] || \
	   ! kubectl --kubeconfig="$$raw_kubeconfig" config view --minify --flatten >"$$filtered_kubeconfig" 2>/dev/null || \
	   [[ -z "$$(kubectl --kubeconfig="$$filtered_kubeconfig" config current-context 2>/dev/null)" ]]; then \
		echo "ERROR: Rancher has not returned a usable kubeconfig yet." >&2; \
		echo "Wait for the cluster to become Active, then refresh its OpenTofu state." >&2; \
		exit 1; \
	fi; \
	install -m 600 "$$filtered_kubeconfig" "$(RKE2_KUBECONFIG_FILE)"; \
	echo "wrote $(RKE2_KUBECONFIG_FILE)"

.PHONY: kubeconfig-merge-rke2
kubeconfig-merge-rke2: kubeconfig-rke2 ## Merge one RKE2 kubeconfig into ~/.kube/config
	@bash $(ROOT)/scripts/merge-kubeconfig.sh $(RKE2_KUBECONFIG_FILE)

.PHONY: destroy-rke2
destroy-rke2: check-rke2-cluster ## Destroy one RKE2 cluster only (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) destroy

.PHONY: destroy-all-rke2
destroy-all-rke2: ## Destroy every generated RKE2 cluster before Rancher
	@set -euo pipefail; \
	shopt -s nullglob; \
	found_cluster=false; \
	for cluster_dir in "$(RKE2_ROOT)"/*; do \
		[[ -d "$$cluster_dir" ]] || continue; \
		found_cluster=true; \
		echo "==> destroying RKE2 cluster $${cluster_dir##*/}"; \
		tofu -chdir="$$cluster_dir" destroy; \
	done; \
	if [[ "$$found_cluster" == false ]]; then \
		echo "==> no generated RKE2 cluster roots found under $(RKE2_ROOT)"; \
	fi

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
	@$$(tofu -chdir=$(INFRA) output -raw ssh_command)

.PHONY: destroy
destroy: ## Tear down RKE2 clusters, platform, then infrastructure
	@$(MAKE) --no-print-directory destroy-all-rke2
	@$(MAKE) --no-print-directory destroy-platform
	tofu -chdir=$(INFRA) destroy
