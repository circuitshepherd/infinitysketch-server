import Foundation
import Testing
@testable import InfSketchServerKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/doc/<ref>` and `/api/docs/<ref>/frame` resolve `<ref>` through `SessionManager.resolveDocRef`
/// (spec 2026-09-28 §4): an id always works, a unique name works too, and a name shared by several
/// documents is a 409 rather than a guess. The viewer page is titled by the document's NAME — see
/// `WebViewerPageTests` for the id-in-script / name-in-title split itself.
@Suite struct ViewerRefTests {
    private func startServer(labelled: [String: String]) async throws -> (InfSketchServer, UInt16, Task<Void, any Error>) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-ref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DirectoryDocumentStore(directory: dir)
        for (id, name) in labelled {
            try store.save(docId: id, bytes: Fixtures.docBytes)
            try store.setName(name, for: id)
        }
        let server = InfSketchServer(port: 0, docsDirectory: dir)
        let task = Task { try await server.run() }
        try await server.waitUntilListening()
        return (server, try #require(await server.listeningPort), task)
    }

    @Test func theViewerPageIsTitledByTheName() async throws {
        let (server, port, task) = try await startServer(labelled: ["ID-1": "Chart"])
        defer { task.cancel() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/doc/ID-1")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("<title>Chart — infsketch</title>"))
        await server.stop()
    }

    @Test func aUniqueNameOpensTheViewerToo() async throws {
        let (server, port, task) = try await startServer(labelled: ["ID-1": "Chart"])
        defer { task.cancel() }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/doc/Chart")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await server.stop()
    }

    @Test func anAmbiguousNameIsAConflict() async throws {
        let (server, port, task) = try await startServer(labelled: ["ID-1": "Chart", "ID-2": "Chart"])
        defer { task.cancel() }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/doc/Chart")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 409)
        #expect(String(decoding: data, as: UTF8.self).contains("ID-1"))
        await server.stop()
    }
}
