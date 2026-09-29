import Foundation

public struct DocRefCandidate: Equatable, Sendable {
    public let id: String
    public let name: String
    public let modifiedAt: Date
    public init(id: String, name: String, modifiedAt: Date) {
        self.id = id
        self.name = name
        self.modifiedAt = modifiedAt
    }
}

public enum DocRefResolution: Equatable, Sendable {
    case id(String)
    case ambiguous([DocRefCandidate])
    case unresolved
}

/// What an agent (or a viewer URL) means by a document reference: its id, or its NAME when no
/// other document carries that name (spec §4). An id always wins over a name that looks like it.
enum DocRefResolver {
    static func resolve(_ ref: String, among documents: [DocRefCandidate]) -> DocRefResolution {
        if documents.contains(where: { $0.id == ref }) { return .id(ref) }
        let folded = ref.lowercased()
        let byFoldedId = documents.filter { $0.id.lowercased() == folded }
        if byFoldedId.count == 1 { return .id(byFoldedId[0].id) }
        for matches in [documents.filter { $0.name == ref }, documents.filter { $0.name.lowercased() == folded }] {
            if matches.count == 1 { return .id(matches[0].id) }
            if matches.count > 1 { return .ambiguous(matches.sorted { $0.modifiedAt > $1.modifiedAt }) }
        }
        return .unresolved
    }
}
