import XCTest
import InfSketchWire
@testable import InfSketchServerKit

final class ProvideContentBrokerTests: XCTestCase {
    /// The request must go to the NAMED device, not merely any capable one.
    func testRequestGoesToTheNamedDevice() async throws {
        let broker = DeviceCommandBroker(createTimeout: .seconds(1), strokeOpTimeout: .seconds(1))
        let idA = UUID(), idB = UUID()
        actor Seen { var ids: [UUID] = []; func note(_ i: UUID) { ids.append(i) } }
        let seen = Seen()

        await broker.register(connectionId: idA, deviceId: "devA", capabilities: ["provideContent"]) { msg in
            if case .strokeOpRequest(let requestId, _, _, _) = msg {
                Task { await seen.note(idA); await broker.handleReply(
                    requestId: requestId, bytes: Data("A".utf8), failureReason: nil) }
            }
        }
        await broker.register(connectionId: idB, deviceId: "devB", capabilities: ["provideContent"]) { msg in
            if case .strokeOpRequest(let requestId, _, _, _) = msg {
                Task { await seen.note(idB); await broker.handleReply(
                    requestId: requestId, bytes: Data("B".utf8), failureReason: nil) }
            }
        }

        let bytes = try await broker.requestProvideContent(docId: "X", deviceId: "devA")
        XCTAssertEqual(bytes, Data("A".utf8))
        let ids = await seen.ids
        XCTAssertEqual(ids, [idA])
    }

    /// No connection for that deviceId → noDeviceAvailable (the caller falls back to the next holder).
    func testUnknownDeviceIdThrowsNoDeviceAvailable() async throws {
        let broker = DeviceCommandBroker(createTimeout: .seconds(1), strokeOpTimeout: .seconds(1))
        await broker.register(connectionId: UUID(), deviceId: "devA", capabilities: ["provideContent"]) { _ in }
        do {
            _ = try await broker.requestProvideContent(docId: "X", deviceId: "devGONE")
            XCTFail("expected noDeviceAvailable")
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            XCTAssertEqual(error, .noDeviceAvailable)
        }
    }

    /// A device that lacks the capability must not be selected even if the deviceId matches.
    func testMatchingDeviceWithoutCapabilityIsNotSelected() async throws {
        let broker = DeviceCommandBroker(createTimeout: .seconds(1), strokeOpTimeout: .seconds(1))
        await broker.register(connectionId: UUID(), deviceId: "devA", capabilities: ["authorStrokes"]) { _ in }
        do {
            _ = try await broker.requestProvideContent(docId: "X", deviceId: "devA")
            XCTFail("expected noDeviceAvailable")
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            XCTAssertEqual(error, .noDeviceAvailable)
        }
    }

    /// A device-reported failure propagates so the caller can try the next holder.
    func testDeviceFailurePropagates() async throws {
        let broker = DeviceCommandBroker(createTimeout: .seconds(1), strokeOpTimeout: .seconds(1))
        await broker.register(connectionId: UUID(), deviceId: "devA", capabilities: ["provideContent"]) { msg in
            if case .strokeOpRequest(let requestId, _, _, _) = msg {
                Task { await broker.handleReply(requestId: requestId, bytes: nil, failureReason: "noSuchDocument") }
            }
        }
        do {
            _ = try await broker.requestProvideContent(docId: "X", deviceId: "devA")
            XCTFail("expected deviceFailed")
        } catch let error as DeviceCommandBroker.DeviceCommandError {
            XCTAssertEqual(error, .deviceFailed("noSuchDocument"))
        }
    }
}
