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
        case invalidColor
        case arrowNotFound
        case formulaNotFound
        /// A text that is turned or scaled cannot be placed without laying it out; the caller
        /// routes such an edit to a device first, so this is only reached without one.
        case textNeedsDeviceToPlace
        /// The document was written by an app whose file format is newer than the one these
        /// edits know (`knownFormatVersion`).
        case documentFormatNewer(file: Int)
    }

    /// The newest `.infsketch` format version the edits in this file understand — the app's
    /// `SketchDocData.currentFormatVersion` at this server's release (7: a text's `inlineMath` and
    /// the document's `newTextsInlineMath`, formulas; 6: one mixed `placedObjects` list, arrows). A document that says it is NEWER is REFUSED by every edit here, as the app
    /// refuses it: a format change can move where elements live, and an edit made on the old
    /// shape answers not-found for elements that exist, or writes a key the newer app no longer
    /// reads. That is what v1.4.0 does to a format-5 document — it looks in `placedTextsData`,
    /// finds nothing, and tells the agent the text is not there. The document itself stays an
    /// opaque payload for sync; only these direct edits read its shape. **Raise this together
    /// with the app's format version, in the same paired release.**
    public static let knownFormatVersion = 7

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
    ///
    /// `inlineMath` (format 7, formulas): nil takes the document's `newTextsInlineMath` (absent =
    /// false). The key is written only when true, and writing it raises the document to format 7
    /// (`writeInlineMath`); false and nil on a document without the default write exactly the
    /// entry this wrote before formulas existed.
    public static func addText(
        to bytes: Data,
        id: UUID,
        text: String,
        x: Double,
        y: Double,
        pinned: Bool,
        inlineMath: Bool? = nil
    ) throws -> Data {
        // Programmer-error contract, not a document property: JSON (the only
        // transport MCP tool arguments arrive over) cannot encode NaN/Infinity,
        // so a non-finite coordinate can only come from a direct API misuse.
        precondition(x.isFinite && y.isFinite,
                     "DocJSON.addText: coordinates must be finite — JSON cannot encode NaN/Infinity")
        var doc = try parseDocumentForEdit(bytes)
        let darkColorScheme = (doc["darkColorScheme"] as? Bool) ?? false
        var elements = rawTextElements(of: doc)
        var entry = makeEntry(
            id: id.uuidString,
            text: text,
            x: x,
            y: y,
            pinned: pinned,
            colorSchemeIsDark: darkColorScheme
        )
        if usesObjectList(doc) {
            // Format 5: an element of the one object list names its kind and its layer —
            // a new text goes in front of the strokes, where texts have always been.
            entry["kind"] = ElementKind.text.rawValue
            entry["layer"] = "front"
        }
        let formulas = inlineMath ?? ((doc["newTextsInlineMath"] as? Bool) ?? false)
        writeInlineMath(formulas, into: &entry, doc: &doc)
        elements.append(entry)
        setElements(elements, .text, in: &doc)
        return try serialize(doc)
    }

    /// Mutates an existing text entry by id. `newText` (when non-nil) replaces
    /// the run array with ONE run of the new characters in the style of the
    /// text's FIRST run, whose attribute object is copied as it is (it is
    /// UIKit-archived data this side cannot make, but it can keep it). Until
    /// 2026-11-19 it was `[newText, {}]`, a formatting reset: an agent that
    /// corrected a label's wording got it back in the default size and color.
    /// `x`/`y` (when non-nil) update only that axis of `rect`'s origin; the
    /// untouched axis, size, sibling entries (including unrecognized array
    /// elements), and every other key are passed through unchanged (not
    /// re-rounded — the original `Any`/`NSNumber` values are preserved).
    /// Whether the text `textId` carries a picked anchor (format v3). Its re-layout on new
    /// characters is the device's (`TextAuthoring`), so a plain edit of its characters must not
    /// take the server-side path, which would leave the anchor point to drift.
    public static func textHasAnchor(in bytes: Data, textId: String) -> Bool {
        guard let doc = try? parseDocument(bytes) else { return false }
        let elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements),
              let entry = elements[index] as? [String: Any],
              let anchor = entry["anchor"] else { return false }
        return !(anchor is NSNull)
    }

    public static func editText(
        in bytes: Data,
        textId: String,
        newText: String?,
        x: Double?,
        y: Double?,
        inlineMath: Bool? = nil
    ) throws -> Data {
        // See addText: non-finite coordinates are a programmer error by contract.
        precondition((x?.isFinite ?? true) && (y?.isFinite ?? true),
                     "DocJSON.editText: coordinates must be finite — JSON cannot encode NaN/Infinity")
        var doc = try parseDocumentForEdit(bytes)
        var elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements),
              var entry = elements[index] as? [String: Any]
        else {
            throw DocJSONError.textNotFound
        }

        if let newText {
            entry["text"] = textRuns(newText, inTheStyleOf: entry["text"])
        }

        if x != nil || y != nil {
            // `x` / `y` say where the text is SHOWN. A text the user dragged in the app carries
            // that drag as a translation on its `transform`, and the origin written here is the
            // point asked for less that translation — written as asked (until 2026-11-22), the
            // text landed beside the place by exactly its drag. A text that is turned or scaled
            // is not placed here at all: its shown corner depends on its laid-out size, which
            // only a device has (`textPlacementNeedsDevice`, routed in `MCPAdapter.callEditText`).
            switch transformKind(of: entry) {
            case .identity:
                entry["rect"] = updatedRect(entry["rect"], x: x, y: y)
            case .translation(let tx, let ty):
                entry["rect"] = updatedRect(entry["rect"], x: x.map { $0 - tx }, y: y.map { $0 - ty })
            case .other:
                throw DocJSONError.textNeedsDeviceToPlace
            }
        }

        if let inlineMath {
            writeInlineMath(inlineMath, into: &entry, doc: &doc)
        }

        elements[index] = entry
        setElements(elements, .text, in: &doc)
        return try serialize(doc)
    }

    /// What a text entry's `transform` does to a position: nothing, a shift, or more.
    enum TransformKind: Equatable {
        case identity
        case translation(tx: Double, ty: Double)
        case other
    }

    static func transformKind(of entry: [String: Any]) -> TransformKind {
        guard let t = entry["transform"] as? [String: Any] else { return .identity }
        func value(_ key: String, default fallback: Double) -> Double { t[key].flatMap(doubleValue) ?? fallback }
        let linear = [value("a", default: 1), value("b", default: 0), value("c", default: 0), value("d", default: 1)]
        guard linear == [1, 0, 0, 1] else { return .other }
        let tx = value("tx", default: 0), ty = value("ty", default: 0)
        return tx == 0 && ty == 0 ? .identity : .translation(tx: tx, ty: ty)
    }

    /// Whether this text carries a transform at all — a drag's translation included. A position
    /// for such a text is only placed where it is SHOWN by an app that has `placeBy`; an older
    /// one writes the origin under the transform and answers success.
    public static func textIsTransformed(in bytes: Data, textId: String) -> Bool {
        guard let doc = try? parseDocument(bytes) else { return false }
        let elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements),
              let entry = elements[index] as? [String: Any] else { return false }
        return transformKind(of: entry) != .identity
    }

    /// Whether moving this text to a canvas position needs a device: it is turned, scaled or
    /// skewed, so where its corner is shown depends on its laid-out size. False for an unknown id
    /// (the edit itself answers `textNotFound`).
    public static func textPlacementNeedsDevice(in bytes: Data, textId: String) -> Bool {
        guard let doc = try? parseDocument(bytes) else { return false }
        let elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements),
              let entry = elements[index] as? [String: Any] else { return false }
        return transformKind(of: entry) == .other
    }

    /// Sets one text's `inlineMath` (format 7) and nothing else — the device path of `add_text` /
    /// `edit_text`: the server writes the key on the bytes the device returned (the new text's id
    /// is in the reply's `meta`), so it is the one writer of the key on both paths and the device's
    /// op spec never carries it. Throws `.textNotFound` when no text has that id.
    ///
    /// When the entry already holds the requested value the device's bytes come back UNCHANGED:
    /// a rewrite would re-sort the keys and drop nothing but would still be a new byte string, and
    /// the device's bytes carry a current thumbnail that must not be lost for no change.
    public static func setInlineMath(in bytes: Data, textId: String, to inlineMath: Bool) throws -> Data {
        let doc = try parseDocumentForEdit(bytes)
        let elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements) else { throw DocJSONError.textNotFound }
        let value = (elements[index] as? [String: Any])?["inlineMath"]
        let current = (value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false
        if current == inlineMath { return bytes }
        return try editText(in: bytes, textId: textId, newText: nil, x: nil, y: nil, inlineMath: inlineMath)
    }

    /// The format that introduced `inlineMath` (formulas).
    static let inlineMathFormatVersion = 7

    /// Writes a text entry's `inlineMath` the app's way — the key only when true, absent when false
    /// — and, when it writes the key, raises the document's `formatVersion` to 7 if it says older
    /// (a file without the key is format 1). An app that knows only format 6 then REFUSES the
    /// document (its newer-format door) instead of opening it and stripping the key at its next
    /// save — the stated cost of every format change (design decision A1). Never lowers a version
    /// and never moves the text: the server cannot measure, and the device re-lays it at open.
    private static func writeInlineMath(_ on: Bool, into entry: inout [String: Any], doc: inout [String: Any]) {
        guard on else {
            entry.removeValue(forKey: "inlineMath")
            return
        }
        entry["inlineMath"] = true
        let version = (doc["formatVersion"] as? NSNumber)?.intValue ?? (doc["formatVersion"] as? Int) ?? 1
        if version < inlineMathFormatVersion {
            doc["formatVersion"] = inlineMathFormatVersion
        }
    }

    /// Removes a text entry by id, leaving every other array element (including
    /// unrecognized ones) untouched in place. Throws `.textNotFound` if no
    /// entry matches.
    public static func removeText(from bytes: Data, textId: String) throws -> Data {
        var doc = try parseDocumentForEdit(bytes)
        var elements = rawTextElements(of: doc)
        guard let index = entryIndex(withId: textId, in: elements) else {
            throw DocJSONError.textNotFound
        }
        elements.remove(at: index)
        setElements(elements, .text, in: &doc)
        return try serialize(doc)
    }

    /// Removes a placed arrow by id from the object list, every other slot left in place. An arrow
    /// is plain JSON (`kind: "arrow"`), so this needs no device and works on a closed document —
    /// the agent's one door for deleting an arrow without a live selection (review I2,
    /// 2026-10-15). Throws `.arrowNotFound` when no arrow has that id (a document without an
    /// object list has no arrows).
    public static func removeArrow(from bytes: Data, arrowId: String) throws -> Data {
        var doc = try parseDocumentForEdit(bytes)
        guard usesObjectList(doc) else { throw DocJSONError.arrowNotFound }
        var arrows = elements(.arrow, of: doc)
        guard let index = entryIndex(withId: arrowId, in: arrows) else {
            throw DocJSONError.arrowNotFound
        }
        arrows.remove(at: index)
        setElements(arrows, .arrow, in: &doc)
        return try serialize(doc)
    }

    /// Removes a formula object by id from the object list, every other slot left in place — the
    /// `removeArrow` rule: a formula is plain JSON (`kind: "formula"`), so this needs no device and
    /// works on a closed document. The format version is left as it is (a removal never raises or
    /// lowers it). Throws `.formulaNotFound` when no formula has that id (a document without an
    /// object list has no formulas).
    public static func removeFormula(from bytes: Data, formulaId: String) throws -> Data {
        var doc = try parseDocumentForEdit(bytes)
        guard usesObjectList(doc) else { throw DocJSONError.formulaNotFound }
        var formulas = elements(.formula, of: doc)
        guard let index = entryIndex(withId: formulaId, in: formulas) else {
            throw DocJSONError.formulaNotFound
        }
        formulas.remove(at: index)
        setElements(formulas, .formula, in: &doc)
        return try serialize(doc)
    }

    /// The ids of a document's elements of `kind` — a lenient READ (bytes that do not parse have
    /// none). What the adapter asks to learn whether a mixed `ids` list names a formula.
    static func elementIds(_ kind: ElementKind, in bytes: Data) -> Set<String> {
        guard let doc = try? parseDocument(bytes) else { return [] }
        return Set(elements(kind, of: doc).compactMap { ($0 as? [String: Any])?["id"] as? String })
    }

    /// Removes a placed-image entry by id, then orphan-prunes its backing
    /// `pastedImagesData` blob IFF no *remaining* placed image still
    /// references the same `pastedImageDataId` — two placed images can share
    /// one blob via paste-dedup, so the blob only goes when nothing else
    /// points at it. Every other array element (including unrecognized ones,
    /// in either array) is left untouched in place. Throws `.imageNotFound`
    /// if no placed image matches `imageId`.
    public static func removeImage(from bytes: Data, imageId: String) throws -> Data {
        var doc = try parseDocumentForEdit(bytes)
        var placed = elements(.image, of: doc)
        guard let index = entryIndex(withId: imageId, in: placed) else {
            throw DocJSONError.imageNotFound
        }
        let removedPastedId = (placed[index] as? [String: Any])?["pastedImageDataId"] as? String
        placed.remove(at: index)
        setElements(placed, .image, in: &doc)
        // Orphan-prune the backing blob IFF no remaining placement references it (images can share a blob).
        if let removedPastedId,
           !placed.contains(where: { ($0 as? [String: Any])?["pastedImageDataId"] as? String == removedPastedId }) {
            var pasted = (doc["pastedImagesData"] as? [Any]) ?? []
            pasted.removeAll { ($0 as? [String: Any])?["id"] as? String == removedPastedId }
            doc["pastedImagesData"] = pasted
        }
        return try serialize(doc)
    }

    /// Sets the `pinned` flag to `pinned` on every placed text, image, arrow or formula whose
    /// `id` is in `ids`. `ids` may mix the kinds — every one is scanned. ATOMIC: every id must
    /// resolve to one of them, else
    /// `.elementNotFound` is thrown and nothing is mutated. Only the `pinned`
    /// field of a matched entry changes; every other field, and every
    /// non-dictionary / unmatched element (in either array), is preserved in
    /// place (the `[Any]`-per-element robustness rule). Strokes have no `pinned`
    /// field and are not involved.
    public static func setPinned(from bytes: Data, ids: [String], pinned: Bool) throws -> Data {
        var doc = try parseDocumentForEdit(bytes)
        let texts = elements(.text, of: doc)
        let images = elements(.image, of: doc)
        let arrows = usesObjectList(doc) ? elements(.arrow, of: doc) : []
        let formulas = usesObjectList(doc) ? elements(.formula, of: doc) : []

        // Validate BEFORE mutating (atomic): every requested id must be present.
        let present = Set((texts + images + arrows + formulas).compactMap { ($0 as? [String: Any])?["id"] as? String })
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
        if usesObjectList(doc) {
            setElements(repin(texts), .text, in: &doc)
            setElements(repin(images), .image, in: &doc)
            if !arrows.isEmpty { setElements(repin(arrows), .arrow, in: &doc) }
            if !formulas.isEmpty { setElements(repin(formulas), .formula, in: &doc) }
        } else {
            if doc["placedTextsData"] != nil { doc["placedTextsData"] = repin(texts) }
            if doc["placedImagesData"] != nil { doc["placedImagesData"] = repin(images) }
        }
        return try serialize(doc)
    }

    /// Sets any subset of a document's paper fields — `backgroundColor` (light),
    /// `backgroundColorDark` (dark), `transparentBackground`. `light`/`dark` are
    /// `#RRGGBB`/`#RRGGBBAA` hex, written as the `ColorModel` JSON shape
    /// (`{red,green,blue,alpha}`, doubles in 0…1). An omitted field is left
    /// exactly as-is. ATOMIC: every supplied hex is validated BEFORE the doc is
    /// mutated, so a bad `dark` never leaves a half-written `light`
    /// (`.invalidColor` → the adapter's `invalidSpec`). Light/dark are
    /// INDEPENDENT — no `convertColor` coupling (that's UIKit; unavailable here).
    public static func setPaper(from bytes: Data, light: String?, dark: String?, transparent: Bool?) throws -> Data {
        // Validate every supplied hex up front (atomic).
        let lightDict = try light.map { hex -> [String: Double] in
            guard let c = colorModelDict(fromHex: hex) else { throw DocJSONError.invalidColor }
            return c
        }
        let darkDict = try dark.map { hex -> [String: Double] in
            guard let c = colorModelDict(fromHex: hex) else { throw DocJSONError.invalidColor }
            return c
        }
        var doc = try parseDocumentForEdit(bytes)
        if let lightDict { doc["backgroundColor"] = lightDict }
        if let darkDict { doc["backgroundColorDark"] = darkDict }
        if let transparent { doc["transparentBackground"] = transparent }
        return try serialize(doc)
    }

    /// `#RRGGBB` / `#RRGGBBAA` → the `ColorModel` JSON dict (doubles in 0…1), or
    /// nil for a malformed hex. Pure — no UIKit (the app's
    /// `GridAuthoring.colorModel(fromHex:)` is device-only; the server carries
    /// its own tiny parser).
    private static func colorModelDict(fromHex hex: String) -> [String: Double]? {
        // A leading `#` is REQUIRED, matching the app's one hex parser
        // (`UIColor(hexString:)` in StrokeAuthoring, used by GridAuthoring) — one
        // consistent hex contract across every agent tool that takes a colour.
        guard hex.hasPrefix("#") else { return nil }
        let s = hex.dropFirst()
        guard s.count == 6 || s.count == 8, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        let chars = Array(s)
        func component(_ i: Int) -> Double {
            let hi = chars[i].hexDigitValue!, lo = chars[i + 1].hexDigitValue!
            return Double(hi * 16 + lo) / 255.0
        }
        let alpha = chars.count == 8 ? component(6) : 1.0
        return ["red": component(0), "green": component(2), "blue": component(4), "alpha": alpha]
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

    /// `parseDocument` for a WRITE: a document newer than `knownFormatVersion` is refused (a file
    /// without the key is format 1). Reads stay lenient — a summary of what this build can see
    /// harms nothing.
    private static func parseDocumentForEdit(_ bytes: Data) throws -> [String: Any] {
        let doc = try parseDocument(bytes)
        if let version = (doc["formatVersion"] as? NSNumber)?.intValue, version > knownFormatVersion {
            throw DocJSONError.documentFormatNewer(file: version)
        }
        return doc
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
        // Every caller of this CHANGED the document, and the server cannot render: the stored
        // preview would be the previous content's. A thumbnail is stored with a document only if
        // it belongs to the bytes being stored — otherwise none (a stale preview is worse than an
        // absent one, since nothing about it looks wrong). The app decodes an absent key as an
        // empty preview and shows its placeholder; the device's next save renders a real one.
        var doc = doc
        doc.removeValue(forKey: "aaa001_thumbnailData")
        // `.sortedKeys` (2026-09-28 review, round 1, item 1c): this was the one writer of
        // `.infsketch` bytes that did NOT sort its top-level keys, and a document this writes can
        // land back in `Documents/` (an agent's `replace_doc`/`add_text`/… on a synced document).
        // The app's `SketchDocData.extractDocumentId(from:)` no longer depends on the order — it
        // reads every top-level key — so this is about keeping every writer's bytes in one shape
        // (a stable layout diffs and hashes the same way whichever side wrote it), not about
        // correctness of that reader. `aaa001_thumbnailData` is removed just above, so there is no
        // thumbnail key left to keep first here — the app's own writers keep that invariant where
        // a thumbnail IS present.
        return try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
    }

    /// The raw `placedTextsData` array with each element left as `Any`. The
    /// app's format guarantees dictionaries, but a foreign or hand-edited
    /// document may contain stray non-dictionary elements — reads skip them,
    /// mutations preserve them untouched in place. NEVER cast the whole array
    /// to `[[String: Any]]`: that cast is all-or-nothing, so one bad element
    /// would empty the reads and make `addText` write back an array containing
    /// only the new entry (destroying every existing text).
    private static func rawTextElements(of doc: [String: Any]) -> [Any] {
        elements(.text, of: doc)
    }

    // MARK: - Format 5: one object list

    /// Since document format 5 (object layers) texts and images are ONE list, `placedObjects`,
    /// whose elements carry `kind`; an older document keeps the two per-kind arrays. Every read
    /// and write here goes through these two functions, so both shapes are edited in place and
    /// a format-5 document never gains a stray old key (the app would still keep its elements,
    /// but the list's order and layers are the source of truth).
    /// `arrow` (document format 6) and `formula` (format 7) exist only in the one list: no app
    /// ever wrote a per-kind array for them, so they have NO legacy key (nil), and a document
    /// without the list has none of them.
    enum ElementKind: String { case text, image, arrow, formula
        /// The per-kind array a document from before format 5 keeps this kind in; nil for a kind
        /// that only ever lived in `placedObjects`.
        var legacyKey: String? {
            switch self {
            case .text: return "placedTextsData"
            case .image: return "placedImagesData"
            case .arrow, .formula: return nil
            }
        }
    }

    static func usesObjectList(_ doc: [String: Any]) -> Bool { doc["placedObjects"] is [Any] }

    /// The elements of `kind`, in list order, each left as `Any` (the robustness rule above).
    static func elements(_ kind: ElementKind, of doc: [String: Any]) -> [Any] {
        if let objects = doc["placedObjects"] as? [Any] {
            return objects.filter { (($0 as? [String: Any])?["kind"] as? String) == kind.rawValue }
        }
        guard let key = kind.legacyKey else { return [] }
        return (doc[key] as? [Any]) ?? []
    }

    /// Write back `kind`'s elements after an edit. In the one-list shape that kind's elements
    /// are replaced BY ID: a kept one takes its new value IN ITS SLOT, a missing id is removed,
    /// a new id goes on top (the end of the list). Elements of the other kind, unrecognized
    /// elements and an element without an id keep their slots untouched.
    static func setElements(_ new: [Any], _ kind: ElementKind, in doc: inout [String: Any]) {
        guard let objects = doc["placedObjects"] as? [Any] else {
            // A kind with no legacy key has no elements in such a document, and every caller
            // that writes one checks `usesObjectList` first — so there is nothing to write.
            guard let key = kind.legacyKey else {
                assert(new.isEmpty, "\(kind) has no place in a document without an object list")
                return
            }
            doc[key] = new
            return
        }
        func id(_ element: Any) -> String? { (element as? [String: Any])?["id"] as? String }
        var newById: [String: Any] = [:]
        for element in new { if let eid = id(element), newById[eid] == nil { newById[eid] = element } }
        var placed = Set<String>()
        var out: [Any] = []
        for element in objects {
            guard (element as? [String: Any])?["kind"] as? String == kind.rawValue,
                  let eid = id(element) else { out.append(element); continue }
            if let replacement = newById[eid], !placed.contains(eid) {
                out.append(replacement)
                placed.insert(eid)
            }
        }
        for element in new { if let eid = id(element), !placed.contains(eid) { out.append(element); placed.insert(eid) } }
        doc["placedObjects"] = out
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
        // Where the text is SHOWN: a text the user dragged carries the drag on its transform, and
        // the summary's position is the one `edit_text` takes back. (A turned or scaled text's
        // shown corner needs its laid-out size; its stored origin is reported, as before.)
        if case .translation(let tx, let ty) = transformKind(of: entry) {
            return TextSummary(id: id, text: strings.joined(), x: x + tx, y: y + ty, pinned: pinned)
        }
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

    /// `text` as one run with the attributes of `existing`'s first run (`[string, {…}, string,
    /// {…}, …]`), copied without being read. A first run that is not an attribute object (a
    /// shape this side does not know) gives the plain run.
    private static func textRuns(_ text: String, inTheStyleOf existing: Any?) -> [Any] {
        guard let runs = existing as? [Any], runs.count >= 2, let attributes = runs[1] as? [String: Any]
        else { return makeTextRuns(text) }
        return [text, attributes]
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
