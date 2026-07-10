import Testing
@testable import InfSketchServerKit

@Suite struct ServerInfoTests {
    @Test func serverInfoHasVersion() {
        #expect(ServerInfo.version == "0.1.0")
    }
}
