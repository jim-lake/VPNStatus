# VPNStatus — Makefile
#
# A task runner in the spirit of package.json's "scripts". Wraps the common
# xcodebuild invocations plus code formatting so you don't have to remember the
# exact flags. Run `make help` (or just `make`) to list targets.
#
# Notes:
#   * The app builds and runs UNSIGNED. All xcodebuild targets pass
#     CODE_SIGNING_* flags so a missing "Mac Development" certificate is not a
#     problem (see AGENTS.md).
#   * UI tests must run from the logged-in GUI (Aqua) session, not over SSH.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT        := VPN.xcodeproj
CONFIGURATION  := Debug
DESTINATION    := platform=macOS

APP_SCHEME     := VPNStatus
UNIT_SCHEME    := VPNStatus
UITEST_SCHEME  := VPNStatusUITests

# Disable code signing everywhere — the app works unsigned.
UNSIGNED_FLAGS := CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

XCODEBUILD     := xcodebuild -project $(PROJECT) -configuration $(CONFIGURATION)

# Format over all first-party Objective-C sources (skip build output & DerivedData).
FORMAT_DIRS    := Common VPNStatus VPNStatusTests
CLANG_FORMAT   := clang-format

# Pretty-print xcodebuild output with xcpretty if it is installed; otherwise
# pass through unchanged.
PRETTY         := $(shell command -v xcpretty 2>/dev/null)
ifdef PRETTY
  PIPE := | xcpretty && exit $${PIPESTATUS[0]}
else
  PIPE :=
endif

SHELL := /bin/bash

# ---------------------------------------------------------------------------
# Meta
# ---------------------------------------------------------------------------
.DEFAULT_GOAL := help
.PHONY: help build build-app build-all rebuild clean \
        test test-unit test-ui \
        format format-check format-setup \
        run stop restart app-path \
        list-schemes

help: ## Show this help
	@echo "VPNStatus — available make targets:"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build: build-app ## Build the menu bar app (alias for build-app)

build-app: ## Build the VPNStatus menu bar app
	$(XCODEBUILD) -scheme $(APP_SCHEME) $(UNSIGNED_FLAGS) build $(PIPE)

build-all: build-app ## Build everything (currently just the app)

rebuild: clean build-all ## Clean, then build everything

clean: ## Delete build output (build/, DerivedData) and run xcodebuild clean
	@echo "Removing local build output..."
	rm -rf build DerivedData
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/VPN-*
	$(XCODEBUILD) -scheme $(APP_SCHEME) clean $(PIPE)

# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------
test: test-unit ## Run the unit tests (alias for test-unit)

test-unit: ## Run unit tests (GitHubRelease + ACMenuReconciler)
	$(XCODEBUILD) -scheme $(UNIT_SCHEME) -destination '$(DESTINATION)' $(UNSIGNED_FLAGS) test $(PIPE)

test-ui: ## Run end-to-end UI tests (requires the GUI/Aqua session, not SSH)
	@if [ -n "$$SSH_CONNECTION" ] || [ "$$(launchctl managername 2>/dev/null)" = "Background" ]; then \
		echo "error: UI tests must run from the logged-in desktop (Aqua) session, not over SSH."; \
		echo "       Open Terminal on the Mac's desktop and run 'make test-ui' there."; \
		exit 1; \
	fi
	@command -v vpnutil >/dev/null 2>&1 || { \
		echo "note: 'vpnutil' not found on PATH. The connect/disconnect toggle test"; \
		echo "      will be skipped. Install it for full coverage:"; \
		echo "        brew install timac/vpnstatus/vpnutil"; \
	}
	$(XCODEBUILD) -scheme $(UITEST_SCHEME) -destination '$(DESTINATION)' $(UNSIGNED_FLAGS) test $(PIPE)

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------
format: format-setup ## Format all Objective-C sources in place (.clang-format)
	@files=$$(find $(FORMAT_DIRS) -type f \( -name '*.m' -o -name '*.h' \) 2>/dev/null); \
	if [ -z "$$files" ]; then echo "No .m/.h files found."; exit 0; fi; \
	echo "$$files" | xargs $(CLANG_FORMAT) -i --style=file; \
	echo "Formatted $$(echo "$$files" | wc -l | tr -d ' ') file(s)."

format-check: format-setup ## Check formatting without modifying files (CI-friendly)
	@files=$$(find $(FORMAT_DIRS) -type f \( -name '*.m' -o -name '*.h' \) 2>/dev/null); \
	if [ -z "$$files" ]; then echo "No .m/.h files found."; exit 0; fi; \
	fail=0; \
	for f in $$files; do \
		if ! $(CLANG_FORMAT) --style=file "$$f" | diff -q "$$f" - >/dev/null; then \
			echo "needs formatting: $$f"; fail=1; \
		fi; \
	done; \
	if [ $$fail -ne 0 ]; then \
		echo "Run 'make format' to fix."; exit 1; \
	fi; \
	echo "All files are correctly formatted."

format-setup: ## Install clang-format (via Homebrew) if it isn't already present
	@if command -v $(CLANG_FORMAT) >/dev/null 2>&1; then \
		true; \
	elif command -v brew >/dev/null 2>&1; then \
		echo "clang-format not found; installing via Homebrew..."; \
		brew install clang-format; \
	else \
		echo "error: clang-format is not installed and Homebrew is unavailable."; \
		echo "       Install Homebrew (https://brew.sh) or clang-format manually."; \
		exit 1; \
	fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
app-path: ## Print the path to the built VPNStatus.app
	@$(XCODEBUILD) -scheme $(APP_SCHEME) -showBuildSettings $(UNSIGNED_FLAGS) 2>/dev/null \
		| awk '/ BUILT_PRODUCTS_DIR =/ {print $$3"/$(APP_SCHEME).app"}'

run: build-app stop ## Build, then launch the app (menu bar item) and leave it running
	@app=$$($(MAKE) --no-print-directory app-path); \
	echo "Launching $$app"; \
	open "$$app"

stop: ## Quit any running VPNStatus instance
	@pkill -x $(APP_SCHEME) 2>/dev/null && echo "Stopped running VPNStatus." || echo "VPNStatus was not running."

restart: stop run ## Restart the app

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
list-schemes: ## List the Xcode schemes in the project
	@$(XCODEBUILD) -list -project $(PROJECT)
