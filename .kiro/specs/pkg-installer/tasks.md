# Implementation Plan: pkg-installer

## Overview

Extend the existing Makefile build pipeline with `pkg` and `pkg-release` targets that produce a signed, notarized `.pkg` installer with custom UI. All installer resources (`pkg/distribution.xml`, `pkg/resources/`) are created as static files. The `secrets/notarization.json` schema is extended with an `installer_identity` field. Property-based tests use Python/Hypothesis.

## Tasks

- [ ] 1. Create installer resource files and distribution XML
  - [ ] 1.1 Create `pkg/resources/license.txt` by copying the repo root `LICENSE` file (Apache 2.0)
    - _Requirements: 2.7, 8.1, 8.3_

  - [ ] 1.2 Create `pkg/resources/welcome.html` introducing Wispr and its key features
    - Brief HTML page: what Wispr is, on-device speech-to-text, privacy focus
    - Reference `README.md` for content inspiration
    - _Requirements: 2.5, 8.1, 8.3_

  - [ ] 1.3 Create `pkg/resources/readme.html` with system requirements and post-install steps
    - macOS 15.0+, microphone permission, model download on first launch
    - _Requirements: 2.6, 8.1, 8.3_

  - [ ] 1.4 Create `pkg/resources/background.png` placeholder
    - Create a simple branded background image (660×440 PNG) using the Wispr project color palette
    - Reference `artwork/icon.svg` and `artwork/icon-square.svg` for branding
    - _Requirements: 2.4, 8.1, 8.3_

  - [ ] 1.5 Create `pkg/distribution.xml` defining the installer flow
    - Single choice element installing Wispr to `/Applications`
    - Reference background, welcome, readme, and license from resources
    - `customize="never"`, `require-scripts="false"`
    - `pkg-ref` identifier `com.stormacq.mac.wispr`
    - Use the exact XML structure from the design document
    - _Requirements: 2.1, 2.2, 2.3, 8.2_

- [ ] 2. Checkpoint — Verify installer resources
  - Ensure all four resource files exist in `pkg/resources/` and `pkg/distribution.xml` is valid XML. Ask the user if questions arise.

- [ ] 3. Extend Makefile with `pkg` target
  - [ ] 3.1 Add new Makefile variables for the pkg pipeline
    - `INSTALLER_IDENTITY` read from `$(NOTARIZATION_JSON)` via `jq -r .installer_identity`
    - `COMPONENT_PKG`, `PRODUCT_PKG`, `SIGNED_PKG`, `FINAL_PKG` derived paths in `$(EXPORT_DIR)`
    - `PKG_RESOURCES` pointing to `$(CURDIR)/pkg/resources`
    - `DISTRIBUTION_XML` pointing to `$(CURDIR)/pkg/distribution.xml`
    - Reuse all existing variables (`BUNDLE_ID`, `SIGNING_IDENTITY`, `APP_PATH`, `EXPORT_DIR`, `ARCHIVE_PATH`, `API_KEY_PATH`, `API_KEY_ID`, `API_ISSUER`, `NOTARIZATION_JSON`)
    - _Requirements: 5.6, 7.1, 7.2_

  - [ ] 3.2 Add resource file validation step to the `pkg` target recipe
    - Check that `pkg/distribution.xml`, `pkg/resources/background.png`, `pkg/resources/welcome.html`, `pkg/resources/readme.html`, `pkg/resources/license.txt` all exist
    - Print error message naming the missing file and `exit 1` if any is absent
    - _Requirements: 8.4_

  - [ ] 3.3 Add `installer_identity` validation step
    - Read `INSTALLER_IDENTITY` from `$(NOTARIZATION_JSON)` and verify it is non-empty
    - Print `Error: installer_identity not found in <path>` and `exit 1` if missing
    - _Requirements: 7.2, 7.3_

  - [ ] 3.4 Add `pkgbuild` step to create the component package
    - `pkgbuild --root <app parent> --install-location /Applications --identifier $(BUNDLE_ID) --version $(VERSION) $(COMPONENT_PKG)`
    - Error handling: `|| { echo "Error: pkgbuild failed"; exit 1; }`
    - _Requirements: 1.1, 1.2, 1.3, 1.4_

  - [ ] 3.5 Add `productbuild` step to create the product package with custom UI
    - `productbuild --distribution $(DISTRIBUTION_XML) --resources $(PKG_RESOURCES) --package-path $(EXPORT_DIR) $(PRODUCT_PKG)`
    - Error handling: `|| { echo "Error: productbuild failed"; exit 1; }`
    - _Requirements: 2.1, 2.8_

  - [ ] 3.6 Add `productsign` step to sign the product package
    - `productsign --sign "$(INSTALLER_IDENTITY)" $(PRODUCT_PKG) $(SIGNED_PKG)`
    - Error handling: `|| { echo "Error: productsign failed"; exit 1; }`
    - _Requirements: 3.1, 3.2, 3.4_

  - [ ] 3.7 Add notarization, stapling, and verification steps for the signed package
    - Reuse `_setup-api-key` and `_cleanup-api-key` for API key management
    - `notarytool submit` with `--key`, `--key-id`, `--issuer`, `--wait`
    - `stapler staple` on the signed package
    - `spctl -a -vvv -t install` to verify
    - Error handling for notarization (print log URL), stapling, and verification failures
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 5.5_

  - [ ] 3.8 Add final rename and summary output
    - Rename signed+stapled package to `wispr-$(VERSION).pkg` in `$(EXPORT_DIR)`
    - Print summary line with the path to the final package
    - Wire the `pkg` target to depend on `notarize` (existing target)
    - Ensure `pkg` does NOT duplicate any archive, app-signing, or notarization logic from `notarize`
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.7_

- [ ] 4. Checkpoint — Verify `pkg` target structure
  - Ensure the `pkg` target is defined, depends on `notarize`, and does not duplicate existing logic. Ask the user if questions arise.

- [ ] 5. Extend Makefile with `pkg-release` target
  - [ ] 5.1 Add `pkg-release` target with VERSION validation and `gh` CLI check
    - Print usage message and `exit 1` if `VERSION` is not provided
    - Print error and `exit 1` if `gh` CLI is not installed
    - _Requirements: 6.5, 6.6_

  - [ ] 5.2 Add version setting and `pkg` invocation
    - Set `MARKETING_VERSION` in the Xcode project via `sed` (mirror `brew-release` pattern)
    - Call `make pkg` to produce the signed and notarized package
    - _Requirements: 6.1, 6.2_

  - [ ] 5.3 Add GitHub Release creation and asset upload
    - Create or update GitHub Release tagged `v<VERSION>`
    - Upload `.pkg` as release asset alongside existing assets (do not remove them)
    - Mirror the `brew-release` pattern for `gh release create` / `gh release upload`
    - _Requirements: 6.3, 6.4_

- [ ] 6. Document `installer_identity` field in `secrets/notarization.json`
  - Add a comment or update project documentation noting the new `installer_identity` field
  - Provide the expected JSON schema: `"installer_identity": "Developer ID Installer: [name] ([team_id])"`
  - _Requirements: 7.1_

- [ ] 7. Checkpoint — Verify full Makefile integration
  - Ensure `pkg` and `pkg-release` targets are defined and follow existing Makefile patterns. Ensure all tests pass, ask the user if questions arise.

- [ ] 8. Property-based tests (Python/Hypothesis)
  - [ ]* 8.1 Write property test for installer identity extraction round trip
    - **Property 1: Installer identity extraction round trip**
    - Generate random valid JSON with a non-empty `installer_identity` string, write to temp file, extract via `jq -r .installer_identity`, assert output matches original
    - **Validates: Requirements 3.2, 7.2**

  - [ ]* 8.2 Write property test for output package filename version pattern
    - **Property 2: Output package filename follows version pattern**
    - Generate random semver strings `X.Y.Z`, construct expected filename `wispr-X.Y.Z.pkg`, assert it matches the pattern and is rooted in `build/export/`
    - **Validates: Requirements 5.2**

  - [ ]* 8.3 Write property test for marketing version injection
    - **Property 3: Marketing version injection**
    - Generate random semver strings and a `.pbxproj` snippet with `MARKETING_VERSION = <old>;`, run the `sed` substitution, assert all `MARKETING_VERSION` entries equal the new version
    - **Validates: Requirements 6.1**

  - [ ]* 8.4 Write property test for missing resource file detection
    - **Property 4: Missing resource file detection**
    - For each file in {`background.png`, `welcome.html`, `readme.html`, `license.txt`}, create a temp `pkg/resources/` with that file removed, run the validation check, assert error message contains the missing filename
    - **Validates: Requirements 8.4**

- [ ] 9. Final checkpoint — Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- The user is responsible for obtaining the Developer ID Installer certificate
- The `background.png` in task 1.4 may need manual refinement for production quality
- Property tests use Python/Hypothesis and can be run with `pytest`
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
