import Testing
@testable import InfSketchServerKit

@Suite struct ServerInfoTests {
    @Test func serverInfoHasVersion() {
        #expect(ServerInfo.version == "1.0.0")
    }
}
