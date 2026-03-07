//
//  SemanticVersion.swift
//  wispr
//
//  Parses version strings like "v1.0.6" or "1.0.6" into comparable components.
//

import Foundation

struct SemanticVersion: Comparable, Sendable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(string: String) {
        var cleaned = string
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned = String(cleaned.dropFirst())
        }
        let parts = cleaned.split(separator: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
