import Foundation
import Testing
@testable import WisprCore

@Suite("EnclosingAppBundle")
struct EnclosingAppBundleTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("finds the app that contains a nested executable")
    func findsApp() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("Wispr.app/Contents/Resources/bin/WisprCLI")

        #expect(EnclosingAppBundle.url(containing: exe)?.lastPathComponent == "Wispr.app")
    }

    @Test("resolves a symlinked executable into its app")
    func resolvesSymlink() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("Wispr.app/Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let real = binDir.appendingPathComponent("WisprCLI")
        try Data().write(to: real)
        let link = root.appendingPathComponent("wispr")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(EnclosingAppBundle.url(containing: link)?.lastPathComponent == "Wispr.app")
    }

    @Test("returns nil for an executable outside any app")
    func noApp() {
        #expect(EnclosingAppBundle.url(containing: URL(fileURLWithPath: "/usr/local/bin/wispr")) == nil)
    }
}
