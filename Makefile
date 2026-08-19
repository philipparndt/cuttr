# cuttr
#
# Common entry points. `make` builds and launches the app.

APP     := build/cuttr.app
BINARY  := $(APP)/Contents/MacOS/cuttr
CONFIG  ?= release

# Xcode's Swift, not whichever one is first on the PATH.
#
# A toolchain manager such as swiftly puts its own `swift` in front, and that
# one is pinned to a release older than the SDK: it then fails to compile
# Foundation, with an error about the SDK rather than anything to do with this
# program. `xcrun` asks the selected Xcode, which is the toolchain the SDK
# belongs to and the one `bundle.sh` builds with anyway.
SWIFT   := xcrun swift

.DEFAULT_GOAL := run

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the .app bundle (CONFIG=debug|release, default release)
	@Scripts/bundle.sh $(CONFIG)

.PHONY: run
run: build ## Build and launch the app
	@echo "==> Launching $(APP)"
	@open $(APP)

.PHONY: dev
dev: ## Build debug and run in the foreground, with logs on the terminal
	@$(MAKE) build CONFIG=debug
	@echo "==> Running $(BINARY) (ctrl-c to stop)"
	@$(BINARY)

.PHONY: open
open: ## Build and open a take: make open TAKE=path/to/take.cuttr
	@test -n "$(TAKE)" || { echo "usage: make open TAKE=<file.cuttr>"; exit 1; }
	@$(MAKE) build CONFIG=debug
	@open -a $(abspath $(APP)) $(TAKE)

.PHONY: test
test: ## Run the test suite (FILTER=name)
	@$(SWIFT) test $(if $(FILTER),--filter $(FILTER))

.PHONY: xcode
xcode: ## Generate the Xcode project and open it (needs xcodegen)
	@command -v xcodegen >/dev/null || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
	@xcodegen generate
	@open cuttr.xcodeproj

.PHONY: release
release: ## Build, sign and notarise a disk image (needs a Developer ID)
	@$(MAKE) --no-print-directory build CONFIG=release
	@Scripts/release.sh

.PHONY: release-publish
release-publish: ## Cut a release: make release-publish VERSION=0.2.0
	@test -n "$(VERSION)" || { echo "usage: make release-publish VERSION=0.2.0"; exit 1; }
	@Scripts/publish-release.sh $(VERSION)

.PHONY: tap
tap: ## Point the Homebrew tap at a release: make tap VERSION=0.2.0
	@test -n "$(VERSION)" || { echo "usage: make tap VERSION=0.2.0"; exit 1; }
	@Scripts/update-tap.sh $(VERSION)

.PHONY: install
install: build ## Copy the app into /Applications
	@rm -rf /Applications/cuttr.app
	@cp -R $(APP) /Applications/
	@echo "==> Installed /Applications/cuttr.app"

.PHONY: clean
clean: ## Remove build output
	@rm -rf .build build
	@echo "==> Cleaned"
