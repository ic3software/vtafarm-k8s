SHELL      := /usr/bin/env bash
ROOT       := $(shell pwd)
INFRA      := $(ROOT)/stacks/01-infra
RANCHER    := $(ROOT)/stacks/02-rancher
RKE2_ROOT  := $(ROOT)/stacks/03-rke2-clusters/clusters
RKE2_TEMPLATE := $(ROOT)/stacks/03-rke2-clusters/_template
RKE2_CLUSTER_DIR := $(RKE2_ROOT)/$(CLUSTER)
RKE2_KUBECONFIG_FILE := $(RKE2_CLUSTER_DIR)/kubeconfig.yaml
VTAFARM_PLATFORM_ROOT := $(ROOT)/stacks/04-vtafarm-platform/clusters
VTAFARM_PLATFORM_TEMPLATE := $(ROOT)/stacks/04-vtafarm-platform/_template
VTAFARM_PLATFORM_CLUSTER_DIR := $(VTAFARM_PLATFORM_ROOT)/$(CLUSTER)
VTAFARM_PLATFORM_MODULE := $(ROOT)/modules/vtafarm-platform
KUBECONFIG_FILE := $(INFRA)/kubeconfig.yaml

export KUBECONFIG := $(KUBECONFIG_FILE)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}'

# --- stack 01: infrastructure + k3s ----------------------------------------

.PHONY: lint
lint: ## Check OpenTofu formatting and Markdown style
	tofu -chdir=$(INFRA) fmt -recursive -check
	tofu -chdir=$(RANCHER) fmt -recursive -check
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster fmt -recursive -check
	tofu -chdir=$(VTAFARM_PLATFORM_MODULE) fmt -recursive -check
	tofu -chdir=$(RKE2_TEMPLATE) fmt -recursive -check
	tofu -chdir=$(VTAFARM_PLATFORM_TEMPLATE) fmt -recursive -check
	tofu -chdir=$(INFRA) validate
	tofu -chdir=$(RANCHER) validate
	tofu -chdir=$(RKE2_TEMPLATE) validate
	tofu -chdir=$(VTAFARM_PLATFORM_TEMPLATE) validate
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster test
	tofu -chdir=$(VTAFARM_PLATFORM_MODULE) test
	markdownlint-cli2

.PHONY: fmt
fmt: ## Auto-format OpenTofu and Markdown in place
	tofu -chdir=$(INFRA) fmt -recursive
	tofu -chdir=$(RANCHER) fmt -recursive
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster fmt -recursive
	tofu -chdir=$(VTAFARM_PLATFORM_MODULE) fmt -recursive
	tofu -chdir=$(RKE2_TEMPLATE) fmt -recursive
	tofu -chdir=$(VTAFARM_PLATFORM_TEMPLATE) fmt -recursive
	markdownlint-cli2 --fix

.PHONY: init
init: ## Download providers for all stacks and module tests
	tofu -chdir=$(INFRA) init
	tofu -chdir=$(RANCHER) init
	tofu -chdir=$(RKE2_TEMPLATE) init -backend=false
	tofu -chdir=$(VTAFARM_PLATFORM_TEMPLATE) init -backend=false
	tofu -chdir=$(ROOT)/modules/rke2-custom-cluster init -backend=false
	tofu -chdir=$(VTAFARM_PLATFORM_MODULE) init -backend=false

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

# --- stack 02: Rancher on the management cluster ---------------------------

.PHONY: plan-rancher
plan-rancher: ## Show what stack 02 would change on the management cluster
	tofu -chdir=$(RANCHER) plan

.PHONY: apply-rancher
apply-rancher: ## Install/upgrade Rancher, cert-manager, backups and the upgrade controller
	tofu -chdir=$(RANCHER) apply

.PHONY: destroy-rancher
destroy-rancher: ## Destroy stack 02 only; keep stack 01 and RKE2 infrastructure
	tofu -chdir=$(RANCHER) destroy

.PHONY: rancher-password
rancher-password: ## Print the Rancher bootstrap password
	@tofu -chdir=$(RANCHER) output -raw rancher_bootstrap_password; echo

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

.PHONY: refresh-rke2
refresh-rke2: check-rke2-cluster ## Re-read one RKE2 cluster's state from Rancher (CLUSTER=name)
	tofu -chdir=$(RKE2_CLUSTER_DIR) apply -refresh-only

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
		echo "Wait for the cluster to become Active, then: make refresh-rke2 CLUSTER=$(CLUSTER)" >&2; \
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
	@$(MAKE) --no-print-directory drop-vtafarm-platform-state CLUSTER=$(CLUSTER)

# Everything stack 04 owns lives inside the RKE2 cluster, so destroying that
# cluster removes it. The state file must still go, or the next apply-vtafarm-platform
# would refresh against a cluster that no longer exists - the same reasoning as
# stack 02 at the bottom of this file.
.PHONY: drop-vtafarm-platform-state
drop-vtafarm-platform-state:
	@if [[ -f "$(VTAFARM_PLATFORM_CLUSTER_DIR)/terraform.tfstate" ]]; then \
		rm -f "$(VTAFARM_PLATFORM_CLUSTER_DIR)"/terraform.tfstate "$(VTAFARM_PLATFORM_CLUSTER_DIR)"/terraform.tfstate.backup; \
		echo "==> removed stack 04 state for $(CLUSTER) (its resources died with the cluster)"; \
	fi

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
		$(MAKE) --no-print-directory drop-vtafarm-platform-state CLUSTER="$${cluster_dir##*/}"; \
	done; \
	if [[ "$$found_cluster" == false ]]; then \
		echo "==> no generated RKE2 cluster roots found under $(RKE2_ROOT)"; \
	fi

# --- stack 04: the vtafarm platform on a downstream RKE2 cluster -----------

# Stack 04 only reaches the cluster through Rancher's proxy, which rate-limits.
# Concurrent helm_release discovery bursts come back 429, so serialize them.
VTAFARM_PLATFORM_PARALLELISM := 1

.PHONY: new-vtafarm-platform
new-vtafarm-platform: ## Scaffold the platform root for an RKE2 cluster (CLUSTER=name)
	@bash $(ROOT)/scripts/new-vtafarm-platform.sh "$(CLUSTER)"

.PHONY: check-vtafarm-platform
check-vtafarm-platform:
	@if [[ ! "$(CLUSTER)" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$$ ]]; then \
	  echo "set a DNS-safe cluster name, for example: make apply-vtafarm-platform CLUSTER=production" >&2; \
	  exit 2; \
	fi
	@test -d "$(VTAFARM_PLATFORM_CLUSTER_DIR)" || { \
	  echo "platform root does not exist: $(VTAFARM_PLATFORM_CLUSTER_DIR)" >&2; \
	  echo "create it with: make new-vtafarm-platform CLUSTER=$(CLUSTER)" >&2; \
	  exit 2; \
	}
	@test -s "$(RKE2_KUBECONFIG_FILE)" || { \
	  echo "no kubeconfig for $(CLUSTER) at $(RKE2_KUBECONFIG_FILE)" >&2; \
	  echo "write it with: make kubeconfig-rke2 CLUSTER=$(CLUSTER)" >&2; \
	  exit 2; \
	}

.PHONY: init-vtafarm-platform
init-vtafarm-platform: check-vtafarm-platform ## Initialize one platform root (CLUSTER=name)
	tofu -chdir=$(VTAFARM_PLATFORM_CLUSTER_DIR) init

.PHONY: plan-vtafarm-platform
plan-vtafarm-platform: check-vtafarm-platform ## Plan the downstream cluster's platform (CLUSTER=name)
	tofu -chdir=$(VTAFARM_PLATFORM_CLUSTER_DIR) plan -parallelism=$(VTAFARM_PLATFORM_PARALLELISM)

.PHONY: apply-vtafarm-platform
apply-vtafarm-platform: check-vtafarm-platform ## Install cert-manager, Longhorn and Vault downstream (CLUSTER=name)
	tofu -chdir=$(VTAFARM_PLATFORM_CLUSTER_DIR) apply -parallelism=$(VTAFARM_PLATFORM_PARALLELISM)

.PHONY: outputs-vtafarm-platform
outputs-vtafarm-platform: check-vtafarm-platform ## Print one platform root's outputs (CLUSTER=name)
	tofu -chdir=$(VTAFARM_PLATFORM_CLUSTER_DIR) output

.PHONY: destroy-vtafarm-platform
destroy-vtafarm-platform: check-vtafarm-platform ## Destroy stack 04 only; keep the RKE2 cluster (CLUSTER=name)
	tofu -chdir=$(VTAFARM_PLATFORM_CLUSTER_DIR) destroy -parallelism=$(VTAFARM_PLATFORM_PARALLELISM)

# Both Vaults come up sealed, and unsealing needs keys that must never reach
# OpenTofu state - so init and unseal stay manual. See docs/vault.md.
.PHONY: vault-bootstrap
vault-bootstrap: check-vtafarm-platform ## Configure a Vault after init+unseal (CLUSTER=name TARGET=transit|farm)
	@if [[ "$(TARGET)" != "transit" && "$(TARGET)" != "farm" ]]; then \
	  echo "set TARGET=transit or TARGET=farm" >&2; \
	  exit 2; \
	fi
	@KUBECONFIG=$(RKE2_KUBECONFIG_FILE) bash $(ROOT)/scripts/vault-bootstrap.sh "$(TARGET)"

.PHONY: vault-status
vault-status: check-vtafarm-platform ## Show Vault, Longhorn and certificate health (CLUSTER=name)
	@export KUBECONFIG=$(RKE2_KUBECONFIG_FILE); \
	echo "== nodes =="; kubectl get nodes -o wide; \
	echo; echo "== storage classes =="; kubectl get storageclass; \
	echo; echo "== longhorn =="; kubectl -n longhorn-system get pods 2>/dev/null || true; \
	echo; echo "== certificates =="; kubectl get certificate -A 2>/dev/null || true; \
	echo; echo "== transit vault =="; kubectl -n vault-transit get pods,pvc 2>/dev/null || true; \
	echo; echo "== farm vault =="; kubectl -n vault get pods,pvc 2>/dev/null || true

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

.PHONY: upgrade-packages-check
export CLUSTER
upgrade-packages-check: ## Report pending Ubuntu updates per node (CLUSTER=name for RKE2)
	@bash $(ROOT)/scripts/upgrade-packages.sh --check

.PHONY: upgrade-packages
upgrade-packages: ## apt upgrade every node, one at a time (CLUSTER=name for RKE2)
	@bash $(ROOT)/scripts/upgrade-packages.sh

.PHONY: ssh
ssh: ## SSH into the first control-plane node
	@$$(tofu -chdir=$(INFRA) output -raw ssh_command)

# Stack 02 is not destroyed here: every resource it owns lives inside the k3s
# cluster, so destroying stack 01 removes them anyway and a helm uninstall pass
# would only add minutes. Its state file must still go, or the next
# apply-rancher would refresh against a cluster that no longer exists.
.PHONY: destroy
destroy: ## Tear down RKE2 clusters, then infrastructure; drop the stale stack 02 state
	@$(MAKE) --no-print-directory destroy-all-rke2
	tofu -chdir=$(INFRA) destroy
	@rm -f $(RANCHER)/terraform.tfstate $(RANCHER)/terraform.tfstate.backup
	@echo "==> removed stack 02 state (its resources died with the cluster)"
