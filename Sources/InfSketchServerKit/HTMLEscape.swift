import Foundation

/// Escaping for the small amount of HTML this server builds by hand.
///
/// One implementation, because there are now two pages doing it and a page that escapes four of the
/// five characters looks exactly like a page that escapes all five.
public enum HTML {
    public static func escape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&#39;")
    }
}
