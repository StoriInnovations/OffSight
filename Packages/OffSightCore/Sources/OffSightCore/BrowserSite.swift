import Foundation

/// The website shown for a browser meeting (UR-34a), from the browser's active tab URL.
public enum BrowserSite {
    /// "https://meet.google.com/abc-defg-hij?authuser=0" → "meet.google.com".
    /// Only the host is kept (never the path or query, which can identify a meeting). Nil for
    /// non-web URLs (new tab pages, files, extensions).
    public static func host(fromURL string: String) -> String? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// How a browser session is labelled: "Google Chrome — meet.google.com", or the browser alone.
    public static func label(browser: String, host: String?) -> String {
        guard let host, !host.isEmpty else { return browser }
        return "\(browser) — \(host)"
    }
}
