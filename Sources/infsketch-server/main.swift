import Foundation
import InfSketchServerKit

var port: UInt16 = 8080
var docsPath = "./docs"

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port":
        guard let value = arguments.next().flatMap({ UInt16($0) }) else {
            print("--port requires a number"); exit(1)
        }
        port = value
    case "--docs":
        guard let value = arguments.next() else {
            print("--docs requires a path"); exit(1)
        }
        docsPath = value
    default:
        print("usage: infsketch-server [--port N] [--docs DIR]")
        exit(argument == "--help" ? 0 : 1)
    }
}

let docsDirectory = URL(fileURLWithPath: docsPath, isDirectory: true)
do {
    try FileManager.default.createDirectory(at: docsDirectory, withIntermediateDirectories: true)
} catch {
    print("could not create docs directory at \(docsDirectory.path): \(error.localizedDescription)")
    exit(1)
}

let server = InfSketchServer(port: port, docsDirectory: docsDirectory)
print("infsketch-server \(ServerInfo.version) — http://localhost:\(port)  docs: \(docsDirectory.path)")
try await server.run()
