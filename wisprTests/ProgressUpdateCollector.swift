//
//  ProgressUpdateCollector.swift
//  wisprTests
//
//  Thread-safe collector for `ProgressUpdate` handler invocations.
//

import Synchronization
import WisprCore

/// Records every `ProgressUpdate` a handler receives.
///
/// `nonisolated` because the package builds with `MainActor` default isolation,
/// and the handler is `@Sendable` and called from the engine's own context.
nonisolated final class ProgressUpdateCollector: Sendable {
    private let store = Mutex<[ProgressUpdate]>([])

    func record(_ update: ProgressUpdate) {
        store.withLock { $0.append(update) }
    }

    var updates: [ProgressUpdate] {
        store.withLock { $0 }
    }
}
