import Foundation

/// Streams the app's live accessibility tree for VoiceOver Radar.
///
/// Add this package to your app and, in a DEBUG build, call
/// `VoiceOverRadarKit.shared.start()` once at launch. VoiceOver Radar then reads
/// the current screen's accessibility tree from `http://localhost:8765/`.
///
/// The stream only runs on the **iOS Simulator** (where `localhost` is shared
/// with the Mac); on a physical device `start()` is a no-op.
@MainActor
public final class VoiceOverRadarKit {

    public static let shared = VoiceOverRadarKit()

    private var server: AXExportServer?
    public private(set) var port: UInt16 = 8765

    private init() {}

    /// Starts serving the accessibility snapshot on the Simulator only.
    /// Idempotent; a no-op on physical devices.
    public func start(port: UInt16 = 8765) {
        #if !targetEnvironment(simulator)
        NSLog("[VoiceOverRadarKit] disabled: the stream only runs on the iOS Simulator.")
        #else
        guard server == nil else { return }
        self.port = port
        do {
            let server = try AXExportServer(port: port) { target in
                Self.handle(target)
            }
            server.start()
            self.server = server
            NSLog("[VoiceOverRadarKit] serving accessibility tree on http://localhost:\(port)/")
        } catch {
            NSLog("[VoiceOverRadarKit] failed to start on port \(port): \(error)")
        }
        #endif
    }

    public func stop() {
        server?.stop()
        server = nil
    }

    /// Handles a request target: performs an action if it's "/action?…", then
    /// always returns the current snapshot. Runs on the server's main queue.
    nonisolated private static func handle(_ target: String) -> Data {
        MainActor.assumeIsolated {
            if target.hasPrefix("/action") { performAction(query: target) }
            return encodedSnapshot()
        }
    }

    /// Parses `/action?id=…&type=increment|decrement|custom&name=…` and runs it.
    private static func performAction(query target: String) {
        guard let queryStart = target.firstIndex(of: "?") else { return }
        var params: [String: String] = [:]
        for pair in target[target.index(after: queryStart)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0])
            let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
            params[key] = value
        }
        guard let type = params["type"] else { return }
        switch type {
        case "escape": AccessibilityWalker.performEscape()
        case "magictap": AccessibilityWalker.performMagicTap()
        case "increment":
            if let id = params["id"] { AccessibilityWalker.adjust(id: id, increment: true) }
        case "decrement":
            if let id = params["id"] { AccessibilityWalker.adjust(id: id, increment: false) }
        case "custom":
            if let id = params["id"], let name = params["name"] {
                AccessibilityWalker.performCustomAction(id: id, name: name)
            }
        default: break
        }
    }

    /// Encodes the current snapshot. The tree walk must run on the main thread.
    private static func encodedSnapshot() -> Data {
        let snapshot = AccessibilityWalker.snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    }
}
