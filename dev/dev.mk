# dev.mk — Shared Makefile targets for medik8s local development
#
# Include this from any operator's Makefile:
#   TOOLS_DIR ?= $(shell cd .. && pwd)/tools
#   -include $(TOOLS_DIR)/dev/dev.mk
#
# All targets are prefixed with 'dev-' to avoid collisions.

# Dev environment configuration
MEDIK8S_CLUSTER_NAME ?= medik8s-dev
MEDIK8S_NAMESPACE ?= medik8s-system
TOOLS_DIR ?= $(shell cd .. && pwd)/tools
DEV_DIR := $(TOOLS_DIR)/dev

# CONTAINER_TOOL for dev targets: auto-detect docker/podman.
# Use override to ensure dev targets use the same tool as setup.sh,
# regardless of what the operator's Makefile sets.
# Must be defined before DEV_CLUSTER_TYPE which uses it for KIND_EXPERIMENTAL_PROVIDER.
override CONTAINER_TOOL := $(shell \
  if command -v podman >/dev/null 2>&1; then echo podman; \
  elif command -v docker >/dev/null 2>&1; then echo docker; \
  else echo ""; \
  fi \
)
ifeq ($(CONTAINER_TOOL),)
  $(error No container tool found. Please install docker or podman.)
endif

# Detect cluster type: "kind" if a Kind cluster exists, "external" otherwise.
# Uses CONTAINER_TOOL to set KIND_EXPERIMENTAL_PROVIDER (needed for podman).
# When SKIP_KIND=true, force external mode (the user explicitly opted out of Kind).
# Override with DEV_CLUSTER_TYPE=external to force external mode in other cases.
ifeq ($(SKIP_KIND),true)
  DEV_CLUSTER_TYPE ?= external
else
  DEV_CLUSTER_TYPE ?= $(shell \
    if KIND_EXPERIMENTAL_PROVIDER=$(CONTAINER_TOOL) kind get clusters 2>/dev/null | grep -q '^$(MEDIK8S_CLUSTER_NAME)$$'; then echo kind; \
    elif $(KUBECTL) cluster-info --context 'kind-$(MEDIK8S_CLUSTER_NAME)' >/dev/null 2>&1; then echo kind; \
    else echo external; \
    fi \
  )
endif

# Image delivery:
#   local:    loaded directly into Kind nodes (no registry, no pull)
#   ttl.sh:   pushed to ttl.sh (anonymous, ephemeral, no auth required)
#
# Defaults to "local" for Kind clusters, "ttl.sh" for external.
# Set DEV_REGISTRY=ttl.sh to force using ttl.sh even with Kind.
DEV_REGISTRY ?= $(if $(filter kind,$(DEV_CLUSTER_TYPE)),local,ttl.sh)
TTL_SH_TTL ?= 2h
ifeq ($(DEV_REGISTRY),local)
  DEV_IMG ?= localhost:5000/medik8s/$(OPERATOR_NAME):dev
else
  DEV_IMG ?= ttl.sh/medik8s-$(OPERATOR_NAME)-$(shell cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8):$(TTL_SH_TTL)
endif
DEV_IMG := $(DEV_IMG)

# Detect kubectl or oc
KUBECTL ?= $(shell \
  if command -v kubectl >/dev/null 2>&1; then echo kubectl; \
  elif command -v oc >/dev/null 2>&1; then echo oc; \
  else echo ""; \
  fi \
)
ifeq ($(KUBECTL),)
  $(error No kubectl or oc found. Please install kubectl or oc.)
endif

# Verify Go is available
ifeq ($(shell command -v go 2>/dev/null),)
  $(error Go not found. Please install Go from https://go.dev/doc/install or add it to your PATH.)
endif

# Warn early if OPERATOR_NAME is not set — dev-build and dev-deploy will fail without it.
ifndef OPERATOR_NAME
  $(warning OPERATOR_NAME is not set. Targets dev-build, dev-deploy, dev-redeploy will not work.)
endif

export MEDIK8S_CLUSTER_NAME
export MEDIK8S_NAMESPACE

# Helper to find the namespace for this operator's deployment.
# First tries the kustomization namespace (works even when OPERATOR_NAME != namespace prefix,
# e.g. SBR uses "sbr-operator-system" but OPERATOR_NAME is "storage-based-remediation").
# Falls back to label-based cluster queries filtered by operator name.
_dev_find_ns = $(shell \
  NS=$$({ grep -rh '^namespace:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
  if [ -n "$$NS" ] && $(KUBECTL) get namespace "$$NS" >/dev/null 2>&1; then echo "$$NS"; exit 0; fi; \
  NS=$$($(KUBECTL) get deployment -A -l control-plane=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)\|$(subst -,.,$(OPERATOR_NAME))' | head -1); \
  if [ -z "$$NS" ]; then \
    NS=$$($(KUBECTL) get deployment -A -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)\|$(subst -,.,$(OPERATOR_NAME))' | head -1); \
  fi; \
  if [ -z "$$NS" ]; then \
    NS=$$($(KUBECTL) get deployment -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null | grep '$(OPERATOR_NAME)' | awk '{print $$1}' | head -1); \
  fi; \
  echo "$$NS" \
)

##@ Dev Environment

.PHONY: dev-setup
dev-setup: ## Create Kind cluster and configure dependencies (use SKIP_KIND=true for existing clusters, KIND_HA=true for 3 CP)
	@$(DEV_DIR)/setup.sh $(if $(filter true,$(SKIP_KIND)),--skip-kind) $(if $(filter true,$(KIND_HA)),--ha)

.PHONY: dev-teardown
dev-teardown: ## Destroy the Kind dev cluster
ifeq ($(SKIP_KIND),true)
	@echo "External cluster — nothing to tear down. Use 'make dev-undeploy' to remove operators."
else
	@$(DEV_DIR)/teardown.sh
endif

.PHONY: dev-build
dev-build: ## Build operator image and load into Kind or push to ttl.sh
	@# For Kind: patch imagePullPolicy to IfNotPresent (no registry, images loaded directly).
	@# For external: keep imagePullPolicy as Always (image pulled from ttl.sh).
	@# The SNR controller reconciles DaemonSets from templates baked into the image,
	@# so this must be done before the container build, not after.
	@# Files are restored after build (even on failure) via trap.
ifeq ($(DEV_REGISTRY),local)
	@patched=""; \
	for f in $$(find install/ -name '*.yaml' 2>/dev/null); do \
		if grep -q 'imagePullPolicy: Always' "$$f"; then \
			cp "$$f" "$$f.dev-bak"; \
			sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/' "$$f"; \
			patched="$$patched $$f"; \
			echo "  Patched $$f imagePullPolicy for dev build."; \
		fi; \
	done; \
	restore() { for f in $$patched; do mv "$$f.dev-bak" "$$f"; done; }; \
	TMPTAR=$$(mktemp /tmp/dev-image-XXXXXX.tar); \
	cleanup() { rm -f "$$TMPTAR"; restore; }; \
	trap cleanup EXIT; \
	$(CONTAINER_TOOL) build -t $(DEV_IMG) . && \
	$(CONTAINER_TOOL) save -o "$$TMPTAR" $(DEV_IMG) && \
	KIND_EXPERIMENTAL_PROVIDER=$(if $(filter podman,$(CONTAINER_TOOL)),podman,docker) \
		kind load image-archive "$$TMPTAR" --name $(MEDIK8S_CLUSTER_NAME)
else
	$(CONTAINER_TOOL) build -t $(DEV_IMG) .
	$(CONTAINER_TOOL) push $(DEV_IMG)
	@echo ""
	@echo "  Image pushed to $(DEV_IMG)"
	@echo "  Image will expire after $(TTL_SH_TTL)."
endif

.PHONY: dev-deploy
dev-deploy: dev-build install $(if $(ENVSUBST),envsubst) ## Build, load image, install CRDs, and deploy operator
	@# Backup kustomization.yaml, set dev image, build+apply, then restore (even on failure).
	@cp config/manager/kustomization.yaml config/manager/kustomization.yaml.dev-bak; \
	KUST_OUT=$$(mktemp /tmp/dev-kustomize-XXXXXX.yaml); \
	trap 'rm -f "$$KUST_OUT"; mv config/manager/kustomization.yaml.dev-bak config/manager/kustomization.yaml' EXIT; \
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(DEV_IMG) && cd ../.. && \
	ENVSUBST_BIN="$(ENVSUBST)"; \
	$(KUSTOMIZE) build config/default >"$$KUST_OUT" 2> >(grep -v "Warning: 'commonLabels'" >&2); \
	if [ ! -s "$$KUST_OUT" ]; then \
		echo "Error: kustomize build produced no output."; \
		exit 1; \
	fi; \
	if [ -n "$$ENVSUBST_BIN" ] && [ -x "$$ENVSUBST_BIN" ]; then \
		export IMG=$(DEV_IMG) && $$ENVSUBST_BIN < "$$KUST_OUT" | $(KUBECTL) apply -f -; \
	else \
		$(KUBECTL) apply -f "$$KUST_OUT"; \
	fi
	@# Detect the operator namespace from kustomization files (reliable, no cluster query needed).
	@# The namespace may be in config/default/ or in a component/patch kustomization.yaml.
	@NS=$$({ grep -rh '^namespace:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
	if [ -z "$$NS" ]; then \
		NS=$$($(KUBECTL) get deployment -A -l control-plane=controller-manager --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | grep -i '$(OPERATOR_NAME)' | head -1); \
	fi; \
	if [ -n "$$NS" ]; then \
		if [ -d config/webhook ]; then \
			SVC_RAW=$$(grep -h '^  name:' config/webhook/service.yaml 2>/dev/null | head -1 | awk '{print $$2}'); \
			PREFIX=$$({ grep -rh '^namePrefix:' config/default/kustomization.yaml config/patches/*/kustomization.yaml config/components/*/kustomization.yaml 2>/dev/null || true; } | head -1 | awk '{print $$2}'); \
			SVC="$${PREFIX}$${SVC_RAW}"; \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
			if [ -z "$$DEPLOY" ]; then \
				DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
			fi; \
			if [ -n "$$DEPLOY" ] && [ -n "$$SVC" ]; then \
				$(DEV_DIR)/enable-certmanager.sh $$NS $$DEPLOY $$SVC; \
			else \
				echo "  Warning: config/webhook/ exists but could not determine deployment ($$DEPLOY) or service ($$SVC)."; \
			fi; \
		else \
			echo "  Skipping cert-manager setup (no config/webhook/ directory)."; \
		fi; \
		DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		if [ -z "$$DEPLOY" ]; then \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$DEPLOY" ]; then \
			echo "=== Waiting for operator deployment to be ready ==="; \
			$(KUBECTL) wait --for=condition=Available deployment/$$DEPLOY -n $$NS --timeout=120s || \
				{ echo "Error: deployment $$DEPLOY is not ready. Check logs with 'make dev-logs'."; exit 1; }; \
		fi; \
	else \
		echo "  Warning: could not detect operator namespace. Skipping cert-manager setup."; \
	fi
	@# Create NHC CR after webhooks are ready (cert-manager must be configured first).
	@# Auto-detects any deployed remediator template (SNR, FAR, MDR).
	@if $(KUBECTL) get crd nodehealthchecks.remediation.medik8s.io &>/dev/null && \
	    ($(KUBECTL) get selfnoderemediationtemplate -A --no-headers 2>/dev/null | grep -q . || \
	     $(KUBECTL) get fenceagentsremediationtemplate -A --no-headers 2>/dev/null | grep -q . || \
	     $(KUBECTL) get machinedeletionremediationtemplate -A --no-headers 2>/dev/null | grep -q .); then \
		$(DEV_DIR)/create-nhc.sh; \
	fi

.PHONY: dev-undeploy
dev-undeploy: ## Remove operator from dev cluster
	@if [ -n "$(KUSTOMIZE)" ] && [ -f config/default/kustomization.yaml ]; then \
		$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found -f -; \
	else \
		NS="$(_dev_find_ns)"; \
		if [ -n "$$NS" ]; then \
			echo "Deleting namespace $$NS..."; \
			$(KUBECTL) delete namespace "$$NS" --ignore-not-found; \
		else \
			echo "No operator deployment found to undeploy."; \
		fi; \
	fi

.PHONY: dev-bundle-run
dev-bundle-run: dev-build ## Deploy operator via OLM bundle (requires OLM + operator-sdk)
	@if ! command -v operator-sdk >/dev/null 2>&1; then \
		echo "Error: operator-sdk is required for bundle-run. Install from: https://sdk.operatorframework.io/docs/installation/"; \
		exit 1; \
	fi
	$(MAKE) bundle bundle-build bundle-push bundle-run IMG=$(DEV_IMG) BUNDLE_IMG=$(DEV_IMG)-bundle

.PHONY: dev-bundle-cleanup
dev-bundle-cleanup: ## Remove OLM bundle deployment
	@if ! command -v operator-sdk >/dev/null 2>&1; then \
		echo "Error: operator-sdk is required for bundle-cleanup."; \
		exit 1; \
	fi
	$(MAKE) bundle-cleanup BUNDLE_IMG=$(DEV_IMG)-bundle

.PHONY: dev-redeploy
dev-redeploy: dev-build ## Rebuild image and restart operator pods (deletes pods to pick up new image)
	@NS="$(_dev_find_ns)"; \
	if [ -n "$$NS" ]; then \
		echo "Deleting operator pods in $$NS to pick up new image..."; \
		$(KUBECTL) delete pods -n $$NS -l control-plane=controller-manager --force --grace-period=0 2>/dev/null || true; \
		$(KUBECTL) delete pods -n $$NS -l app.kubernetes.io/component=controller-manager --force --grace-period=0 2>/dev/null || true; \
		DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l control-plane=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		if [ -z "$$DEPLOY" ]; then \
			DEPLOY=$$($(KUBECTL) get deployment -n $$NS -l app.kubernetes.io/component=controller-manager --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$DEPLOY" ]; then \
			$(KUBECTL) wait --for=condition=Available deployment/$$DEPLOY -n $$NS --timeout=120s || \
				echo "Warning: deployment is not ready. Check logs with 'make dev-logs'."; \
		fi; \
	else \
		echo "Could not find deployment to restart. Run 'make dev-deploy' first."; \
	fi

.PHONY: dev-logs
dev-logs: ## Tail operator controller-manager logs
	@NS="$(_dev_find_ns)"; \
	if [ -n "$$NS" ]; then \
		POD=$$($(KUBECTL) get pods -n $$NS -l control-plane=controller-manager -o name 2>/dev/null | head -1); \
		if [ -z "$$POD" ]; then \
			POD=$$($(KUBECTL) get pods -n $$NS -l app.kubernetes.io/component=controller-manager -o name 2>/dev/null | head -1); \
		fi; \
		if [ -n "$$POD" ]; then \
			$(KUBECTL) logs -f -n $$NS $$POD --all-containers --tail=50; \
		else \
			echo "No controller-manager pod found in $$NS. Is the operator running?"; \
		fi; \
	else \
		echo "No controller-manager pod found. Run 'make dev-deploy' first."; \
	fi

.PHONY: dev-wait
dev-wait: ## Wait for all medik8s operator pods to be ready
	@echo "=== Waiting for operator deployments to be ready ==="
	@FOUND=false; \
	for label in control-plane=controller-manager app.kubernetes.io/component=controller-manager; do \
		for ns in $$($(KUBECTL) get deployment -A -l $$label --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do \
			for deploy in $$($(KUBECTL) get deployment -n $$ns -l $$label --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do \
				FOUND=true; \
				echo "  Waiting for $$ns/$$deploy..."; \
				$(KUBECTL) wait --for=condition=Available deployment/$$deploy -n $$ns --timeout=120s || \
					echo "  Warning: $$ns/$$deploy is not ready."; \
			done; \
		done; \
	done; \
	if [ "$$FOUND" = false ]; then \
		echo "  No operator deployments found. Run 'make dev-deploy' first."; \
		exit 1; \
	fi

.PHONY: dev-events
dev-events: ## Show recent events related to medik8s resources
	@echo "=== Recent Events (last 10 minutes) ==="
	@$(KUBECTL) get events -A --sort-by=.lastTimestamp --field-selector reason!=Pulling,reason!=Pulled 2>/dev/null | \
		grep -iE 'remediat|healthcheck|maintenance|fence|unhealthy|notready|taint' || \
		echo "  No remediation-related events found."
	@echo ""
	@echo "=== All Recent Events ==="
	@$(KUBECTL) get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -20

.PHONY: dev-summary
dev-summary: ## Show remediation flow timeline (what happened during simulate/recover)
	@$(DEV_DIR)/summary.sh

.PHONY: dev-describe
dev-describe: ## Full summary of all medik8s resources (nodes, pods, CRs, leases, events)
	@$(DEV_DIR)/describe.sh

.PHONY: dev-shell
dev-shell: ## Open a shell on a Kind node (use NODE=<name>, default: first worker)
	@NODES=$$(KIND_EXPERIMENTAL_PROVIDER=$(CONTAINER_TOOL) kind get nodes --name $(MEDIK8S_CLUSTER_NAME) 2>/dev/null); \
	if [ -z "$$NODES" ]; then \
		NODES=$$($(KUBECTL) get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); \
	fi; \
	if [ -z "$$NODES" ]; then \
		echo "No nodes found. Is the cluster running?"; \
		exit 1; \
	fi; \
	TARGET="$(NODE)"; \
	if [ -z "$$TARGET" ]; then \
		TARGET=$$(echo "$$NODES" | grep worker | head -1); \
	fi; \
	if [ -z "$$TARGET" ]; then \
		TARGET=$$(echo "$$NODES" | head -1); \
	fi; \
	if ! echo "$$NODES" | grep -Fqx -- "$$TARGET"; then \
		echo "Error: '$$TARGET' is not a node in the cluster. Available: $$(echo $$NODES | tr '\n' ' ')"; \
		exit 1; \
	fi; \
	echo "Opening shell on $$TARGET..."; \
	echo "  (type 'exit' to return)"; \
	$(CONTAINER_TOOL) exec -it "$$TARGET" bash

.PHONY: dev-create-nhc
dev-create-nhc: ## Create a NodeHealthCheck CR that triggers SNR remediation
	@$(DEV_DIR)/create-nhc.sh

.PHONY: dev-simulate-failure
dev-simulate-failure: ## Stop kubelet on a worker to trigger remediation (use SCENARIO= for other scenarios)
	@$(DEV_DIR)/simulate-failure.sh $(or $(SCENARIO),kubelet-stop)

.PHONY: dev-simulate-storm
dev-simulate-storm: ## Simulate storm: stop kubelet on 2 workers
	@$(DEV_DIR)/simulate-failure.sh storm

.PHONY: dev-simulate-network
dev-simulate-network: ## Block API server from a worker to test SNR peer health
	@$(DEV_DIR)/simulate-failure.sh network-partition

.PHONY: dev-recover
dev-recover: ## Recover all workers (restart kubelet, restore network, clean CRs)
	@$(DEV_DIR)/simulate-failure.sh recover

.PHONY: dev-help
dev-help: ## Show dev environment help
	@echo "Medik8s Development Environment"
	@echo ""
	@echo "Lifecycle:"
	@echo "  make dev-setup              Create Kind cluster (1 CP + 3 workers)"
	@echo "  make dev-teardown           Destroy cluster"
	@echo ""
	@echo "Build & Deploy:"
	@echo "  make dev-build              Build image and load into Kind"
	@echo "  make dev-deploy             Build + install CRDs + deploy operator"
	@echo "  make dev-redeploy           Rebuild and restart (fast iteration)"
	@echo "  make dev-undeploy           Remove operator from cluster"
	@echo "  make dev-bundle-run         Deploy via OLM bundle (requires operator-sdk)"
	@echo "  make dev-bundle-cleanup     Remove OLM bundle deployment"
	@echo "  make dev-create-nhc         Create NodeHealthCheck CR (auto-detects remediator)"
	@echo ""
	@echo "Observe:"
	@echo "  make dev-logs               Tail operator logs"
	@echo "  make dev-describe           Full summary (nodes, pods, CRs, leases, events)"
	@echo "  make dev-summary            Remediation flow timeline"
	@echo "  make dev-events             Show recent remediation-related events"
	@echo "  make dev-wait               Wait for all operator pods to be ready"
	@echo "  make dev-shell              Open shell on a Kind node (NODE=<name>)"
	@echo ""
	@echo "Simulate Failures:"
	@echo "  make dev-simulate-failure   Stop kubelet on a worker"
	@echo "  make dev-simulate-storm     Stop kubelet on 2 workers (storm test)"
	@echo "  make dev-simulate-network   Block API server from a worker"
	@echo "  make dev-recover            Recover all workers"
