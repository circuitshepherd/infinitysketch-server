import Foundation
import Testing
import InfSketchWire

struct WriteExpectationTests {
    private func roundTrip(_ m: ClientMessage) throws -> ClientMessage {
        let data = try JSONEncoder().encode(m)
        return try JSONDecoder().decode(ClientMessage.self, from: data)
    }

    @Test func opCarriesEachExpectation() throws {
        for exp in [WriteExpectation?.none, .some(.none), .some(.absent), .some(.matchBytes(Data([1, 2, 3])))] {
            let m = ClientMessage.op(docId: "D", opId: "O", payload: OpPayload(type: "fullDoc", data: Data([9])),
                                      expectation: exp)
            guard case let .op(_, _, _, decoded) = try roundTrip(m) else { Issue.record("not an op"); return }
            #expect(decoded == exp)
        }
    }

    @Test func preUpgradeOpWithoutExpectationDecodesToNil() throws {
        // Hand-crafted OLD wire shape (no "expectation" key, OpPayload's real
        // {"type":..., "data": base64} shape) must still decode, with the new
        // field defaulting to nil.
        let json = #"{"type":"op","docId":"D","opId":"O","payload":{"type":"fullDoc","data":""}}"#
        guard case let .op(_, _, _, exp) = try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8)) else {
            Issue.record("not an op"); return
        }
        #expect(exp == nil)
    }
}
