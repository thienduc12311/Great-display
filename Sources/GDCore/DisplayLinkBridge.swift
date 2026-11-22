import Foundation
import CoreGraphics

/// EXPERIMENTAL: input source switching for monitors behind a DisplayLink dock.
///
/// macOS has no DDC/CI path to a DisplayLink display: the video goes through
/// DisplayLink Manager, not a GPU framebuffer. DisplayLink Manager itself only
/// exposes brightness and contrast (`com.displaylink.SetBrightness` and friends).
///
/// This talks to a **patched, open-source build of DisplayLink's DDC bridge**
/// (`libdlmddc.dylib`, loaded into DisplayLink Manager) that adds input source
/// switching and generic VCP access in the same style as DisplayLink's own API:
/// distributed notifications whose `object` is a JSON string. Without that
/// patch installed, `DDCAPIPing` gets no answer and nothing here does anything.
///
/// Off unless "DisplayLink input switching" is enabled under Settings ›
/// General › Experimental.
@MainActor
public final class DisplayLinkBridge {
    public static let shared = DisplayLinkBridge()

    /// A DisplayLink display as reported by `com.displaylink.GetDisplays`.
    public struct Display: Equatable {
        public let persistentID: String
        public let name: String
        public let displayID: CGDirectDisplayID
    }

    public enum Status: Equatable {
        case unknown
        case checking
        /// The patched bridge answered `DDCAPIPing`.
        case available(apiVersion: Int)
        /// No `DDCAPIPong`: stock DisplayLink Manager, or it is not running.
        case notInstalled
    }

    public private(set) var status: Status = .unknown
    /// DisplayLink displays keyed by their macOS display ID.
    public private(set) var displays: [CGDirectDisplayID: Display] = [:]
    /// Called on the main thread whenever `status` or `displays` change.
    public var onChange: (() -> Void)?

    private let center = DistributedNotificationCenter.default()
    private var observers: [NSObjectProtocol] = []
    private var waiters: [String: ([String: Any]?) -> Void] = [:]

    private static let prefix = "com.displaylink."
    /// The first request after DisplayLink starts or the monitor switches input
    /// opens the DDC channel with DisplayLink's own poll, which takes 2–3 s.
    private static let timeout: TimeInterval = 6

    private init() {}

    public var isActive: Bool { !observers.isEmpty }

    /// Starts listening and asks DisplayLink for its displays.
    public func activate() {
        if observers.isEmpty {
            for name in ["InputSourceStatus", "VCPStatus", "CapabilitiesStatus", "DDCAPIPong"] {
                observe(name) { [weak self] object in self?.handleReply(object) }
            }
            observe("DisplayListUpdated") { [weak self] object in self?.handleDisplayList(object) }
            observe("InputSourceUpdated") { [weak self] _ in self?.onChange?() }
        }
        refresh()
    }

    /// Stops listening and forgets every display.
    public func deactivate() {
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
        let pending = waiters
        waiters.removeAll()
        for completion in pending.values { completion(nil) }
        displays.removeAll()
        status = .unknown
        onChange?()
    }

    /// Pings the bridge and re-reads DisplayLink's display list.
    public func refresh() {
        guard isActive else { return }
        // Keep showing "available" while re-checking a bridge that answered before.
        if case .available = status {} else if status != .checking {
            status = .checking
            onChange?()
        }
        send("DDCAPIPing", [:]) { [weak self] reply in
            guard let self else { return }
            if let reply, (reply["result"] as? Int ?? 0) == 0 {
                self.status = .available(apiVersion: reply["apiVersion"] as? Int ?? 1)
            } else {
                self.status = .notInstalled
            }
            self.onChange?()
        }
        // DisplayLink's built-in call; the reply is `DisplayListUpdated`.
        post("GetDisplays", [:])
    }

    public func display(for id: CGDirectDisplayID) -> Display? {
        displays[id]
    }

    // MARK: Input source (VCP 0x60)

    /// Reads the monitor's current input. Completion gets nil on failure.
    public func inputSource(for id: CGDirectDisplayID, completion: @escaping (Int?) -> Void) {
        guard let display = displays[id] else { completion(nil); return }
        send("GetInputSource", ["persistentDisplayId": display.persistentID]) { reply in
            guard let reply, (reply["result"] as? Int) == 0, let value = Self.number(reply["inputSource"]) else {
                completion(nil)
                return
            }
            completion(value & 0xFF)
        }
    }

    /// Switches the monitor's input. Completion gets an error message on failure.
    public func setInputSource(_ value: Int, for id: CGDirectDisplayID, completion: @escaping (String?) -> Void) {
        guard let display = displays[id] else { completion("Not a DisplayLink display"); return }
        send("SetInputSource", ["persistentDisplayId": display.persistentID, "inputSource": value]) { reply in
            guard let reply else { completion("No reply from the DisplayLink bridge"); return }
            if (reply["result"] as? Int) == 0 { completion(nil); return }
            completion(reply["error"] as? String ?? "DisplayLink bridge error \(reply["result"] ?? "?")")
        }
    }

    /// Input codes from the monitor's capabilities string. Many docks do not
    /// pass the capabilities reply through; completion then gets nil.
    public func inputSources(for id: CGDirectDisplayID, completion: @escaping ([Int]?) -> Void) {
        guard let display = displays[id] else { completion(nil); return }
        send("GetCapabilities", ["persistentDisplayId": display.persistentID]) { reply in
            guard let reply, (reply["result"] as? Int) == 0,
                  let list = reply["inputSources"] as? [Any] else { completion(nil); return }
            let values = list.compactMap(Self.number)
            completion(values.isEmpty ? nil : values)
        }
    }

    // MARK: Transport

    private func observe(_ name: String, _ handler: @escaping (String?) -> Void) {
        let token = center.addObserver(forName: .init(Self.prefix + name), object: nil, queue: .main) { note in
            let object = note.object as? String
            MainActor.assumeIsolated { handler(object) }
        }
        observers.append(token)
    }

    private func post(_ request: String, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let json = String(data: data, encoding: .utf8) else { return }
        center.postNotificationName(.init(Self.prefix + request), object: json,
                                    userInfo: nil, deliverImmediately: true)
    }

    @discardableResult
    private func send(_ request: String, _ body: [String: Any],
                      completion: @escaping ([String: Any]?) -> Void) -> String {
        let id = UUID().uuidString
        var body = body
        body["requestId"] = id
        waiters[id] = completion
        post(request, body)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                if let waiter = self?.waiters.removeValue(forKey: id) { waiter(nil) }
            }
        }
        return id
    }

    private func handleReply(_ object: String?) {
        guard let object, let data = object.data(using: .utf8),
              let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = reply["requestId"] as? String,
              let waiter = waiters.removeValue(forKey: id) else { return }
        waiter(reply)
    }

    private func handleDisplayList(_ object: String?) {
        guard let object, let data = object.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        var found: [CGDirectDisplayID: Display] = [:]
        for entry in list {
            guard let persistent = entry["persistentDisplayId"] as? String,
                  let cgid = Self.number(entry["CGID"]), cgid > 0,
                  (entry["isEnabled"] as? Bool) != false else { continue }
            let id = CGDirectDisplayID(truncatingIfNeeded: cgid)
            found[id] = Display(persistentID: persistent, name: entry["name"] as? String ?? persistent, displayID: id)
        }
        guard found != displays else { return }
        displays = found
        onChange?()
    }

    /// Accepts numbers and hex strings (`"0x11"`), as the bridge does.
    nonisolated private static func number(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("0x") { return Int(trimmed.dropFirst(2), radix: 16) }
            return Int(trimmed)
        default: return nil
        }
    }
}
