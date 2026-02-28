# wispr — Developer Makefile
#
# Handy targets for inspecting and cleaning local app data.

BUNDLE_ID    := com.stormacq.mac.wispr
CONTAINER    := $(HOME)/Library/Containers/$(BUNDLE_ID)/Data
MODEL_DIR    := $(CONTAINER)/Library/Application Support/wispr

SCHEME       := wispr
XCODEPROJ    := wispr.xcodeproj

.PHONY: help bump-build archive list-downloads clean-downloads list-container list-prefs clean-prefs reset-permissions reset-onboarding

bump-build: ## Set build number to YYMMDD-<commit count>
	$(eval BUILD_NUM := $(shell date +%y%m%d)-$(shell git rev-list --count HEAD))
	@xcrun agvtool new-version -all $(BUILD_NUM) > /dev/null
	@echo "Build number set to $(BUILD_NUM)"

archive: bump-build ## Bump build number and create Release archive
	xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -configuration Release archive

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

list-downloads: ## List downloaded Whisper models in the sandbox container
	@if [ -d "$(MODEL_DIR)" ]; then \
		echo "Downloaded models in $(MODEL_DIR):"; \
		du -sh "$(MODEL_DIR)"/models/argmaxinc/whisperkit-coreml/*/ 2>/dev/null || echo "  (none)"; \
	else \
		echo "No model directory found at $(MODEL_DIR)"; \
	fi

clean-downloads: ## Delete all downloaded Whisper models from the sandbox container
	@if [ -d "$(MODEL_DIR)" ]; then \
		echo "Removing $(MODEL_DIR) …"; \
		rm -rf "$(MODEL_DIR)"; \
		echo "Done."; \
	else \
		echo "Nothing to clean — $(MODEL_DIR) does not exist."; \
	fi

list-container: ## Inspect the sandbox container directory
	@if [ -d "$(CONTAINER)" ]; then \
		echo "Sandbox container at $(CONTAINER):"; \
		ls -la "$(CONTAINER)/Library/Application Support/wispr/" 2>/dev/null || echo "  (empty or missing)"; \
	else \
		echo "No sandbox container found at $(CONTAINER)"; \
	fi

list-prefs: ## Show current UserDefaults for the app
	@defaults read $(BUNDLE_ID) 2>/dev/null || echo "No preferences found for $(BUNDLE_ID)."

clean-prefs: ## Delete all UserDefaults for the app
	@echo "Removing preferences for $(BUNDLE_ID) …"
	@defaults delete $(BUNDLE_ID) 2>/dev/null || true
	@echo "Done."

reset-permissions: ## Reset microphone and accessibility permissions for the app
	@echo "Resetting Microphone permission …"
	@tccutil reset Microphone $(BUNDLE_ID) 2>/dev/null || true
	@echo "Resetting Accessibility permission …"
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	@echo "Done. Restart the app to be prompted again."

reset-onboarding: ## Full onboarding reset (permissions + prefs + models)
	@echo "=== Full onboarding reset ==="
	@$(MAKE) -s reset-permissions
	@$(MAKE) -s clean-prefs
	@$(MAKE) -s clean-downloads
	@echo "=== Ready to re-test onboarding ==="
