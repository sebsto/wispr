# Requirements Document

## Introduction

Wispr is distributed via the App Store and Homebrew. This feature adds a third distribution channel: a signed and notarized Apple `.pkg` installer with a custom installer UI. The `.pkg` installs Wispr.app to `/Applications` and is uploaded to GitHub Releases alongside the existing Homebrew zip. The build flow reuses the existing archive and notarization pipeline and extends the Makefile with new targets.

## Glossary

- **Build_Pipeline**: The set of Makefile targets that archive, sign, notarize, and release the Wispr app
- **Component_Pkg**: An intermediate `.pkg` file created by `pkgbuild` containing the app bundle and install location metadata
- **Product_Pkg**: The final user-facing `.pkg` installer created by `productbuild` from a Component_Pkg and a distribution XML, with custom installer UI screens
- **Distribution_XML**: An XML file that defines the Product_Pkg installer flow, including title, background, welcome, readme, license, and install choices
- **Installer_Resources**: Static files (background image, welcome text, readme text, license) displayed during the Product_Pkg installation wizard
- **Installer_Identity**: The "Developer ID Installer" signing certificate used to sign `.pkg` files for distribution outside the App Store
- **Notarization_Config**: The `secrets/notarization.json` file containing Apple ID, team ID, and signing identity values used by the Build_Pipeline
- **GitHub_Release**: A versioned release on GitHub containing downloadable artifacts (zip, pkg) and auto-generated release notes

## Requirements

### Requirement 1: Build Component Package

**User Story:** As a developer, I want to create a component `.pkg` from the notarized app bundle, so that I have the building block for the final installer.

#### Acceptance Criteria

1. WHEN the `make pkg` target is invoked, THE Build_Pipeline SHALL archive and notarize the app using the existing `notarize` target before creating the Component_Pkg
2. WHEN the notarized app is available, THE Build_Pipeline SHALL invoke `pkgbuild` to create a Component_Pkg that installs Wispr.app to `/Applications`
3. THE Build_Pipeline SHALL set the Component_Pkg bundle identifier to `com.stormacq.mac.wispr` and the version to the current marketing version
4. IF `pkgbuild` exits with a non-zero status, THEN THE Build_Pipeline SHALL print an error message and stop execution

### Requirement 2: Build Product Package with Custom Installer UI

**User Story:** As a developer, I want to wrap the component package into a product installer with branded UI screens, so that users see a polished installation experience.

#### Acceptance Criteria

1. WHEN the Component_Pkg is available, THE Build_Pipeline SHALL invoke `productbuild` with the Distribution_XML and Installer_Resources to create the Product_Pkg
2. THE Distribution_XML SHALL define a single choice element that installs the Wispr component to `/Applications`
3. THE Distribution_XML SHALL reference a background image, a welcome screen, a readme screen, and a license screen from the Installer_Resources
4. THE Installer_Resources SHALL include a background image that uses the Wispr project color palette
5. THE Installer_Resources SHALL include a welcome HTML or text file introducing Wispr and its key features
6. THE Installer_Resources SHALL include a readme HTML or text file describing system requirements and post-install steps
7. THE Installer_Resources SHALL include the project license file (Apache License 2.0)
8. IF `productbuild` exits with a non-zero status, THEN THE Build_Pipeline SHALL print an error message and stop execution

### Requirement 3: Sign the Product Package

**User Story:** As a developer, I want the final `.pkg` to be signed with my Developer ID Installer certificate, so that macOS Gatekeeper accepts the installer.

#### Acceptance Criteria

1. WHEN the Product_Pkg is created, THE Build_Pipeline SHALL sign the Product_Pkg using `productsign` with the Installer_Identity
2. THE Build_Pipeline SHALL read the Installer_Identity name from the Notarization_Config file
3. IF the Installer_Identity is not found in the keychain, THEN THE Build_Pipeline SHALL print an error message identifying the missing certificate and stop execution
4. IF `productsign` exits with a non-zero status, THEN THE Build_Pipeline SHALL print an error message and stop execution

### Requirement 4: Notarize and Staple the Product Package

**User Story:** As a developer, I want the signed `.pkg` to be notarized and stapled by Apple, so that users can install it without Gatekeeper warnings.

#### Acceptance Criteria

1. WHEN the Product_Pkg is signed, THE Build_Pipeline SHALL submit the signed Product_Pkg to Apple notarization via `notarytool` using the existing API key credentials
2. THE Build_Pipeline SHALL wait for the notarization result before proceeding
3. WHEN notarization succeeds, THE Build_Pipeline SHALL staple the notarization ticket to the signed Product_Pkg using `stapler`
4. WHEN stapling is complete, THE Build_Pipeline SHALL verify the Product_Pkg with `spctl` and print the verification result
5. IF notarization fails, THEN THE Build_Pipeline SHALL print the notarization log URL and stop execution
6. IF stapling fails, THEN THE Build_Pipeline SHALL print an error message and stop execution

### Requirement 5: Makefile `pkg` Target

**User Story:** As a developer, I want a single `make pkg` command that builds, signs, notarizes, and staples the `.pkg` installer, reusing as much of the existing Makefile infrastructure as possible, so that I can produce the artifact in one step without duplicating build logic.

#### Acceptance Criteria

1. THE Build_Pipeline SHALL provide a `pkg` Makefile target that executes the full flow: archive, notarize app, build Component_Pkg, build Product_Pkg, sign Product_Pkg, notarize Product_Pkg, and staple Product_Pkg
2. WHEN `make pkg` completes successfully, THE Build_Pipeline SHALL output the final Product_Pkg to the `build/export/` directory with the filename `wispr-<VERSION>.pkg`
3. THE Build_Pipeline SHALL print a summary line with the path to the final Product_Pkg on successful completion
4. THE `pkg` target SHALL reuse the existing `notarize` target for the app archive and signing step
5. THE `pkg` target SHALL reuse the existing `_setup-api-key` and `_cleanup-api-key` targets for API key management
6. THE `pkg` target SHALL reuse the existing Makefile variables (`SIGNING_IDENTITY`, `API_KEY_PATH`, `API_KEY_ID`, `API_ISSUER`, `APP_PATH`, `EXPORT_DIR`, `ARCHIVE_PATH`) rather than redefining them
7. THE `pkg` target SHALL NOT duplicate any archive, app-signing, or notarization logic that already exists in the `notarize` target

### Requirement 6: Makefile `pkg-release` Target

**User Story:** As a developer, I want a `make pkg-release VERSION=x.y.z` command that builds the `.pkg` and uploads it to GitHub Releases, so that users can download the installer from the releases page.

#### Acceptance Criteria

1. WHEN `make pkg-release VERSION=x.y.z` is invoked, THE Build_Pipeline SHALL set the marketing version to the provided VERSION value in the Xcode project
2. THE Build_Pipeline SHALL invoke the `pkg` target to produce the signed and notarized Product_Pkg
3. WHEN the Product_Pkg is ready, THE Build_Pipeline SHALL create or update a GitHub Release tagged `v<VERSION>` and upload the Product_Pkg as a release asset
4. THE Build_Pipeline SHALL upload the Product_Pkg alongside any existing release assets without removing them
5. IF the VERSION parameter is not provided, THEN THE Build_Pipeline SHALL print a usage message and stop execution
6. IF the `gh` CLI tool is not installed, THEN THE Build_Pipeline SHALL print an error message and stop execution

### Requirement 7: Installer Identity Configuration

**User Story:** As a developer, I want the installer signing identity stored in the existing secrets configuration, so that the build pipeline can reference it consistently.

#### Acceptance Criteria

1. THE Notarization_Config SHALL include an `installer_identity` field containing the Developer ID Installer certificate name
2. THE Build_Pipeline SHALL read the `installer_identity` value from the Notarization_Config using `jq`
3. IF the `installer_identity` field is missing from the Notarization_Config, THEN THE Build_Pipeline SHALL print an error message specifying the expected field name and stop execution

### Requirement 8: Installer Resource Files

**User Story:** As a developer, I want the installer resource files stored in a dedicated directory in the repository, so that they are version-controlled and easy to maintain.

#### Acceptance Criteria

1. THE Build_Pipeline SHALL read Installer_Resources from a `pkg/resources/` directory at the repository root
2. THE Build_Pipeline SHALL read the Distribution_XML from `pkg/distribution.xml` at the repository root
3. THE `pkg/resources/` directory SHALL contain the background image, welcome file, readme file, and license file
4. WHEN any required Installer_Resources file is missing, THE Build_Pipeline SHALL print an error message listing the missing file and stop execution
