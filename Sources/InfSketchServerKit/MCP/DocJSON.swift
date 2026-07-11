import Foundation

/// Pure `JSONSerialization` manipulation of `.infsketch` document JSON, scoped to
/// placed-text entries (`placedTextsData`). No UIKit, no Codable model of the app's
/// on-disk format — everything here operates on plain `[String: Any]` / `[Any]` so it
/// stays Linux-safe (MCP tools run server-side; see Tasks 6-7 in
/// `docs/superpowers/plans/2026-07-11-mcp-endpoint.md`).
///
/// `addText`'s entry construction MUST stay byte-shape-identical to the "canonical
/// minimal text entry" pinned in that plan's Global Constraints — the app's
/// `MCPPayloadDecodeTests` keystone test locks the same shape on the decode side.
/// Never add, rename, or omit a key in `makeEntry(...)` without updating both sides.
public enum DocJSON {

    // MARK: - Types

    public struct TextSummary: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var x: Double
        public var y: Double
        public var pinned: Bool

        public init(id: String, text: String, x: Double, y: Double, pinned: Bool) {
            self.id = id
            self.text = text
            self.x = x
            self.y = y
            self.pinned = pinned
        }
    }

    public struct DocSummary: Codable, Equatable, Sendable {
        public var texts: [TextSummary]
        public var darkColorScheme: Bool
        public var contentSize: [Double]?

        public init(texts: [TextSummary], darkColorScheme: Bool, contentSize: [Double]?) {
            self.texts = texts
            self.darkColorScheme = darkColorScheme
            self.contentSize = contentSize
        }
    }

    public enum DocJSONError: Error, Equatable {
        case invalidDocumentJSON
        case textNotFound
    }

    // MARK: - Read

    /// Extracts a read-only summary: every placed text (id/text/origin/pinned),
    /// the document's dark/light colour scheme, and its content size when present.
    /// Malformed text entries (missing id, non-string first text run, or a
    /// malformed rect) are skipped rather than thrown — a summary is best-effort.
    public static func summary(from bytes: Data) throws -> DocSummary {
        let doc = try parseDocument(bytes)
        let entries = (doc["placedTextsData"] as? [[String: Any]]) ?? []
        let texts = entries.compactMap { textSummary(from: $0) }
        return DocSummary(
            texts: texts,
            darkColorScheme: (doc["darkColorScheme"] as? Bool) ?? false,
            contentSize: contentSize(from: doc)
        )
    }

    // MARK: - Write

    /// Appends the canonical minimal text entry (Global Constraints) to
    /// `placedTextsData`, inheriting the document's `darkColorScheme` (default
    /// false) into the entry's `colorSchemeIsDark`.
    public static func addText(
        to bytes: Data,
        id: UUID,
        text: String,
        x: Double,
        y: Double,
        pinned: Bool
    ) throws -> Data {
        var doc = try parseDocument(bytes)
        let darkColorScheme = (doc["darkColorScheme"] as? Bool) ?? false
        var entries = (doc["placedTextsData"] as? [[String: Any]]) ?? []
        entries.append(makeEntry(
            id: id.uuidString,
            text: text,
            x: x,
            y: y,
            pinned: pinned,
            colorSchemeIsDark: darkColorScheme
        ))
        doc["placedTextsData"] = entries
        return try serialize(doc)
    }

    /// Mutates an existing text entry by id. `newText` (when non-nil) replaces
    /// the run array wholesale with `[newText, {}]` — a documented formatting
    /// reset, mirroring what a fresh `addText` would produce for that string.
    /// `x`/`y` (when non-nil) update only that axis of `rect`'s origin; the
    /// untouched axis, size, and every other key are passed through unchanged
    /// (not re-rounded — the original `Any`/`NSNumber` values are preserved).
    public static func editText(
        in bytes: Data,
        textId: String,
        newText: String?,
        x: Double?,
        y: Double?
    ) throws -> Data {
        var doc = try parseDocument(bytes)
        var entries = (doc["placedTextsData"] as? [[String: Any]]) ?? []
        guard let index = entries.firstIndex(where: { ($0["id"] as? String) == textId }) else {
            throw DocJSONError.textNotFound
        }

        var entry = entries[index]

        if let newText {
            entry["text"] = makeTextRuns(newText)
        }

        if x != nil || y != nil {
            entry["rect"] = updatedRect(entry["rect"], x: x, y: y)
        }

        entries[index] = entry
        doc["placedTextsData"] = entries
        return try serialize(doc)
    }

    /// Removes a text entry by id. Throws `.textNotFound` if no entry matches.
    public static func removeText(from bytes: Data, textId: String) throws -> Data {
        var doc = try parseDocument(bytes)
        var entries = (doc["placedTextsData"] as? [[String: Any]]) ?? []
        guard let index = entries.firstIndex(where: { ($0["id"] as? String) == textId }) else {
            throw DocJSONError.textNotFound
        }
        entries.remove(at: index)
        doc["placedTextsData"] = entries
        return try serialize(doc)
    }

    // MARK: - Parsing helpers

    private static func parseDocument(_ bytes: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let dict = object as? [String: Any]
        else {
            throw DocJSONError.invalidDocumentJSON
        }
        return dict
    }

    private static func serialize(_ doc: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(doc) else {
            throw DocJSONError.invalidDocumentJSON
        }
        return try JSONSerialization.data(withJSONObject: doc)
    }

    private static func textSummary(from entry: [String: Any]) -> TextSummary? {
        guard let id = entry["id"] as? String else { return nil }
        guard let runs = entry["text"] as? [Any], let text = runs.first as? String else { return nil }
        guard let rect = entry["rect"] as? [Any],
              let origin = rect.first as? [Any],
              origin.count >= 2,
              let x = doubleValue(origin[0]),
              let y = doubleValue(origin[1])
        else { return nil }
        let pinned = (entry["pinned"] as? Bool) ?? false
        return TextSummary(id: id, text: text, x: x, y: y, pinned: pinned)
    }

    private static func contentSize(from doc: [String: Any]) -> [Double]? {
        guard let widthAny = doc["contentSizeWidth"], let width = doubleValue(widthAny),
              let heightAny = doc["contentSizeHeight"], let height = doubleValue(heightAny)
        else {
            return nil
        }
        return [width, height]
    }

    private static func doubleValue(_ any: Any) -> Double? {
        if let d = any as? Double { return d }
        if let n = any as? NSNumber { return n.doubleValue }
        if let i = any as? Int { return Double(i) }
        return nil
    }

    /// `[text, {}]` — a fresh, unformatted run array (also used by `makeEntry`).
    private static func makeTextRuns(_ text: String) -> [Any] {
        let emptyAttributes: [String: Any] = [:]
        return [text, emptyAttributes]
    }

    /// Replaces the x and/or y of `rect`'s origin (`rect[0]`), leaving the other
    /// axis and the size (`rect[1]`) exactly as they were. Falls back to a
    /// canonical zero rect only if the existing value is missing/malformed.
    private static func updatedRect(_ existing: Any?, x: Double?, y: Double?) -> [Any] {
        let fallbackOrigin: [Any] = [0, 0]
        let fallbackSize: [Any] = [1, 1]

        var rect = (existing as? [Any]) ?? [fallbackOrigin, fallbackSize]
        if rect.count < 2 { rect = [fallbackOrigin, fallbackSize] }

        var origin = (rect[0] as? [Any]) ?? fallbackOrigin
        if origin.count < 2 { origin = fallbackOrigin }

        if let x { origin[0] = x }
        if let y { origin[1] = y }

        rect[0] = origin
        return rect
    }

    /// The canonical minimal text entry (see the plan's Global Constraints) —
    /// keep this verbatim in shape; Tasks 6-7 and the app's decode-side keystone
    /// test both depend on it.
    private static func makeEntry(
        id: String,
        text: String,
        x: Double,
        y: Double,
        pinned: Bool,
        colorSchemeIsDark: Bool
    ) -> [String: Any] {
        let transform: [String: Any] = ["a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0]
        let rect: [Any] = [[x, y], [1, 1]]
        return [
            "id": id,
            "text": makeTextRuns(text),
            "rect": rect,
            "transform": transform,
            "opacity": 1,
            "pinned": pinned,
            "wordWrapEnabled": false,
            "colorSchemeIsDark": colorSchemeIsDark,
        ]
    }
}
