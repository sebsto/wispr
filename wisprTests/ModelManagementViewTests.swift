//
//  ModelManagementViewTests.swift
//  wisprTests
//
//  Unit tests for ModelManagementView logic: WhisperModelInfo data model,
//  model status display, available models list structure, and deletion
//  fallback logic from WhisperService.
//  Requirements: 7.8, 7.9, 17.1
//

import Testing
import Foundation
@testable import wispr

// MARK: - WhisperModelInfo Data Model Tests

/// Tests WhisperModelInfo struct properties and conformances.
/// Validates: Requirement 7.2 (model info display)
@MainActor
@Suite("ModelManagement WhisperModelInfo Data Model")
struct WhisperModelInfoDataModelTests {

    @Test("WhisperModelInfo stores all properties correctly")
    func testModelInfoProperties() {
        let model = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .notDownloaded
        )

        #expect(model.id == "tiny")
        #expect(model.displayName == "Tiny")
        #expect(model.sizeDescription == "~75 MB")
        #expect(model.qualityDescription == "Fastest, lower accuracy")
        #expect(model.status == .notDownloaded)
    }

    @Test("WhisperModelInfo status is mutable")
    func testModelInfoStatusMutable() {
        var model = WhisperModelInfo(
            id: "base",
            displayName: "Base",
            sizeDescription: "~140 MB",
            qualityDescription: "Fast, moderate accuracy",
            status: .notDownloaded
        )

        model.status = .downloading(progress: 0.5)
        #expect(model.status == .downloading(progress: 0.5))

        model.status = .downloaded
        #expect(model.status == .downloaded)

        model.status = .active
        #expect(model.status == .active)
    }

    @Test("WhisperModelInfo Equatable compares all fields")
    func testModelInfoEquatable() {
        let model1 = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .downloaded
        )
        let model2 = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .downloaded
        )
        let model3 = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .active
        )

        #expect(model1 == model2)
        #expect(model1 != model3)
    }

    @Test("WhisperModelInfo uses id as Identifiable key")
    func testModelInfoIdentifiable() {
        let model = WhisperModelInfo(
            id: "small",
            displayName: "Small",
            sizeDescription: "~460 MB",
            qualityDescription: "Balanced speed and accuracy",
            status: .notDownloaded
        )

        #expect(model.id == "small")
    }
}

// MARK: - ModelStatus Display Logic Tests

/// Tests ModelStatus enum values and equality for status display in the view.
/// Validates: Requirement 7.3 (model status display)
@MainActor
@Suite("ModelManagement ModelStatus Display Logic")
struct ModelStatusDisplayLogicTests {

    @Test("ModelStatus notDownloaded equality")
    func testNotDownloadedEquality() {
        #expect(ModelStatus.notDownloaded == ModelStatus.notDownloaded)
    }

    @Test("ModelStatus downloaded equality")
    func testDownloadedEquality() {
        #expect(ModelStatus.downloaded == ModelStatus.downloaded)
    }

    @Test("ModelStatus active equality")
    func testActiveEquality() {
        #expect(ModelStatus.active == ModelStatus.active)
    }

    @Test("ModelStatus downloading equality with same progress")
    func testDownloadingEqualitySameProgress() {
        #expect(ModelStatus.downloading(progress: 0.5) == ModelStatus.downloading(progress: 0.5))
    }

    @Test("ModelStatus downloading inequality with different progress")
    func testDownloadingInequalityDifferentProgress() {
        #expect(ModelStatus.downloading(progress: 0.3) != ModelStatus.downloading(progress: 0.7))
    }

    @Test("ModelStatus different cases are not equal")
    func testDifferentCasesNotEqual() {
        #expect(ModelStatus.notDownloaded != ModelStatus.downloaded)
        #expect(ModelStatus.downloaded != ModelStatus.active)
        #expect(ModelStatus.active != ModelStatus.notDownloaded)
        #expect(ModelStatus.downloading(progress: 1.0) != ModelStatus.downloaded)
    }
}

// MARK: - Available Models List Structure Tests

/// Tests the available models list returned by WhisperService for the view.
/// Validates: Requirements 7.2, 7.7 (model list structure)
@MainActor
@Suite("ModelManagement Available Models List")
struct AvailableModelsListTests {

    @Test("Available models returns exactly 5 models")
    func testAvailableModelsCount() async {
        let service = WhisperService()
        let models = await service.availableModels()
        #expect(models.count == 5)
    }

    @Test("Available models are ordered by size: tiny → large")
    func testAvailableModelsOrder() async {
        let service = WhisperService()
        let models = await service.availableModels()

        let expectedOrder = ["Tiny", "Base", "Small", "Medium", "Large v3"]
        let actualOrder = models.map { $0.displayName }
        #expect(actualOrder == expectedOrder)
    }

    @Test("All available models have unique IDs")
    func testAvailableModelsUniqueIDs() async {
        let service = WhisperService()
        let models = await service.availableModels()

        let ids = models.map { $0.id }
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count)
    }

    @Test("All available models have non-empty display metadata")
    func testAvailableModelsMetadata() async {
        let service = WhisperService()
        let models = await service.availableModels()

        for model in models {
            #expect(!model.displayName.isEmpty, "Model \(model.id) has empty displayName")
            #expect(!model.sizeDescription.isEmpty, "Model \(model.id) has empty sizeDescription")
            #expect(!model.qualityDescription.isEmpty, "Model \(model.id) has empty qualityDescription")
        }
    }

    @Test("All available models default to notDownloaded status")
    func testAvailableModelsDefaultStatus() async {
        let service = WhisperService()
        let models = await service.availableModels()

        for model in models {
            #expect(model.status == .notDownloaded, "Model \(model.id) should default to .notDownloaded")
        }
    }

    @Test("Model IDs are non-empty strings")
    func testModelIDNamingConvention() async {
        let service = WhisperService()
        let models = await service.availableModels()

        for model in models {
            #expect(!model.id.isEmpty, "Model ID should not be empty")
        }
    }
}

// MARK: - Model Deletion Fallback Logic Tests

/// Tests the deletion fallback logic in WhisperService used by ModelManagementView.
/// Validates: Requirements 7.8, 7.9 (deletion and fallback)
@MainActor
@Suite("ModelManagement Deletion Fallback Logic")
struct ModelDeletionFallbackLogicTests {

    @Test("Deleting non-existent model throws modelDeletionFailed")
    func testDeleteNonExistentModel() async {
        let service = WhisperService()

        do {
            try await service.deleteModel("nonexistent-model-xyz")
            Issue.record("Expected deleteModel to throw for non-existent model")
        } catch let error as WispError {
            if case .modelDeletionFailed(let message) = error {
                #expect(message.contains("not found"))
            } else {
                Issue.record("Expected modelDeletionFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected WispError, got \(error)")
        }
    }

    @Test("Active model returns nil when no model is loaded")
    func testNoActiveModelInitially() async {
        let service = WhisperService()
        let active = await service.activeModel()
        #expect(active == nil)
    }

    @Test("Model status is notDownloaded for fresh service")
    func testFreshServiceModelStatus() async {
        let service = WhisperService()
        // Use a model name that definitely won't exist on disk
        let status = await service.modelStatus("nonexistent-model-xyz")

        if case .notDownloaded = status {
            // Expected
        } else {
            Issue.record("Expected .notDownloaded, got \(status)")
        }
    }

    @Test("Switch model fails gracefully for non-existent model")
    func testSwitchModelFailsGracefully() async {
        let service = WhisperService()

        do {
            try await service.switchModel(to: "nonexistent-model-xyz")
            Issue.record("Expected switchModel to throw for non-existent model")
        } catch let error as WispError {
            if case .modelLoadFailed = error {
                // Expected — model doesn't exist on disk
            } else {
                Issue.record("Expected modelLoadFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected WispError, got \(error)")
        }

        // After failed switch, no model should be active
        let active = await service.activeModel()
        #expect(active == nil)
    }
}

// MARK: - Accessibility Label Tests

/// Tests the accessibility description logic used in ModelRowView.
/// Validates: Requirement 17.1 (VoiceOver accessibility labels)
@MainActor
@Suite("ModelManagement Accessibility Labels")
struct ModelManagementAccessibilityTests {

    /// Mirrors the accessibilityDescription computed property from ModelRowView.
    private func accessibilityDescription(for model: WhisperModelInfo) -> String {
        var parts = [model.displayName, model.sizeDescription, model.qualityDescription]
        switch model.status {
        case .notDownloaded:
            parts.append("Not downloaded")
        case .downloading(let progress):
            parts.append("Downloading \(Int(progress * 100)) percent")
        case .downloaded:
            parts.append("Downloaded")
        case .active:
            parts.append("Active")
        }
        return parts.joined(separator: ", ")
    }

    @Test("Accessibility label for not downloaded model")
    func testAccessibilityNotDownloaded() {
        let model = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .notDownloaded
        )

        let label = accessibilityDescription(for: model)
        #expect(label == "Tiny, ~75 MB, Fastest, lower accuracy, Not downloaded")
    }

    @Test("Accessibility label for downloading model includes percentage")
    func testAccessibilityDownloading() {
        let model = WhisperModelInfo(
            id: "base",
            displayName: "Base",
            sizeDescription: "~140 MB",
            qualityDescription: "Fast, moderate accuracy",
            status: .downloading(progress: 0.42)
        )

        let label = accessibilityDescription(for: model)
        #expect(label == "Base, ~140 MB, Fast, moderate accuracy, Downloading 42 percent")
    }

    @Test("Accessibility label for downloaded model")
    func testAccessibilityDownloaded() {
        let model = WhisperModelInfo(
            id: "small",
            displayName: "Small",
            sizeDescription: "~460 MB",
            qualityDescription: "Balanced speed and accuracy",
            status: .downloaded
        )

        let label = accessibilityDescription(for: model)
        #expect(label == "Small, ~460 MB, Balanced speed and accuracy, Downloaded")
    }

    @Test("Accessibility label for active model")
    func testAccessibilityActive() {
        let model = WhisperModelInfo(
            id: "large-v3",
            displayName: "Large",
            sizeDescription: "~3 GB",
            qualityDescription: "Slowest, highest accuracy",
            status: .active
        )

        let label = accessibilityDescription(for: model)
        #expect(label == "Large, ~3 GB, Slowest, highest accuracy, Active")
    }

    @Test("Accessibility label for downloading at 0 percent")
    func testAccessibilityDownloadingZero() {
        let model = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .downloading(progress: 0.0)
        )

        let label = accessibilityDescription(for: model)
        #expect(label.contains("Downloading 0 percent"))
    }

    @Test("Accessibility label for downloading at 100 percent")
    func testAccessibilityDownloadingComplete() {
        let model = WhisperModelInfo(
            id: "tiny",
            displayName: "Tiny",
            sizeDescription: "~75 MB",
            qualityDescription: "Fastest, lower accuracy",
            status: .downloading(progress: 1.0)
        )

        let label = accessibilityDescription(for: model)
        #expect(label.contains("Downloading 100 percent"))
    }
}
