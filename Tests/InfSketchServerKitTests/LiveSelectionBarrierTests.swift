import Foundation
import Testing
@testable import InfSketchServerKit
import MCP

/// A live-selection write commits on the DEVICE, so the agent's undo history gets a barrier for
/// it instead of an entry. The barrier must also be left when the op's answer never arrived: a
/// device that went quiet (`deviceTimeout`) or away (`deviceDisconnected`) may still apply the op
/// before its `notAfter`, and an undo past it would then reverse the older write beneath it.
@Suite struct LiveSelectionBarrierTests {
    private func result(_ text: String, isError: Bool) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }

    @Test func aSuccessLeavesABarrier() {
        #expect(MCPAdapter.mayHaveChangedTheDocument(result("{}", isError: false)))
    }

    @Test func anUnansweredOpLeavesABarrier() {
        #expect(MCPAdapter.mayHaveChangedTheDocument(result("deviceTimeout", isError: true)))
        #expect(MCPAdapter.mayHaveChangedTheDocument(result("deviceDisconnected", isError: true)))
    }

    @Test func aRefusalLeavesNone() {
        #expect(!MCPAdapter.mayHaveChangedTheDocument(result("deviceFailed: noSelectionActive", isError: true)))
        #expect(!MCPAdapter.mayHaveChangedTheDocument(result("deviceFailed: requestExpired", isError: true)))
        #expect(!MCPAdapter.mayHaveChangedTheDocument(result("noDeviceAvailable", isError: true)))
    }
}
