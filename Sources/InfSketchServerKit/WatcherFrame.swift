import Foundation

/// The relay that gives a WATCHED, UNOPENED document a live frame: the op-spec the server sends
/// a render-capable device, and the reading of what comes back. This is the pure half —
/// `SessionManager` decides WHEN, and `InfSketchServer` wires it to `DeviceCommandBroker`.
///
/// Before it, a browser on a document nobody had open got the cached frame while the session
/// lived and then the 256 px thumbnail stored in the file, although any connected app could
/// render the bytes — `render_sketch` proves that on every call, with the document closed on
/// the device and nothing written to its disk.
public enum WatcherFrame {
    /// Matches the app's own default frame (`FrameRenderer.defaultLongSidePx`) so a page that
    /// asked for nothing gets the same size whichever path rendered it. Two repositories name
    /// this number; they should move together.
    public static let defaultLongSidePx = 1024

    /// A whole-document render on paper (the device's own frame draws no grid either), budgeted
    /// at the requested long side squared. `maxPixels` is an AREA budget, so a non-square
    /// document comes back with its long side past `px` and its area at px² — the viewer maps a
    /// frame by its reported rect, so that is well defined. `appearance` is omitted: the device
    /// then renders the document's own theme, exactly as its own frame does.
    public static func renderSpec(longSidePx: Int?) -> Data {
        let side = Double(longSidePx ?? defaultLongSidePx)
        let spec: [String: Any] = ["op": "render", "include": "document", "background": "paper",
                                   "maxPixels": side * side]
        return (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys])) ?? Data()
    }

    /// The rect the device says its PNG covers — `RenderMetadata.canvasRect`, the field an agent
    /// reads. Anything else is nil: a frame without a rect is a defined viewer state, a frame
    /// with a wrong one is not.
    public static func canvasRect(fromMetadata meta: Data?) -> [Double]? {
        guard let meta,
              let object = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
              let raw = object["canvasRect"] as? [Any], raw.count == 4 else { return nil }
        // Element by element, not `as? [Double]`: on Linux the parser yields Int for a whole
        // number and the whole-array cast then fails for a rect like [0, 0, 100, 100].
        let rect = raw.compactMap { value -> Double? in
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let n = value as? NSNumber { return n.doubleValue }
            return nil
        }
        return rect.count == 4 ? rect : nil
    }
}
