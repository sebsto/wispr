# wispr — Developer Makefile
#
# Handy targets for inspecting and cleaning local app data.

BUNDLE_ID    := com.stormacq.mac.wispr
CONTAINER    := $(HOME)/Library/Containers/$(BUNDLE_ID)/Data
MODEL_DIR    := $(CONTAINER)/Library/Application Support/wispr
PARAKEET_DIR := $(HOME)/Library/Application Support/FluidAudio

SCHEME       := wispr
XCODEPROJ    := wispr.xcodeproj
ARCHIVE_PATH := $(CURDIR)/build/wispr.xcarchive
EXPORT_DIR   := $(CURDIR)/build/export

# App Store Connect API key (read from secrets/asc-api-key.json)
SECRETS_JSON   := $(CURDIR)/secrets/asc-api-key.json
API_KEYS_DIR   := $(CURDIR)/secrets
API_KEY_ID     := $(shell jq -r .apple_api_key_id $(CURDIR)/secrets/asc-api-key.json 2>/dev/null)
API_ISSUER     := $(shell jq -r .apple_api_issuer_id $(CURDIR)/secrets/asc-api-key.json 2>/dev/null)
API_KEY_PATH   := $(API_KEYS_DIR)/AuthKey_$(API_KEY_ID).p8

APP_PATH          := $(EXPORT_DIR)/Wispr.app
ZIP_PATH          := $(EXPORT_DIR)/wispr-notarized.zip

# pkg installer (see .kiro/specs/pkg-installer)
# INSTALLER_IDENTITY is the only new secret — the Developer ID Installer certificate
# name, added to the existing secrets/asc-api-key.json. App signing itself is automatic
# Developer ID via ExportOptionsHomebrew.plist (handled by the `notarize` target).
#
# secrets/asc-api-key.json schema (git-ignored, never committed):
#   {
#     "apple_api_key_id":    "[key_id]",
#     "apple_api_issuer_id": "[issuer_id]",
#     "apple_api_key":       "[base64-encoded .p8 key]",
#     "installer_identity":  "Developer ID Installer: [name] ([team_id])"
#   }
# The first three fields are used by notarytool; `installer_identity` (new) is
# used by `productsign` in the `pkg` target.
INSTALLER_IDENTITY := $(shell jq -r '.installer_identity // empty' $(SECRETS_JSON) 2>/dev/null)
COMPONENT_PKG      := $(EXPORT_DIR)/wispr-component.pkg
PRODUCT_PKG        := $(EXPORT_DIR)/wispr-unsigned.pkg
SIGNED_PKG         := $(EXPORT_DIR)/wispr-signed.pkg
PKG_RESOURCES      := $(CURDIR)/pkg/resources
DISTRIBUTION_XML   := $(CURDIR)/pkg/distribution.xml
# VERSION: a caller-supplied value (make pkg VERSION=x.y.z or pkg-release) always wins;
# otherwise fall back to the project's current MARKETING_VERSION so the output filename
# and package version stay deterministic.
VERSION ?= $(shell grep -m1 'MARKETING_VERSION' $(XCODEPROJ)/project.pbxproj | sed 's/.*= *//;s/;.*//')
FINAL_PKG          := $(EXPORT_DIR)/wispr-$(VERSION).pkg

.PHONY: help test bump-build archive upload notarize pkg pkg-release brew-release brew-clean list-downloads clean-downloads list-container list-prefs clean-prefs reset-permissions reset-login-item reset-onboarding

_setup-api-key:
	@test -f "$(SECRETS_JSON)" || { echo "Error: $(SECRETS_JSON) not found"; exit 1; }
	@mkdir -p $(API_KEYS_DIR)
	@jq -r .apple_api_key $(SECRETS_JSON) | base64 -d > $(API_KEY_PATH)

_cleanup-api-key:
	@rm -f $(API_KEY_PATH)

bump-build: ## Set build number (CFBundleVersion) to git commit count
	$(eval BUILD_NUM := $(shell date +%y%m%d).$(shell git rev-list --count HEAD))
	@xcrun agvtool new-version -all $(BUILD_NUM) > /dev/null
	@echo "Build number set to $(BUILD_NUM)"

archive: bump-build ## Bump build number and create Release archive (version is unchanged)
	set -o pipefail && xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release \
		-archivePath $(ARCHIVE_PATH) clean archive | xcbeautify

test: ## Run unit tests with xcodebuild (not SPM)
	set -o pipefail && xcodebuild test \
		-project $(XCODEPROJ) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-destination 'platform=macOS,arch=arm64' \
		-only-testing:WisprTests | xcbeautify

upload: archive _setup-api-key ## Archive and upload to App Store Connect
	@rm -rf $(EXPORT_DIR)
	set -o pipefail && xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportPath $(EXPORT_DIR) \
		-exportOptionsPlist ExportOptions.plist \
		-allowProvisioningUpdates \
		-authenticationKeyPath $(API_KEY_PATH) \
		-authenticationKeyID $(API_KEY_ID) \
		-authenticationKeyIssuerID $(API_ISSUER) | xcbeautify
	@$(MAKE) _cleanup-api-key

notarize: archive _setup-api-key ## Archive, export with Developer ID, notarize, and staple
	@rm -rf $(EXPORT_DIR)
	@echo "📦 Exporting with Developer ID signing..."
	set -o pipefail && xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportPath $(EXPORT_DIR) \
		-exportOptionsPlist ExportOptionsHomebrew.plist \
		-allowProvisioningUpdates \
		-authenticationKeyPath $(API_KEY_PATH) \
		-authenticationKeyID $(API_KEY_ID) \
		-authenticationKeyIssuerID $(API_ISSUER) | xcbeautify
	@echo "🗜️  Creating zip..."
	@ditto -c -k --keepParent "$(APP_PATH)" "$(ZIP_PATH)"
	@echo "📤 Submitting for notarization..."
	@xcrun notarytool submit "$(ZIP_PATH)" \
		--key "$(API_KEY_PATH)" \
		--key-id "$(API_KEY_ID)" \
		--issuer "$(API_ISSUER)" \
		--wait
	@echo "📎 Stapling ticket..."
	@xcrun stapler staple "$(APP_PATH)"
	@echo "✅ Notarization complete"
	@spctl -a -vvv -t install "$(APP_PATH)"
	@$(MAKE) _cleanup-api-key

pkg: notarize ## Build a signed, notarized .pkg installer (reuses notarize; VERSION optional)
	@echo "🔎 Validating installer resources…"
	@for f in "$(DISTRIBUTION_XML)" "$(PKG_RESOURCES)/background.png" "$(PKG_RESOURCES)/welcome.html" "$(PKG_RESOURCES)/readme.html" "$(PKG_RESOURCES)/license.txt"; do \
		test -f "$$f" || { echo "Error: missing installer resource: $$f"; exit 1; }; \
	done
	@echo "🔒 Checking secrets are not tracked by git…"
	@git ls-files --error-unmatch "$(SECRETS_JSON)" >/dev/null 2>&1 && \
		{ echo "Error: $(SECRETS_JSON) is tracked by git — remove it from version control before releasing"; exit 1; } || true
	@test -n "$(INSTALLER_IDENTITY)" || { echo "Error: installer_identity not found in $(SECRETS_JSON)"; exit 1; }
	@security find-identity -v -p basic | grep -qF "$(INSTALLER_IDENTITY)" || \
		{ echo 'Error: certificate "$(INSTALLER_IDENTITY)" not found in keychain'; exit 1; }
	@echo "📦 Building component package (version $(VERSION))…"
	@pkgbuild --component "$(APP_PATH)" \
		--install-location /Applications \
		--identifier $(BUNDLE_ID) \
		--version $(VERSION) \
		"$(COMPONENT_PKG)" || { echo "Error: pkgbuild failed"; exit 1; }
	@echo "🏗️  Building product package with custom UI…"
	@sed 's/__VERSION__/$(VERSION)/g' "$(DISTRIBUTION_XML)" > "$(EXPORT_DIR)/distribution.xml"
	@productbuild --distribution "$(EXPORT_DIR)/distribution.xml" \
		--resources "$(PKG_RESOURCES)" \
		--package-path "$(EXPORT_DIR)" \
		"$(PRODUCT_PKG)" || { echo "Error: productbuild failed"; exit 1; }
	@echo "✍️  Signing product package…"
	@productsign --sign "$(INSTALLER_IDENTITY)" "$(PRODUCT_PKG)" "$(SIGNED_PKG)" || \
		{ echo "Error: productsign failed"; exit 1; }
	@echo "📤 Notarizing, stapling, and verifying the .pkg…"
	@# The decrypted .p8 key is created here (only notarytool needs it) and a
	@# trap removes it on ANY exit of this shell — success or failure — so a
	@# failed notarize/staple/verify never leaves the sensitive key on disk.
	@test -f "$(SECRETS_JSON)" || { echo "Error: $(SECRETS_JSON) not found"; exit 1; }
	@sh -c 'trap "rm -f \"$(API_KEY_PATH)\"" EXIT; \
		mkdir -p "$(API_KEYS_DIR)"; \
		jq -r .apple_api_key "$(SECRETS_JSON)" | base64 -d > "$(API_KEY_PATH)" || { echo "Error: failed to decode API key"; exit 1; }; \
		xcrun notarytool submit "$(SIGNED_PKG)" \
			--key "$(API_KEY_PATH)" \
			--key-id "$(API_KEY_ID)" \
			--issuer "$(API_ISSUER)" \
			--wait || { echo "Error: notarization failed. Check the log URL above"; exit 1; }; \
		xcrun stapler staple "$(SIGNED_PKG)" || { echo "Error: stapler failed"; exit 1; }; \
		spctl -a -vvv -t install "$(SIGNED_PKG)"'
	@mv "$(SIGNED_PKG)" "$(FINAL_PKG)"
	@echo "✅ Installer ready: $(FINAL_PKG)"

pkg-release: ## Build .pkg and upload to GitHub Releases (usage: make pkg-release VERSION=1.0.0)
	@test -n "$(VERSION)" || { echo "Usage: make pkg-release VERSION=x.y.z"; exit 1; }
	@command -v gh >/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
	$(eval TAG := v$(VERSION))
	@echo "📝 Setting version to $(VERSION)…"
	@sed -i '' 's/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $(VERSION)/g' $(XCODEPROJ)/project.pbxproj
	@$(MAKE) pkg VERSION=$(VERSION)
	@echo "🏷️  Creating GitHub release $(TAG)…"
	@git tag $(TAG) || true
	@git push --no-verify origin $(TAG) || true
	@# One release per version, multiple artifacts: if the tag already has a release
	@# (e.g. brew-release uploaded the .zip), `create` fails and we `upload` the .pkg
	@# alongside the existing assets. --clobber only replaces the same-named .pkg on
	@# re-runs; it never touches the .zip or other differently-named assets.
	@gh release create $(TAG) --generate-notes "$(FINAL_PKG)" || \
		gh release upload $(TAG) "$(FINAL_PKG)" --clobber
	@echo "✅ Release $(VERSION) complete: $(FINAL_PKG)"

brew-clean: ## Clean up existing release tags, GitHub release, and homebrew cask (usage: make brew-clean VERSION=1.0.0)
	@test -n "$(VERSION)" || { echo "Usage: make brew-clean VERSION=1.0.0"; exit 1; }
	$(eval TAG := v$(VERSION))
	@echo "🧹 Cleaning up release $(TAG)..."
	@git tag -d $(TAG) 2>/dev/null || true
	@git push --no-verify --delete origin $(TAG) 2>/dev/null || true
	@gh release delete $(TAG) --yes 2>/dev/null || true
	@if [ -d "../homebrew-macos" ] && [ -f "../homebrew-macos/Casks/wispr.rb" ]; then \
		echo "🍺 Reverting homebrew cask..."; \
		cd ../homebrew-macos && git pull --rebase origin main && \
		git log --oneline -1 -- Casks/wispr.rb | grep -q "$(VERSION)" && \
		git revert --no-edit HEAD && \
		git push --no-verify  origin main || echo "  (no matching cask commit to revert)"; \
	fi
	@echo "✅ Cleanup complete"

brew-release: ## Create Homebrew cask release (usage: make brew-release VERSION=1.0.0)
	@test -n "$(VERSION)" || { echo "Usage: make brew-release VERSION=1.0.0"; exit 1; }
	@test -d "../homebrew-macos" || { echo "Error: ../homebrew-macos not found"; exit 1; }
	@command -v gh >/dev/null || { echo "Error: gh CLI not installed"; exit 1; }
	$(eval TAG := v$(VERSION))
	$(eval ZIP_NAME := wispr-$(VERSION).zip)
	@echo "📝 Setting version to $(VERSION)..."
	@sed -i '' 's/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $(VERSION)/g' $(XCODEPROJ)/project.pbxproj
	@$(MAKE) notarize
	@echo "🗜️  Creating release zip..."
	@cp "$(ZIP_PATH)" "$(EXPORT_DIR)/$(ZIP_NAME)"
	@echo "🏷️  Creating GitHub release..."
	@git tag $(TAG) || true
	@git push --no-verify origin $(TAG) || true
	@gh release create $(TAG) --generate-notes $(EXPORT_DIR)/$(ZIP_NAME) || \
		gh release upload $(TAG) $(EXPORT_DIR)/$(ZIP_NAME)
	$(eval URL := https://github.com/sebsto/wispr/releases/download/$(TAG)/$(ZIP_NAME))
	@echo "🍺 Generating cask..."
	@echo "cask \"wispr\" do" > wispr.rb
	@echo "  version \"$(VERSION)\"" >> wispr.rb
	@echo "  sha256 \"$$(shasum -a 256 $(EXPORT_DIR)/$(ZIP_NAME) | awk '{print $$1}')\"" >> wispr.rb
	@echo "" >> wispr.rb
	@echo "  url \"$(URL)\"" >> wispr.rb
	@echo "  name \"Wispr\"" >> wispr.rb
	@echo "  desc \"Local speech-to-text transcription powered by OpenAI Whisper\"" >> wispr.rb
	@echo "  homepage \"https://github.com/sebsto/wispr\"" >> wispr.rb
	@echo "" >> wispr.rb
	@echo "  app \"Wispr.app\"" >> wispr.rb
	@echo "end" >> wispr.rb
	@echo "📦 Updating homebrew tap..."
	@cd ../homebrew-macos && git pull --rebase origin main
	@mkdir -p ../homebrew-macos/Casks
	@cd ../homebrew-macos && git pull
	@cp wispr.rb ../homebrew-macos/Casks/
	@cd ../homebrew-macos && git add Casks/wispr.rb && \
		git commit -m "Update wispr to $(VERSION)" && \
		git push --no-verify origin main
	@rm -f wispr.rb
	@echo "✅ Release $(VERSION) complete!"

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

list-downloads: ## List all downloaded models (Whisper + Parakeet) in the sandbox container
	@echo "Downloaded models in $(MODEL_DIR):"
	@echo ""
	@echo "— Whisper (WhisperKit) —"
	@du -sh "$(MODEL_DIR)"/models/argmaxinc/whisperkit-coreml/*/ 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "— Parakeet V3 (FluidAudio) —"
	@du -sh "$(MODEL_DIR)"/models/parakeet-tdt*/ 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "— Parakeet EOU (FluidAudio) —"
	@du -sh "$(MODEL_DIR)"/models/parakeet-eou-streaming/ 2>/dev/null || echo "  (none)"

clean-downloads: ## Delete all downloaded models (Whisper + Parakeet) from the sandbox container
	@if [ -d "$(MODEL_DIR)" ]; then \
		echo "Removing downloaded models at $(MODEL_DIR) …"; \
		rm -rf "$(MODEL_DIR)"; \
	else \
		echo "No downloaded models to clean."; \
	fi
	@# Clean legacy FluidAudio location in case models were downloaded before unification
	@if [ -d "$(CONTAINER)/Library/Application Support/FluidAudio" ]; then \
		echo "Removing legacy FluidAudio model cache …"; \
		rm -rf "$(CONTAINER)/Library/Application Support/FluidAudio"; \
		echo "Done."; \
	fi

list-container: ## Inspect the sandbox container directory
	@if [ -d "$(CONTAINER)" ]; then \
		echo "Sandbox container at $(CONTAINER):"; \
		ls -la "$(CONTAINER)/Library/Application Support/wispr/" 2>/dev/null || echo "  (empty or missing)"; \
	else \
		echo "No sandbox container found at $(CONTAINER)"; \
	fi

list-prefs: ## Show current UserDefaults for the app
	@echo "— Standard (non-sandboxed) —"
	@defaults read $(BUNDLE_ID) 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "— Sandboxed (container) —"
	@plutil -p "$(CONTAINER)/Library/Preferences/$(BUNDLE_ID).plist" 2>/dev/null || echo "  (none)"

clean-prefs: ## Delete all UserDefaults for the app
	@echo "Removing preferences for $(BUNDLE_ID) …"
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@rm -f "$(CONTAINER)/Library/Preferences/$(BUNDLE_ID).plist" 2>/dev/null || true
	@killall cfprefsd 2>/dev/null || true
	@echo "Done."

reset-permissions: ## Reset microphone and accessibility permissions for the app
	@echo "Resetting Microphone permission …"
	@tccutil reset Microphone $(BUNDLE_ID) 2>/dev/null || true
	@echo "Resetting Accessibility permission …"
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	@echo "Done. Restart the app to be prompted again."

reset-login-item: ## Reset Background Task Management database (clears all login items)
	@echo "Resetting BTM database (clears all SMAppService login items) …"
	@sfltool resetbtm 2>/dev/null || true
	@echo "Done. The app will no longer launch at login."

reset-onboarding: ## Full onboarding reset (permissions + prefs + models + login item)
	@echo "=== Full onboarding reset ==="
	@$(MAKE) -s reset-permissions
	@$(MAKE) -s clean-prefs
	@$(MAKE) -s clean-downloads
	@$(MAKE) -s reset-login-item
	@echo "=== Ready to re-test onboarding ==="
