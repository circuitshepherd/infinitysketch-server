import Testing
@testable import InfSketchServerKit

@Suite struct ServerInfoTests {
    /// The literal is what the banner prints and what MCP `initialize` reports. It is NOT pinned to
    /// a value here — a test that repeats the literal only forces two edits per release and catches
    /// nothing. What ties it to the release tag is `scripts/check-release-version`, run before
    /// tagging and by the Windows workflow on every `v*` tag.
    @Test func versionIsSemver() {
        let parts = ServerInfo.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3, "expected MAJOR.MINOR.PATCH, got \(ServerInfo.version)")
        #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }
}
