import Foundation
import Testing
@testable import InfSketchServerKit

/// `render_sketch(writeToFile: true)` hands the PNG to disk instead of returning it inline, so
/// something has to own those files. The agent does not: it has no reason to remember, and a long
/// session leaves dozens behind.
///
/// So the store names the file (an agent-chosen path could not be pruned by anyone but the agent)
/// and bounds the directory, evicting oldest-first. Renders are scratch, not user data — the trash's
/// 30-day retention is the wrong shape here; the telemetry file's byte cap is the right one.
struct RenderFileStoreTests {

    private func makeStore(byteBudget: Int = 64 * 1024 * 1024) throws -> (RenderFileStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-store-\(UUID().uuidString)", isDirectory: true)
        return (RenderFileStore(directory: dir, byteBudget: byteBudget), dir)
    }

    private func pngFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".png") }
            .sorted()
    }

    @Test func writeStoresTheBytesAndReturnsAPathThatExists() throws {
        let (store, dir) = try makeStore()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD])

        let url = try store.write(docId: "Rainfall", png: png)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == png)
        #expect(url.pathExtension == "png")
        #expect(url.lastPathComponent.hasPrefix("Rainfall_"))
        #expect(pngFiles(dir).count == 1)
    }

    /// The path has to be absolute: the agent reads it from a tool reply and hands it to some other
    /// program, which has no idea what the server's working directory is. `add_image` refuses a
    /// relative path for the same reason rather than resolving one.
    @Test func theReturnedPathIsAbsolute() throws {
        let (store, _) = try makeStore()
        let url = try store.write(docId: "d", png: Data([1, 2, 3]))
        #expect(url.path.hasPrefix("/"))
    }

    /// Oldest-first eviction, so what survives is the RECENT past — the same reasoning the telemetry
    /// file's rotation rests on. Budget is deliberately in BYTES, not a file count: one 4-megapixel
    /// render is worth hundreds of thumbnails and a count would let a handful of them fill a disk.
    @Test func writesPastTheByteBudgetEvictOldestFirst() throws {
        let (store, dir) = try makeStore(byteBudget: 300)
        let hundred = Data(repeating: 0xAB, count: 100)
        // The clock is injected rather than read, so the ordering under test is exact instead of
        // depending on how many writes land inside one filesystem timestamp tick.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try store.write(docId: "a", png: hundred, now: t0)
        let second = try store.write(docId: "b", png: hundred, now: t0.addingTimeInterval(1))
        let third = try store.write(docId: "c", png: hundred, now: t0.addingTimeInterval(2))
        // Still inside the budget: three files at 100 bytes each.
        #expect(pngFiles(dir).count == 3)

        let fourth = try store.write(docId: "e", png: hundred, now: t0.addingTimeInterval(3))

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
        #expect(FileManager.default.fileExists(atPath: fourth.path))
        #expect(pngFiles(dir).count == 3)
    }

    /// A single render larger than the whole budget still has to be written — the caller asked for
    /// it and a silently-absent file is worse than an over-budget directory. It simply arrives with
    /// the directory swept clean behind it.
    @Test func aRenderBiggerThanTheBudgetIsStillWritten() throws {
        let (store, dir) = try makeStore(byteBudget: 50)
        let big = Data(repeating: 0xAB, count: 500)

        let url = try store.write(docId: "a", png: big)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(pngFiles(dir).count == 1)
    }

    /// Two renders inside the same millisecond must not collide — the stamp alone is not unique
    /// enough, which is why the pre-merge backup names carry a random token too.
    @Test func twoWritesAtTheSameInstantDoNotOverwriteEachOther() throws {
        let (store, dir) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let a = try store.write(docId: "same", png: Data([1]), now: now)
        let b = try store.write(docId: "same", png: Data([2]), now: now)

        #expect(a != b)
        #expect(pngFiles(dir).count == 2)
    }

    /// A docId is a filename stem and the server already refuses one carrying path separators, but
    /// this store builds a path of its own — so it must not be the door that reintroduces `..`.
    @Test func aDocIdCannotEscapeTheRenderDirectory() throws {
        let (store, dir) = try makeStore()

        let url = try store.write(docId: "../../escape", png: Data([1]))

        #expect(url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(!url.lastPathComponent.contains("/"))
        #expect(pngFiles(dir).count == 1)
    }

    /// The directory is created on demand: a server that never renders to a file should not leave an
    /// empty dot-directory beside the documents.
    @Test func theDirectoryIsNotCreatedUntilSomethingIsWritten() throws {
        let (store, dir) = try makeStore()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        _ = try store.write(docId: "d", png: Data([1]))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
