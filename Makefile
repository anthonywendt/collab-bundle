# The version of Zarf to use. To keep this repo as portable as possible the Zarf binary will be downloaded and added to
# the build folder.
# renovate: datasource=github-tags depName=defenseunicorns/zarf
UDS_CLI_VERSION := v0.0.5-alpha

ZARF_VERSION := v0.29.2

# Figure out which Zarf binary we should use based on the operating system we are on
ZARF_BIN := zarf
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),x86_64)
    ARCH := amd64
else ifeq ($(UNAME_M),amd64)
    ARCH := amd64
else ifeq ($(UNAME_M),arm64)
    ARCH := arm64
else
    $(error Unsupported architecture: $(UNAME_M))
endif

# Silent mode by default. Run `make VERBOSE=1` to turn off silent mode.
ifndef VERBOSE
.SILENT:
endif

# Optionally add the "-it" flag for docker run commands if the env var "CI" is not set (meaning we are on a local machine and not in github actions)
TTY_ARG :=
ifndef CI
	TTY_ARG := -it
endif

.DEFAULT_GOAL := help

# Idiomatic way to force a target to always run, by having it depend on this dummy target
FORCE:

.PHONY: help
help: ## Show a list of all targets
	grep -E '^\S*:.*##.*$$' $(MAKEFILE_LIST) \
	| sed -n 's/^\(.*\): \(.*\)##\(.*\)/\1:\3/p' \
	| column -t -s ":"


########################################################################
# Cluster Section
########################################################################

cluster/reset: cluster/destroy cluster/create ## This will destroy any existing cluster and then create a new one

cluster/create: ## Create a k3d cluster with metallb installed
	K3D_FIX_MOUNTS=1 k3d cluster create k3d-test-cluster --config utils/k3d/k3d-config.yaml
	k3d kubeconfig merge k3d-test-cluster -o /home/${USER}/cluster-kubeconfig.yaml
	echo "Installing Calico..."
	kubectl apply --wait=true -f utils/calico/calico.yaml 2>&1 >/dev/null
	echo "Waiting for Calico to be ready..."
	kubectl rollout status deployment/calico-kube-controllers -n kube-system --watch --timeout=90s 2>&1 >/dev/null
	kubectl rollout status daemonset/calico-node -n kube-system --watch --timeout=90s 2>&1 >/dev/null
	kubectl wait --for=condition=Ready pods --all --all-namespaces 2>&1 >/dev/null
	echo
	utils/metallb/install.sh
	echo "Cluster is ready!"

cluster/destroy: ## Destroy the k3d cluster
	k3d cluster delete k3d-test-cluster

########################################################################
# Build Section
########################################################################

.PHONY: build/all
build/all: build build/zarf build/uds build/collab-bundle-namespaces build/uds-bundle-collab ## Build everything

build: ## Create build directory
	mkdir -p build

.PHONY: clean
clean: ## Clean up build files
	rm -rf ./build

.PHONY: build/zarf
build/zarf: | build ## Download the Zarf to the build dir
	if [ -f build/zarf ] && [ "$$(build/zarf version)" = "$(ZARF_VERSION)" ] ; then exit 0; fi && \
	echo "Downloading zarf" && \
	curl -sL https://github.com/defenseunicorns/zarf/releases/download/$(ZARF_VERSION)/zarf_$(ZARF_VERSION)_$(UNAME_S)_$(ARCH) -o build/zarf && \
	chmod +x build/zarf

.PHONY: build/uds
build/uds: | build ## Download uds-cli to the build dir
	if [ -f build/uds ] && [ "$$(build/uds version)" = "$(UDS_CLI_VERSION)" ] ; then exit 0; fi && \
	echo "Downloading uds-cli" && \
	curl -sL https://github.com/defenseunicorns/uds-cli/releases/download/$(UDS_CLI_VERSION)/uds-cli_$(UDS_CLI_VERSION)_$(UNAME_S)_$(ARCH) -o build/uds && \
	chmod +x build/uds

build/collab-bundle-namespaces: | build ## Build namespaces package
	cd build && ./zarf package create ../packages/namespaces/ --confirm --output-directory .

build/uds-bundle-collab: | build ## Build the collab bundle
	cd build && ./uds bundle create ../ --confirm
	mv uds-bundle-collab-demo-*.tar.zst build/

########################################################################
# Deploy Section
########################################################################

deploy: ## Deploy the collab bundle
	cd ./build && ./uds bundle deploy uds-bundle-collab-demo-*.tar.zst --confirm

########################################################################
# Macro Section
########################################################################

.PHONY: all
all: build/all cluster/reset deploy ## Build and deploy the collab bundle

.PHONY: rebuild
rebuild: clean build/all
