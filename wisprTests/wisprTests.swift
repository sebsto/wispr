//
//  wisprTests.swift
//  wisprTests
//
//  Created by Stormacq, Sebastien on 26/02/2026.
//

import Testing
import Foundation
#if SWIFT_PACKAGE
@testable import WisprApp
import WisprCore
#else
@testable import wispr
#endif

nonisolated let isLocalTestEnvironment = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil
