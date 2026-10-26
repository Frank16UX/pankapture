# Pankapture developer commands. Run `make help` for the list.

APP := build/Pankapture.app
CLT := /Library/Developer/CommandLineTools

# The Command Line Tools toolchain doesn't reliably find the swift-testing macro
# plugin; point at it explicitly. Not needed (and skipped) once Xcode is selected.
TEST_FLAGS := $(shell [ "$$(xcode-select -p)" = "$(CLT)" ] && echo "-Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing")

# `make eval` (PRD §11): labeled recordings, providers to score, runs per sample, split.
EVAL_DIR ?= $(HOME)/PankaptureEval
PROVIDERS ?=
RUNS ?= 3
SPLIT ?= dev
ONLY ?=
TRANSCRIBER ?=

.PHONY: help build test eval app debug-app run dmg release ci-secrets cert icon logs clean

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

build: ## Compile (debug)
	swift build

test: ## Run unit tests
	swift test $(TEST_FLAGS)

eval: ## Score auto-edit on labeled recordings: make eval PROVIDERS="lmstudio:qwen3.5-9b openai:gpt-6-luna@low"
	swift build -c release --product pankapture-eval
	"$$(swift build -c release --show-bin-path)/pankapture-eval" --dir "$(EVAL_DIR)" --providers "$(PROVIDERS)" --runs $(RUNS) --split $(SPLIT) --only "$(ONLY)" --transcriber "$(TRANSCRIBER)"

app: ## Build release .app into build/
	bash scripts/bundle.sh

debug-app: ## Build debug .app into build/
	CONFIG=debug bash scripts/bundle.sh

run: app ## Build and (re)launch the app
	-pkill -x Pankapture
	open "$(APP)"

dmg: ## Build release .app and package build/Pankapture.dmg
	bash scripts/package-dmg.sh

release: test ## Publish a GitHub release now (merges to main do this automatically)
	bash scripts/release.sh

ci-secrets: ## Give the release workflow the signing identity (once)
	bash scripts/ci-secrets.sh

cert: ## Create the local signing identity (once per machine)
	bash scripts/create-dev-cert.sh

icon: ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

logs: ## Stream app logs
	/usr/bin/log stream --predicate 'subsystem == "com.franklinperez.Pankapture"' --level debug

clean: ## Remove build artifacts
	rm -rf .build build
