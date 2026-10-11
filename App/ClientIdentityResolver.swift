import AppKit
import Darwin
import Foundation
import OffSightCore

struct ResolvedApp: Equatable {
    let key: AppKey
    let displayName: String
    let bundleURL: URL?
    let isBrowser: Bool
    /// How the identity was found, for diagnostics (spike S2).
    let method: String
}

/// Turns a CoreMediaIO client (pid + signing ID) into the app the user recognises (architecture §4.2).
final class ClientIdentityResolver {
    private var cache: [String: ResolvedApp] = [:]

    func resolve(pid: Int32, signingID rawSigningID: String?) -> ResolvedApp {
        // CoreMediaIO may report "unknown" instead of a signing ID (spike S2).
        let signingID = rawSigningID.flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }
        let cacheKey = "\(pid)|\(signingID ?? "")"
        if let cached = cache[cacheKey] { return cached }
        let resolved = lookUp(pid: pid, signingID: signingID)
        cache[cacheKey] = resolved
        return resolved
    }

    private func lookUp(pid: Int32, signingID: String?) -> ResolvedApp {
        if let signingID, let known = KnownClients.match(signingID: signingID) {
            return resolved(known, method: "signing-id")
        }
        // CoreMediaIO usually gives no signing ID (spike S2), so identify the client by the
        // outermost app bundle of its executable: a browser's helper maps to the browser (UR-34).
        if let path = Self.executablePath(of: pid), let appURL = Self.outermostAppBundle(containing: path),
           let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            if let known = KnownClients.match(signingID: bundleID) {
                return resolved(known, method: "path-walk+known")
            }
            let name = FileManager.default.displayName(atPath: appURL.path)
            return ResolvedApp(key: AppKey(bundleID), displayName: (name as NSString).deletingPathExtension,
                               bundleURL: appURL, isBrowser: false, method: "path-walk")
        }
        // System capture processes outside any .app, e.g. WebKit's GPU process (Safari) or
        // avconferenced (FaceTime): match the executable's own name.
        if let path = Self.executablePath(of: pid) {
            let executable = URL(fileURLWithPath: path).lastPathComponent
            if let known = KnownClients.match(signingID: executable) ?? KnownClients.match(signingID: "com.apple." + executable) {
                return resolved(known, method: "executable-name")
            }
        }
        if let app = NSRunningApplication(processIdentifier: pid), let bundleID = app.bundleIdentifier {
            if let known = KnownClients.match(signingID: bundleID) {
                return resolved(known, method: "running-app+known")
            }
            return ResolvedApp(key: AppKey(bundleID), displayName: app.localizedName ?? bundleID,
                               bundleURL: app.bundleURL, isBrowser: false, method: "running-app")
        }
        // Rule R7: unknown clients are still protected, labelled by what we know.
        let label = signingID ?? "pid \(pid)"
        return ResolvedApp(key: AppKey("unknown:\(label)"), displayName: "Unknown app (\(label))",
                           bundleURL: nil, isBrowser: false, method: "unknown")
    }

    private func resolved(_ known: KnownClient, method: String) -> ResolvedApp {
        ResolvedApp(key: AppKey(known.hostBundleID), displayName: known.displayName,
                    bundleURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: known.hostBundleID),
                    isBrowser: known.isBrowser, method: method)
    }

    private static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// For ".../Google Chrome.app/Contents/Frameworks/.../Helper.app/..." returns ".../Google Chrome.app".
    private static func outermostAppBundle(containing path: String) -> URL? {
        var url = URL(fileURLWithPath: "/")
        for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
            url.appendPathComponent(component)
            if component.hasSuffix(".app") { return url }
        }
        return nil
    }
}
