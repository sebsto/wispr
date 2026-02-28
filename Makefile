# wispr — Developer Makefile
#
# Handy targets for inspecting and cleaning local app data.

BUNDLE_ID    := com.stormacq.app.macos.wispr
CONTAINER    := $(HOME)/Library/Containers/$(BUNDLE_ID)/Data
MODEL_DIR    := $(CONTAINER)/Library/Application Support/wispr

.PHONY: help list-downloads clean-downloads list-container list-prefs clean-prefs

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
