// Demo/diagnostic client: subscribes to a document and periodically re-submits
// its bytes as fullDoc ops, so the web overview visibly ticks (seq, subscribers).
import Foundation
import InfSketchServerKit

#if !canImport(Darwin)
print("infsketch-demo currently requires macOS (URLSessionWebSocketTask).")
exit(1)
#else

var urlText = "ws://127.0.0.1:8080/ws"
var docId: String?
var interval: Double = 2

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--url": urlText = arguments.next() ?? urlText
    case "--doc": docId = arguments.next()
    case "--interval": interval = arguments.next().flatMap(Double.init) ?? interval
    default:
        print("usage: infsketch-demo [--url ws://host:port/ws] --doc <id> [--interval seconds]")
        exit(argument == "--help" ? 0 : 1)
    }
}
guard let docId else {
    print("--doc <id> is required")
    exit(1)
}
guard let url = URL(string: urlText) else {
    print("bad url: \(urlText)")
    exit(1)
}

let task = URLSession.shared.webSocketTask(with: url)
task.resume()

func send(_ message: ClientMessage) async throws {
    try await task.send(.string(try message.jsonText()))
}

func receive() async throws -> ServerMessage {
    while true {
        if case .string(let text) = try await task.receive() {
            return try ServerMessage(jsonText: text)
        }
    }
}

try await send(.hello(protocolVersion: WireProtocol.version, capabilities: []))
guard case .helloAck = try await receive() else {
    print("handshake failed")
    exit(1)
}
print("connected to \(urlText)")

try await send(.subscribe(docId: docId, fromSeq: nil))
guard case .subscribed(_, let seq, .inline(let snapshot)) = try await receive() else {
    print("subscribe failed (does doc '\(docId)' exist?)")
    exit(1)
}
print("subscribed to '\(docId)' at seq \(seq), snapshot \(snapshot.count) bytes")

// Print everything the server pushes.
let printer = Task {
    do {
        while true {
            let message = try await receive()
            switch message {
            case .event(_, let seq, let kind, let opId, _):
                print("event  seq=\(seq)  kind=\(kind)  opId=\(opId)")
            case .reject(_, let opId, let reason, _):
                print("REJECT opId=\(opId)  reason=\(reason)")
            default:
                print("received: \(message)")
            }
        }
    } catch {
        print("disconnected (receive): \(error.localizedDescription)")
        exit(0)
    }
}

// Re-submit the snapshot bytes every interval — seq advances, status fires.
var counter = 0
do {
    while true {
        try await Task.sleep(for: .seconds(interval))
        counter += 1
        try await send(.op(
            docId: docId,
            opId: "demo-\(ProcessInfo.processInfo.processIdentifier)-\(counter)",
            payload: OpPayload(type: "fullDoc", data: snapshot)))
    }
} catch {
    print("disconnected (send): \(error.localizedDescription)")
    exit(0)
}
_ = printer  // runs until the process is killed (Ctrl-C)
#endif
