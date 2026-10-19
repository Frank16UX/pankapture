# Pankapture developer commands. Run `make help` for the list.

APP := build/Pankapture.app
CLT := /Library/Developer/CommandLineTools

# The Command Line Tools toolchain doesn't reliably find the swift-testing macro
# plugin; point at it explicitly. Not needed (and skipped) once Xcode is selected.
TEST_FLAGS := $(shell [ "$$(xcode-select -p)" = "$(CLT)" ] && echo "-Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing")

.PHONY: help build test app debug-app run cert logs clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile (debug)
	swift build

test: ## Run unit tests
	swift test $(TEST_FLAGS)

app: ## Build release .app into build/
	bash scripts/bundle.sh

debug-app: ## Build debug .app into build/
	CONFIG=debug bash scripts/bundle.sh

run: app ## Build and (re)launch the app
	-pkill -x Pankapture
	open "$(APP)"

cert: ## Create the local signing identity (once per machine)
	bash scripts/create-dev-cert.sh

logs: ## Stream app logs
	/usr/bin/log stream --predicate 'subsystem == "com.franklinperez.Pankapture"' --level debug

clean: ## Remove build artifacts
	rm -rf .build build
