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
        case imageNotFound
        case elementNotFound
    }

    // MARK: - Read

    /// Extracts a read-only summary: every placed text (id/text/origin/pinned),
    /// the document's dark/light colour scheme, and its content size when present.
    /// Malformed text entries (a non-dictionary array element, missing id, no
    /// string text runs, or a malformed rect) are skipped rather than thrown —
    /// a summary is best-effort. A text's string is the concatenation of ALL its
    /// runs (AttributedString's Codable form is one (string, attributes) pair
    /// per attribute run), never just the first.
    public static func summary(from bytes: Data) throws -> DocSummary {
        let doc = try parseDocument(bytes)
        let texts = rawTextElements(of: doc).compactMap { element in
            (element as? [String: Any]).flatMap(textSummary(from:))
        }
        return DocSummary(
            texts: texts,
            darkColorScheme: (doc["darkColorScheme"] as? Bool) ?? false,
            contentSize: contentSize(from: doc)
        )
    }

    // MARK: - Write

    /// Appends the canonical minimal text entry (Global Constraints) to
    /// `placedTextsData`, inheriting the document's `darkColorScheme` (default
    /// false) into the entry's `colorSchemeIsDark`. Every pre-existing array
    /// element — including ones this module doesn't understand — is preserved
    /// untouched in place.
    public static func addText(
        to bytes: Data,
        id: UUID,
        text: String,
        x: Double,
        y: Double,
        pinned: Bool
    ) throws -> Data {
        // Programmer-error contract, not a document property: JSON (the only
        // transport MCP tool arguments arrive over) cannot encode NaN/Infinity,
        // so a non-finite coordinate can only come from a direct API misuse.
        precondition(x.isFinite && y.isFinite,
                     "DocJSON.addText: coordinates must be finite — JSON cannot encode NaN/Infinity")
        var doc = try parseDocument(bytes)
        let darkColorScheme = (doc["darkColorScheme"] as? Bool) ?? false
        var elements = rawTextElements(of: doc)
        elements.append(makeEntry(
            id: id.uuidString,
            text: text,
            x: x,
            y: y,
            pinned: pinned,
            colorSchemeIsDark: darkColorScheme
        ))
        doc["placedTextsData"] = elements
        return try serialize(doc)
    }

    /// Mutates an existing text entry by id. `newText` (when non-nil) replaces
    /// the run array wholesale with `[newText, {}]` — a documented formatting
    /// reset, mirroring what a fresh `addText` would produce for that string.
    /// `x`/`y` (when non-nil) update only that axis of `rect`'s origin; the
    /// untouched axis, size, sibling entries (including unrecognized array
    /// elements), and every other key are passed through unchanged (not
    /// re-rounded — the original `Any`/`NSNumber` values are preserved).
    public static func editText(
        in bytes: Data,
        textId: String,
        newText: String?,
        x: Double?,
        y: Double?
    ) throws -> Data {
        // See addText: non-finite coordinates are a programmer error by contract.
        precondition((x?.isFinite ?? true) && (y?.isFinite ?? true),
                     "DocJSON.editText: coordinates must be finite — JSON cannot encode NaN/Infinity")
        var doc = try parseDocument(bytes)
        var elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements),
              var entry = elements[index] as? [String: Any]
        else {
            throw DocJSONError.textNotFound
        }

        if let newText {
            entry["text"] = makeTextRuns(newText)
        }

        if x != nil || y != nil {
            entry["rect"] = updatedRect(entry["rect"], x: x, y: y)
        }

        elements[index] = entry
        doc["placedTextsData"] = elements
        return try serialize(doc)
    }

    /// Removes a text entry by id, leaving every other array element (including
    /// unrecognized ones) untouched in place. Throws `.textNotFound` if no
    /// entry matches.
    public static func removeText(from bytes: Data, textId: String) throws -> Data {
        var doc = try parseDocument(bytes)
        var elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements) else {
            throw DocJSONError.textNotFound
        }
        elements.remove(at: index)
        doc["placedTextsData"] = elements
        return try serialize(doc)
    }

    /// Removes a placed-image entry by id, then orphan-prunes its backing
    /// `pastedImagesData` blob IFF no *remaining* placed image still
    /// references the same `pastedImageDataId` — two placed images can share
    /// one blob via paste-dedup, so the blob only goes when nothing else
    /// points at it. Every other array element (including unrecognized ones,
    /// in either array) is left untouched in place. Throws `.imageNotFound`
    /// if no placed image matches `imageId`.
    public static func removeImage(from bytes: Data, imageId: String) throws -> Data {
        var doc = try parseDocument(bytes)
        var placed = (doc["placedImagesData"] as? [Any]) ?? []
        guard let index = entryIndex(withId: imageId, in: placed) else {
            throw DocJSONError.imageNotFound
        }
        let removedPastedId = (placed[index] as? [String: Any])?["pastedImageDataId"] as? String
        placed.remove(at: index)
        doc["placedImagesData"] = placed
        // Orphan-prune the backing blob IFF no remaining placement references it (images can share a blob).
        if let removedPastedId,
           !placed.contains(where: { ($0 as? [String: Any])?["pastedImageDataId"] as? String == removedPastedId }) {
            var pasted = (doc["pastedImagesData"] as? [Any]) ?? []
            pasted.removeAll { ($0 as? [String: Any])?["id"] as? String == removedPastedId }
            doc["pastedImagesData"] = pasted
        }
        return try serialize(doc)
    }

    /// Sets the `pinned` flag to `pinned` on every placed text or image whose
    /// `id` is in `ids`. `ids` may mix text ids and image ids — both arrays are
    /// scanned. ATOMIC: every id must resolve to a text or image, else
    /// `.elementNotFound` is thrown and nothing is mutated. Only the `pinned`
    /// field of a matched entry changes; every other field, and every
    /// non-dictionary / unmatched element (in either array), is preserved in
    /// place (the `[Any]`-per-element robustness rule). Strokes have no `pinned`
    /// field and are not involved.
    public static func setPinned(from bytes: Data, ids: [String], pinned: Bool) throws -> Data {
        var doc = try parseDocument(bytes)
        let texts = (doc["placedTextsData"] as? [Any]) ?? []
        let images = (doc["placedImagesData"] as? [Any]) ?? []

        // Validate BEFORE mutating (atomic): every requested id must be present.
        let present = Set((texts + images).compactMap { ($0 as? [String: Any])?["id"] as? String })
        for id in ids where !present.contains(id) {
            throw DocJSONError.elementNotFound
        }

        let idSet = Set(ids)
        func repin(_ elements: [Any]) -> [Any] {
            elements.map { element in
                guard var dict = element as? [String: Any],
                      let id = dict["id"] as? String, idSet.contains(id)
                else { return element }
                dict["pinned"] = pinned
                return dict
            }
        }
        // Only write back arrays that were actually present (don't add an empty
        // key to a doc that had no texts or no images).
        if doc["placedTextsData"] != nil { doc["placedTextsData"] = repin(texts) }
        if doc["placedImagesData"] != nil { doc["placedImagesData"] = repin(images) }
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
        // Parsed-JSON content is NOT always re-serializable: Darwin's
        // JSONSerialization parses the grammar-valid number `-1e999` as
        // -infinity (negative overflow does not throw, unlike `+1e999`), so a
        // document can make it INTO memory carrying a value that cannot be
        // written back out. That is a property of the caller's document — the
        // one honest label is `invalidDocumentJSON`. THROW, never trap: a
        // precondition here was a remotely-reachable whole-process kill via
        // crafted document bytes (replace_doc → add_text). The guard itself
        // must stay, because on Darwin `JSONSerialization.data(withJSONObject:)`
        // raises an ObjC exception (not a Swift error) for invalid objects.
        // (Values this file writes itself are always representable — the
        // public entry points precondition-check their coordinates.)
        guard JSONSerialization.isValidJSONObject(doc) else {
            throw DocJSONError.invalidDocumentJSON
        }
        return try JSONSerialization.data(withJSONObject: doc)
    }

    /// The raw `placedTextsData` array with each element left as `Any`. The
    /// app's format guarantees dictionaries, but a foreign or hand-edited
    /// document may contain stray non-dictionary elements — reads skip them,
    /// mutations preserve them untouched in place. NEVER cast the whole array
    /// to `[[String: Any]]`: that cast is all-or-nothing, so one bad element
    /// would empty the reads and make `addText` write back an array containing
    /// only the new entry (destroying every existing text).
    private static func rawTextElements(of doc: [String: Any]) -> [Any] {
        (doc["placedTextsData"] as? [Any]) ?? []
    }

    /// Index of the dictionary element whose `id` matches, ignoring
    /// non-dictionary elements.
    private static func entryIndex(withId textId: String, in elements: [Any]) -> Int? {
        elements.firstIndex { (($0 as? [String: Any])?["id"] as? String) == textId }
    }

    private static func textSummary(from entry: [String: Any]) -> TextSummary? {
        guard let id = entry["id"] as? String else { return nil }
        // AttributedString's Codable form alternates (run string, attributes
        // dict) pairs — concatenate every string element so multi-run text
        // ("Hello world" with one bolded word) isn't truncated to its first run.
        guard let runs = entry["text"] as? [Any] else { return nil }
        let strings = runs.compactMap { $0 as? String }
        guard !strings.isEmpty else { return nil }
        guard let rect = entry["rect"] as? [Any],
              let origin = rect.first as? [Any],
              origin.count >= 2,
              let x = doubleValue(origin[0]),
              let y = doubleValue(origin[1])
        else { return nil }
        let pinned = (entry["pinned"] as? Bool) ?? false
        return TextSummary(id: id, text: strings.joined(), x: x, y: y, pinned: pinned)
    }

    private static func contentSize(from doc: [String: Any]) -> [Double]? {
        guard let widthAny = doc["contentSizeWidth"], let width = doubleValue(widthAny),
              let heightAny = doc["contentSizeHeight"], let height = doubleValue(heightAny)
        else {
            return nil
        }
        return [width, height]
    }

    /// Numbers out of `JSONSerialization` are platform-boxed: Darwin always
    /// yields `NSNumber` (which the first branch bridges via `as? Double`),
    /// while swift-corelibs-foundation (Linux) can yield native `Int`/`Double`/
    /// `NSNumber` depending on the literal — the `Int` branch is live there for
    /// integral literals like `40000`, and the `NSNumber` branch backstops
    /// boxed values whose direct `as? Double` bridge fails. Keep all three.
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
