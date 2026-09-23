.PHONY: build dist test lint install-local install-hooks uninstall-local release-plan

HOOKS_DIR ?= $(HOME)/.trustguard/windsurf-hooks
HOOKS_JSON ?= $(HOME)/.codeium/windsurf/hooks.json
VERSION ?= dev

build: ## Build the trustguard-windsurf hook binary into ./bin/
	@mkdir -p bin
	go build -buildvcs=false -trimpath -ldflags "-s -w" -o bin/trustguard-windsurf ./cli

dist: ## Cross-compile every release binary into ./dist/ (VERSION=X.Y.Z)
	@scripts/build-dist.sh $(VERSION)

test: ## Run the test suite
	go test -race ./cli/
	sh tests/bootstrap-hook.sh

lint: ## Vet the sources and check the bootstrap syntax
	go vet ./cli/
	sh -n hooks/trustguard-hook.sh

release-plan: ## Print what the Release workflow would do (mode + version)
	@python3 scripts/release.py plan

# Copies the bootstraps and merges absolute paths into the user hooks.json.
# Cascade runs hooks from the workspace root, so relative paths would break.
# The binary is downloaded by the bootstrap on the first event.
install-hooks: ## Install the bootstraps and wire the user-level hooks.json
	@mkdir -p "$(HOOKS_DIR)"
	@cp hooks/trustguard-hook.sh hooks/trustguard-hook.ps1 "$(HOOKS_DIR)/"
	@chmod 0755 "$(HOOKS_DIR)/trustguard-hook.sh"
	@python3 scripts/install-hooks.py install "$(HOOKS_DIR)" "$(HOOKS_JSON)"
	@echo "wired $(HOOKS_JSON) — reload Windsurf so Cascade picks the hooks up"

install-local: build install-hooks ## Same as install-hooks, with a local build of the binary
	@mkdir -p "$(HOME)/.trustguard/bin"
	@cp bin/trustguard-windsurf "$(HOME)/.trustguard/bin/trustguard-windsurf"
	@chmod 0755 "$(HOME)/.trustguard/bin/trustguard-windsurf"

uninstall-local: ## Remove the TrustGuard entries and the local install
	@python3 scripts/install-hooks.py uninstall "$(HOOKS_JSON)"
	@rm -rf "$(HOOKS_DIR)"
	@rm -f "$(HOME)/.trustguard/bin/trustguard-windsurf"
	@echo "removed local TrustGuard Windsurf install"
