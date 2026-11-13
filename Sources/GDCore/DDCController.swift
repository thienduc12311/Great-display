import Foundation
import CoreGraphics
import IOKit

/// Minimal DDC/CI implementation for external displays.
///
/// The display is reached through a `DCPAVServiceProxy` video-interface service.
/// Current SDKs no longer expose the display-to-I/O-service mapping, so the
/// service's DCP port index (`dispextN` / `DCPEXTN` in its ancestor chain) is
/// matched against the CoreGraphics display unit number. Standard DDC/CI Get VCP
/// and Set VCP frames are then exchanged over the I2C side channel.
public final class DDCController {
    public static let shared = DDCController()

    public enum VCP: UInt8, CaseIterable {
        case restoreFactoryDefaults = 0x04
        case restoreBrightnessContrast = 0x05
        case restoreColor = 0x08
        case brightness = 0x10
        case contrast = 0x12
        case colorPreset = 0x14
        case redGain = 0x16
        case greenGain = 0x18
        case blueGain = 0x1A
        case inputSource = 0x60
        case volume = 0x62
        case sharpness = 0x87
        case mute = 0x8D
        case powerMode = 0xD6

        public var name: String {
            switch self {
            case .restoreFactoryDefaults: return "Restore factory defaults"
            case .restoreBrightnessContrast: return "Restore brightness/contrast"
            case .restoreColor: return "Restore color"
            case .brightness: return "Brightness"
            case .contrast: return "Contrast"
            case .colorPreset: return "Color preset"
            case .redGain: return "Red gain"
            case .greenGain: return "Green gain"
            case .blueGain: return "Blue gain"
            case .inputSource: return "Input source"
            case .volume: return "Volume"
            case .sharpness: return "Sharpness"
            case .mute: return "Mute"
            case .powerMode: return "Power mode"
            }
        }
    }

    /// Outcome of a Get VCP request.
    public enum Reading: Equatable {
        case value(current: Int, maximum: Int)
        case unsupported
        case noReply
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias WriteFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private var createFn: CreateFn?
    private var readFn: ReadFn?
    private var writeFn: WriteFn?

    private var services: [CGDirectDisplayID: UnsafeMutableRawPointer] = [:]
    /// Registry entry ID of the service each display is bound to. Claims are
    /// keyed by this ID, which is stable; the service objects themselves are
    /// created anew on every enumeration and cannot be compared.
    private var serviceEntries: [CGDirectDisplayID: UInt64] = [:]
    private var claimed: Set<UInt64> = []
    /// When a display last failed to match any service, so repeated inventory
    /// refreshes do not walk the registry again straight away.
    private var unmatched: [CGDirectDisplayID: Date] = [:]
    private var readFailures: [CGDirectDisplayID: Int] = [:]

    /// Vendor ID this app gives its own virtual screens (see
    /// `VirtualScreenManager.create`). They have no monitor behind them.
    private static let virtualVendorID: UInt32 = 0x5678

    private let chipAddress: UInt32 = 0x37
    private let dataAddress: UInt32 = 0x51

    /// Maximum values reported by the monitor, so writes need no read first.
    private var maximums: [CGDirectDisplayID: [UInt8: Int]] = [:]
    /// VCP codes the monitor answered as unsupported.
    private var unsupported: [CGDirectDisplayID: Set<UInt8>] = [:]
    private var lastTransaction: [CGDirectDisplayID: Date] = [:]
    private var capabilityCache: [CGDirectDisplayID: DDCCapabilities] = [:]
    /// Transaction-lock protected epochs reject results from unbound services.
    private var bindingGenerations: [CGDirectDisplayID: UInt64] = [:]

    /// DDC is a single shared side channel: transactions and the service cache
    /// are serialized so concurrent callers cannot interleave frames or mutate
    /// the caches at the same time.
    private let lock = NSRecursiveLock()
    /// Guards only the display→service cache. Kept separate from `lock`, which
    /// is held for whole I/O transactions, so display enumeration on the main
    /// thread never waits behind a slow monitor (that stall used to time out
    /// the keyboard event tap). Order: `lock` may be held when taking this one.
    private let serviceLock = NSRecursiveLock()

    /// Writes come from sliders and keys and must feel immediate; reads are
    /// background refreshes. Readers step aside while a writer is waiting, since
    /// the lock itself is not fair.
    private let priorityLock = NSLock()
    private var waitingWriters = 0

    private func writerEnter() { priorityLock.lock(); waitingWriters += 1; priorityLock.unlock() }
    private func writerExit() { priorityLock.lock(); waitingWriters -= 1; priorityLock.unlock() }

    private func yieldToWriters() {
        for _ in 0..<200 {
            priorityLock.lock()
            let waiting = waitingWriters
            priorityLock.unlock()
            if waiting == 0 { return }
            usleep(5_000)
        }
    }

    private init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let symbol = { (name: String) -> UnsafeMutableRawPointer? in
            guard let handle else { return nil }
            return dlsym(handle, name)
        }
        if let p = symbol("IOAVServiceCreateWithService") {
            createFn = unsafeBitCast(p, to: CreateFn.self)
        }
        if let p = symbol("IOAVServiceReadI2C") {
            readFn = unsafeBitCast(p, to: ReadFn.self)
        }
        if let p = symbol("IOAVServiceWriteI2C") {
            writeFn = unsafeBitCast(p, to: WriteFn.self)
        }
    }

    public var isSupported: Bool {
        createFn != nil && readFn != nil && writeFn != nil
    }

    // MARK: Service discovery

    private struct VideoService {
        let entryID: UInt64
        let portIndex: Int?
        let service: UnsafeMutableRawPointer
    }

    /// Balances `IOAVServiceCreateWithService`, which returns a retained
    /// Core Foundation object.
    private func release(_ service: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(service).release()
    }

    /// Unbinds a display from its service. Callers hold `lock`; fragmented
    /// capabilities reads retain their own reference between transactions.
    private func dropService(for id: CGDirectDisplayID) {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        bindingGenerations[id, default: 0] &+= 1
        capabilityCache.removeValue(forKey: id)
        if let cached = services.removeValue(forKey: id) { release(cached) }
        if let entry = serviceEntries.removeValue(forKey: id) { claimed.remove(entry) }
        unmatched.removeValue(forKey: id)
    }

    /// Main-thread safe: takes only the service lock, never waits for I/O.
    public func hasService(for id: CGDirectDisplayID) -> Bool {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        return service(for: id) != nil
    }

    private func service(for id: CGDirectDisplayID) -> UnsafeMutableRawPointer? {
        serviceLock.lock()
        defer { serviceLock.unlock() }
        if let cached = services[id] { return cached }
        guard isSupported, Self.canHaveService(id) else { return nil }
        if let missed = unmatched[id], Date().timeIntervalSince(missed) < 2 { return nil }
        pruneOfflineBindings()

        // Only services no other display is bound to.
        let candidates = videoServices(excluding: claimed)
        guard let chosen = match(id, among: candidates) else {
            candidates.forEach { release($0.service) }
            unmatched[id] = Date()
            return nil
        }
        for candidate in candidates where candidate.entryID != chosen.entryID {
            release(candidate.service)
        }
        claimed.insert(chosen.entryID)
        serviceEntries[id] = chosen.entryID
        services[id] = chosen.service
        unmatched.removeValue(forKey: id)
        return chosen.service
    }

    /// Frees the services of displays that went away, so the monitor plugged
    /// into that port next can claim it. Skipped (and tried again on the next
    /// miss) while a transaction is running: this is reached from the main
    /// thread, which must not wait for I/O.
    private func pruneOfflineBindings() {
        let stale = services.keys.filter { CGDisplayIsOnline($0) == 0 }
        guard !stale.isEmpty, lock.try() else { return }
        defer { lock.unlock() }
        for id in stale { dropService(for: id) }
    }

    /// Displays that can sit behind a video service: external, and not one of
    /// this app's virtual screens (which would otherwise be handed a real
    /// monitor's service and drive that monitor's brightness and input).
    private static func canHaveService(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) == 0 && CGDisplayVendorNumber(id) != virtualVendorID
    }

    private func match(_ id: CGDirectDisplayID, among candidates: [VideoService]) -> VideoService? {
        guard !candidates.isEmpty else { return nil }

        // 1. Match the display unit number to the DCP port index. Port indices are
        // zero-based while display unit numbers are one-based. The video-service
        // EDID export is not used: its runtime ABI is not stable across releases.
        let unit = Int(CGDisplayUnitNumber(id))
        if let byUnit = candidates.first(where: { $0.portIndex == unit - 1 })
            ?? candidates.first(where: { $0.portIndex == unit }) {
            return byUnit
        }

        // 2. A single unclaimed service path on the machine.
        if candidates.count == 1 { return candidates[0] }

        // 3. Deterministic assignment by display order, among the displays
        // that have no service yet.
        let waiting = onlineExternalDisplayIDs().filter { services[$0] == nil }.sorted()
        if let index = waiting.firstIndex(of: id), index < candidates.count {
            return candidates[index]
        }
        return nil
    }

    private func onlineExternalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter(Self.canHaveService)
    }

    /// Creates a service object for every matching registry entry except the
    /// `excluded` ones. The caller owns the returned objects and releases those
    /// it does not keep.
    private func videoServices(excluding excluded: Set<UInt64> = []) -> [VideoService] {
        guard let createFn else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("DCPAVServiceProxy"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [VideoService] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            let supported = IORegistryEntryCreateCFProperty(entry,
                                                            "IOAVServiceUserInterfaceSupported" as CFString,
                                                            kCFAllocatorDefault,
                                                            0)?.takeRetainedValue()
            if let supported = supported as? Bool, supported == false { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS,
                  !excluded.contains(entryID) else { continue }
            guard let created = createFn(kCFAllocatorDefault, entry) else { continue }
            result.append(VideoService(entryID: entryID, portIndex: dcpPortIndex(of: entry), service: created))
        }
        return result
    }

    /// Reads the `dispextN` / `DCPEXTN` role from the service's ancestor chain.
    private func dcpPortIndex(of entry: io_registry_entry_t) -> Int? {
        var current: io_registry_entry_t = entry
        IOObjectRetain(current)
        for _ in 0..<6 {
            for key in ["interface-name", "role"] {
                if let value = IORegistryEntryCreateCFProperty(current,
                                                               key as CFString,
                                                               kCFAllocatorDefault,
                                                               0)?.takeRetainedValue() as? String {
                    if let range = value.range(of: "dispext") ?? value.range(of: "DCPEXT") {
                        let digits = value[range.upperBound...].prefix { $0.isNumber }
                        if let index = Int(digits) { IOObjectRelease(current); return index }
                    }
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else {
                break
            }
            IOObjectRelease(current)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }

    // MARK: DDC/CI transactions

    private func write(_ bytes: [UInt8], to service: UnsafeMutableRawPointer) -> Bool {
        guard let writeFn else { return false }
        var buffer = bytes
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return writeFn(service, chipAddress, dataAddress, base, UInt32(raw.count))
        }
        return result == 0
    }

    private func read(length: Int, from service: UnsafeMutableRawPointer) -> [UInt8]? {
        guard let readFn else { return nil }
        var buffer = [UInt8](repeating: 0, count: max(length, 12))
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return readFn(service, chipAddress, dataAddress, base, UInt32(raw.count))
        }
        guard result == 0 else { return nil }
        return buffer
    }

    /// DDC/CI asks hosts to leave ~50 ms between transactions.
    private func pace(_ id: CGDirectDisplayID, minimum: TimeInterval = 0.05) {
        if let last = lastTransaction[id] {
            let wait = minimum - Date().timeIntervalSince(last)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
    }

    private func touch(_ id: CGDirectDisplayID) { lastTransaction[id] = Date() }

    /// Reads the current and maximum value for a VCP code.
    ///
    /// Reply frame: `6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <checksum>`,
    /// checksum = 0x50 XOR every preceding byte. The frame is located by its
    /// marker rather than a fixed offset; result 0x01 means "unsupported".
    public func reading(code: UInt8, display id: CGDirectDisplayID) -> Reading {
        reading(code: code, display: id, yieldToWrites: true)
    }

    private func reading(code: UInt8, display id: CGDirectDisplayID, yieldToWrites: Bool) -> Reading {
        if yieldToWrites { yieldToWriters() }
        lock.lock()
        defer { lock.unlock() }
        guard let service = service(for: id) else { return .noReply }
        if unsupported[id]?.contains(code) == true { return .unsupported }
        for _ in 0..<3 {
            pace(id)
            let checksum = UInt8((0x82 ^ 0x01 ^ Int(code) ^ 0x6E) & 0xFF)
            let sent = write([0x82, 0x01, code, checksum], to: service)
            touch(id)
            guard sent else { continue }
            usleep(45_000)
            let response = read(length: 12, from: service)
            touch(id)
            guard let response else { continue }
            for base in 0...max(0, response.count - 10) where base + 9 < response.count {
                guard response[base] == 0x6E, response[base + 1] & 0x80 != 0,
                      response[base + 2] == 0x02, response[base + 4] == code else { continue }
                if base + 10 < response.count {
                    let expected = response[base...(base + 9)].reduce(UInt8(0x50)) { $0 ^ $1 }
                    guard expected == response[base + 10] else { continue }
                }
                if response[base + 3] == 0x01 {
                    unsupported[id, default: []].insert(code)
                    readFailures[id] = 0
                    return .unsupported
                }
                guard response[base + 3] == 0x00 else { continue }
                let maximum = Int(response[base + 6]) << 8 | Int(response[base + 7])
                let current = Int(response[base + 8]) << 8 | Int(response[base + 9])
                readFailures[id] = 0
                if maximum > 0 { maximums[id, default: [:]][code] = maximum }
                return .value(current: current, maximum: maximum)
            }
        }
        readFailures[id, default: 0] += 1
        if readFailures[id, default: 0] > 4 {
            // Re-match the service next time (the port may have changed), and
            // count afresh so one bad spell does not re-match on every read.
            dropService(for: id)
            readFailures[id] = 0
        }
        return .noReply
    }

    public func read(_ vcp: VCP, display id: CGDirectDisplayID) -> (current: Int, maximum: Int)? {
        read(code: vcp.rawValue, display: id)
    }

    public func read(code: UInt8, display id: CGDirectDisplayID) -> (current: Int, maximum: Int)? {
        if case let .value(current, maximum) = reading(code: code, display: id) { return (current, maximum) }
        return nil
    }

    @discardableResult
    public func write(_ vcp: VCP, value: Int, display id: CGDirectDisplayID) -> Bool {
        write(code: vcp.rawValue, value: value, display: id)
    }

    /// Set VCP: `84 03 <vcp> <hi> <lo> <checksum>`, checksum over the
    /// destination (0x6E) and source (0x51) addresses and the payload.
    @discardableResult
    public func write(code: UInt8, value: Int, display id: CGDirectDisplayID) -> Bool {
        writerEnter()
        defer { writerExit() }
        lock.lock()
        defer { lock.unlock() }
        guard let service = service(for: id) else { return false }
        let clamped = max(0, min(0xFFFF, value))
        let high = UInt8((clamped >> 8) & 0xFF)
        let low = UInt8(clamped & 0xFF)
        let header: UInt8 = 0x6E ^ 0x51 ^ 0x84 ^ 0x03
        let checksum: UInt8 = header ^ code ^ high ^ low
        pace(id)
        var ok = false
        for _ in 0..<2 where !ok {
            ok = write([0x84, 0x03, code, high, low, checksum], to: service)
            touch(id)
            if !ok { usleep(50_000) }   // the same gap DDC/CI asks for between transactions
        }
        return ok
    }

    public func value(_ vcp: VCP, display id: CGDirectDisplayID) -> Double? {
        guard let reading = read(vcp, display: id), reading.maximum > 0 else { return nil }
        // Some monitors report a current value above their stated maximum.
        return min(1, Double(reading.current) / Double(reading.maximum))
    }

    /// Writes a 0…1 value, scaled to the monitor's maximum (read once, then cached).
    public func setValue(_ value: Double, vcp: VCP, display id: CGDirectDisplayID) -> Bool {
        writerEnter()
        defer { writerExit() }
        lock.lock()
        defer { lock.unlock() }
        var maximum = maximums[id]?[vcp.rawValue]
        if maximum == nil, case let .value(_, max) = reading(code: vcp.rawValue, display: id, yieldToWrites: false) {
            maximum = max
        }
        guard let maximum, maximum > 0 else { return false }
        let raw = Int((max(0, min(1, value)) * Double(maximum)).rounded())
        return write(vcp, value: raw, display: id)
    }

    public func maximum(_ vcp: VCP, display id: CGDirectDisplayID) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return maximums[id]?[vcp.rawValue]
    }

    // MARK: Capabilities

    /// Reads and parses the monitor's capabilities string (Capabilities
    /// Request 0xF3, fetched in 32-byte fragments). Cached per display.
    public func capabilities(display id: CGDirectDisplayID) -> DDCCapabilities? {
        lock.lock()
        if let cached = capabilityCache[id] { lock.unlock(); return cached }
        guard let service = service(for: id) else { lock.unlock(); return nil }
        // Invalidation may release the cache's ownership between fragments.
        _ = Unmanaged<AnyObject>.fromOpaque(service).retain()
        let generation = bindingGenerations[id, default: 0]
        lock.unlock()
        defer { release(service) }
        var data: [UInt8] = []
        var offset = 0
        var failures = 0
        while offset < 2048 && failures < 3 {
            // The lock is held per fragment only, so slider writes can go
            // between fragments instead of waiting ~2 s for the whole string.
            yieldToWriters()
            lock.lock()
            defer { lock.unlock() }
            guard bindingGenerations[id, default: 0] == generation else { return nil }
            pace(id)
            let hi = UInt8((offset >> 8) & 0xFF), lo = UInt8(offset & 0xFF)
            let checksum: UInt8 = (0x6E ^ 0x51 ^ 0x83 ^ 0xF3 as UInt8) ^ hi ^ lo
            let sent = write([0x83, 0xF3, hi, lo, checksum], to: service)
            touch(id)
            guard sent else { failures += 1; continue }
            usleep(60_000)
            let response = read(length: 38, from: service)
            touch(id)
            // Reply: 6E <0x80|len> E3 <offHi> <offLo> <data…> <checksum>
            guard let response, response.count > 5, response[0] == 0x6E, response[2] == 0xE3,
                  Int(response[3]) << 8 | Int(response[4]) == offset else {
                failures += 1
                continue
            }
            let length = Int(response[1] & 0x7F) - 3
            if length <= 0 { break }
            let end = min(response.count - 1, 5 + length)
            let fragment = response[5..<end].filter { $0 != 0 }
            if fragment.isEmpty { break }
            data.append(contentsOf: fragment)
            offset += length
            failures = 0
        }
        // Keep printable ASCII only: one stray byte must not discard the string
        // (it would then be fetched again, ~2 s, on every full reload).
        let printable = data.filter { (0x20...0x7E).contains($0) }
        guard !printable.isEmpty, let text = String(bytes: printable, encoding: .ascii) else { return nil }
        let parsed = DDCCapabilities(raw: text)
        lock.lock()
        defer { lock.unlock() }
        guard bindingGenerations[id, default: 0] == generation else { return nil }
        capabilityCache[id] = parsed
        return parsed
    }

    public struct DDCProbeResult {
        public let portIndex: Int?
        public let service: UInt
        public let writeResult: Int32
        public let readResult: Int32
        public let bytes: [UInt8]
    }

    /// Transport-level diagnostic used by the command line probe.
    public func probeAll(display id: CGDirectDisplayID) -> [DDCProbeResult] {
        lock.lock()
        defer { lock.unlock() }
        guard let readFn, let writeFn else { return [] }
        var results: [DDCProbeResult] = []
        let candidates = videoServices()
        defer { candidates.forEach { release($0.service) } }
        for candidate in candidates {
            var request: [UInt8] = [0x82, 0x01, 0x10, UInt8((0x82 ^ 0x01 ^ 0x10 ^ 0x6E) & 0xFF)]
            let writeResult = request.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return writeFn(candidate.service, chipAddress, dataAddress, base, UInt32(raw.count))
            }
            usleep(60_000)
            var buffer = [UInt8](repeating: 0, count: 12)
            let readResult = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return readFn(candidate.service, chipAddress, dataAddress, base, UInt32(raw.count))
            }
            results.append(DDCProbeResult(portIndex: candidate.portIndex,
                                          service: UInt(bitPattern: candidate.service),
                                          writeResult: writeResult,
                                          readResult: readResult,
                                          bytes: buffer))
        }
        return results
    }

    /// Forgets everything cached for a display. Waits for a running
    /// transaction, so call it off the main thread.
    public func invalidate(display id: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        dropService(for: id)
        readFailures.removeValue(forKey: id)
        maximums.removeValue(forKey: id)
        unsupported.removeValue(forKey: id)
        capabilityCache.removeValue(forKey: id)
    }
}

/// Parsed MCCS capabilities string, e.g.
/// `(prot(monitor)type(LCD)model(S2725QC)vcp(10 12 14(05 08 0B) 60(0F 11 1B) 62)mccs_ver(2.1))`.
public struct DDCCapabilities: Equatable {
    public let raw: String
    public let model: String?
    public let type: String?
    public let mccsVersion: String?
    /// Supported VCP codes, each with its allowed values when the string lists them.
    public let codes: [UInt8: [Int]]

    public init(raw: String) {
        self.raw = raw
        model = DDCCapabilities.section("model", in: raw)
        type = DDCCapabilities.section("type", in: raw)
        mccsVersion = DDCCapabilities.section("mccs_ver", in: raw)
        codes = DDCCapabilities.parseVCP(DDCCapabilities.section("vcp", in: raw) ?? "")
    }

    public func supports(_ vcp: DDCController.VCP) -> Bool { codes[vcp.rawValue] != nil }

    public func values(for vcp: DDCController.VCP) -> [Int] { codes[vcp.rawValue] ?? [] }

    /// Contents of `name(...)`, honouring nested parentheses.
    static func section(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + "(") else { return nil }
        var depth = 1
        var index = range.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return String(text[range.upperBound..<index]) }
            }
            index = text.index(after: index)
        }
        return String(text[range.upperBound...])
    }

    static func parseVCP(_ text: String) -> [UInt8: [Int]] {
        var result: [UInt8: [Int]] = [:]
        var lastCode: UInt8?
        var token = ""
        var depth = 0
        var nested = ""
        func flush() {
            if !token.isEmpty, let code = UInt8(token, radix: 16) {
                result[code] = result[code] ?? []
                lastCode = code
            }
            token = ""
        }
        for character in text {
            if depth > 0 {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth == 0 {
                    if let code = lastCode {
                        result[code] = nested.split(separator: " ").compactMap { Int($0, radix: 16) }
                    }
                    nested = ""
                } else {
                    nested.append(character)
                }
                continue
            }
            if character == "(" { flush(); depth = 1; continue }
            if character.isHexDigit { token.append(character) } else { flush() }
        }
        flush()
        return result
    }
}
