import Foundation
import CoreGraphics
import IOKit
import IOKit.hid
import os

private let usbLog = Logger(subsystem: "app.greatdisplay", category: "usb")

/// DDC/CI over the USB HID bridge built into Dell monitors.
///
/// Some Dell monitors answer DDC/CI on their USB upstream connection while
/// returning the DDC/CI Null Message on the video cable. DDPM reaches them
/// through the Realtek vendor HID interface (`0BDA:1100`, usage page `0xFFDA`),
/// which acts as a USB-to-I2C bridge. This transport performs the same session
/// handshake and then sends standard DDC/CI frames through it.
///
/// The video-side `DCPAVServiceProxy` remains the primary path. This is used
/// only for monitors that refuse it, and only when the monitor's USB HID
/// interface is present.
final class DellUSBTransport {
    static let shared = DellUSBTransport()

    struct Monitor {
        let name: String
        let registryID: UInt64
        fileprivate let device: IOHIDDevice
    }

    enum Reading {
        case value(current: Int, maximum: Int)
        case unsupported
        case noReply
    }

    private static let reportLength = 192
    private static let vendorID = 0x0BDA
    private static let productID = 0x1100
    private static let usagePage = 0xFFDA
    private static let discoveryInterval: TimeInterval = 5

    /// Response keys derived from the handshake keys DDPM uses. The monitor
    /// issues a fresh challenge for every session; only these eight-byte
    /// values take part in the reply.
    private static let responseKeys: [[UInt8]] = [
        [0xB1, 0xA4, 0xD6, 0xBC, 0x96, 0xBC, 0xA9, 0xCF],
        [0x9E, 0xDE, 0xF3, 0xFC, 0xFD, 0x8A, 0x8E, 0xDD],
        [0x1A, 0x56, 0x50, 0x91, 0x90, 0xF5, 0xDB, 0xA4],
        [0xAE, 0xCA, 0xC3, 0x0B, 0x0E, 0x0D, 0x64, 0x27],
        [0x00, 0x00, 0x00, 0x70, 0x73, 0x1B, 0x45, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x45, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x45, 0x00],
        [0x00, 0x00, 0x00, 0x00, 0x00, 0x57, 0x45, 0x00],
        [0x00, 0x00, 0x00, 0x70, 0x73, 0x17, 0x45, 0x00],
        [0x5A, 0x29, 0x2E, 0xC9, 0xE4, 0xED, 0xF2, 0x9E],
    ]

    /// Serializes the shared HID device: one report exchange at a time.
    private let lock = NSRecursiveLock()
    private var monitors: [Monitor] = []
    private var discoveredAt: Date?

    private init() {}

    // MARK: Discovery

    /// The USB monitor with this EDID product name, when exactly one matches.
    /// Names are compared case- and punctuation-insensitively, with a leading
    /// vendor name ignored ("DELL U2723QE" matches "U2723QE").
    func monitor(named rawName: String) -> Monitor? {
        let name = Self.normalize(rawName)
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let found = match(name) { return found }
        if let discoveredAt, Date().timeIntervalSince(discoveredAt) < Self.discoveryInterval {
            return nil
        }
        discover()
        return match(name)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        for monitor in monitors {
            IOHIDDeviceClose(monitor.device, 0)
        }
        monitors.removeAll()
        discoveredAt = nil
    }

    private func match(_ name: String) -> Monitor? {
        let matches = monitors.filter { Self.normalize($0.name) == name }
        // Two identical monitors cannot be told apart from their USB identity.
        return matches.count == 1 ? matches[0] : nil
    }

    private func discover() {
        for monitor in monitors {
            IOHIDDeviceClose(monitor.device, 0)
        }
        monitors.removeAll()
        discoveredAt = Date()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOHIDDevice"),
                                           &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard matchesBridge(entry) else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS else { continue }
            guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, entry) else { continue }
            if let monitor = connect(device: device, entryID: entryID) {
                monitors.append(monitor)
            }
        }
    }

    private func matchesBridge(_ entry: io_registry_entry_t) -> Bool {
        let vendor = property(entry, kIOHIDVendorIDKey) ?? 0
        let product = property(entry, kIOHIDProductIDKey) ?? 0
        let usage = property(entry, kIOHIDPrimaryUsagePageKey) ?? 0
        return vendor == Self.vendorID && product == Self.productID && usage == Self.usagePage
    }

    private func property(_ entry: io_registry_entry_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(entry,
                                                          key as CFString,
                                                          kCFAllocatorDefault,
                                                          0)?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint32Value
    }

    /// Opens the bridge and tries the session keys until the monitor answers.
    /// A failed key can leave the bridge unresponsive, so each attempt starts
    /// from a fresh device handle.
    private func connect(device: IOHIDDevice, entryID: UInt64) -> Monitor? {
        // The Realtek report protocol exposes its I2C command on output usage
        // 0xD1. Dell's control-transfer bridges use a different descriptor and
        // are handled by DellMonitorSDKBridge instead.
        guard let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data,
              descriptor.contains(0xD1) else { return nil }
        for key in Self.responseKeys {
            guard IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { return nil }
            setBusSpeed(device)
            if handshake(device, responseKey: key), let name = monitorName(device), !name.isEmpty {
                return Monitor(name: name, registryID: entryID, device: device)
            }
            IOHIDDeviceClose(device, 0)
        }
        return nil
    }

    // MARK: Session handshake

    private func setBusSpeed(_ device: IOHIDDevice) {
        _ = send(device, [0x40, 0x06, 0x00])
        usleep(20_000)
    }

    private func handshake(_ device: IOHIDDevice, responseKey: [UInt8]) -> Bool {
        guard send(device, [0x40, 0xE1, 0x01]), let challenge = read(device, 16), challenge.count == 16 else {
            return false
        }
        var temp: [UInt8]
        // The monitor picks which half of the challenge is transformed from
        // the parity of its first and last bytes.
        let parity = (challenge[0].nonzeroBitCount & 1) ^ (challenge[15].nonzeroBitCount & 1)
        if parity == 0 {
            temp = Array(challenge[8..<16])
            let offset = Int(challenge[6] & 7)
            temp[offset] ^= challenge[offset]
        } else {
            temp = Array(challenge[0..<8])
            let offset = Int(challenge[14] & 7)
            temp[offset] ^= challenge[8 + offset]
        }
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = 0x40
        report[1] = 0xE1
        report[2] = 0x03
        for index in 0..<8 {
            report[64 + index] = temp[index] ^ responseKey[index]
        }
        guard send(device, report) else { return false }
        usleep(130_000)
        return true
    }

    /// The monitor's model name over the Dell vendor read command. This also
    /// verifies that the session handshake was accepted.
    private func monitorName(_ device: IOHIDDevice) -> String? {
        guard let response = transaction(device, frame: Self.readFrame(command: 0xEB, register: 0x01), readLength: 32),
              response.count >= 6, response[0] == 0x6E, response[2] == 0x02, response[3] == 0 else {
            return nil
        }
        let length = Int(response[1] & 0x7F) - 3
        guard length > 0 else { return nil }
        let end = min(response.count, 5 + length)
        let name = response[5..<end].prefix { $0 != 0 }
        return String(bytes: name, encoding: .ascii)
    }

    // MARK: DDC/CI

    func rawResponse(code: UInt8, monitor: Monitor) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return transaction(monitor.device, frame: Self.getFrame(code), readLength: 32)
    }

    func reading(code: UInt8, monitor: Monitor) -> Reading {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<3 {
            guard let response = transaction(monitor.device,
                                             frame: Self.getFrame(code),
                                             readLength: 32) else { continue }
            if Self.isNullMessage(response) {
                usleep(50_000)
                continue
            }
            if let parsed = Self.parse(response, code: code) { return parsed }
        }
        return .noReply
    }

    @discardableResult
    func write(code: UInt8, value: Int, monitor: Monitor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let clamped = max(0, min(0xFFFF, value))
        let ok = i2cWrite(monitor.device, frame: Self.setFrame(code, value: clamped))
        if ok { usleep(50_000) }
        return ok
    }

    func capabilities(monitor: Monitor) -> DDCCapabilities? {
        lock.lock()
        defer { lock.unlock() }
        var data: [UInt8] = []
        var offset = 0
        var failures = 0
        while offset < 2048 && failures < 3 {
            guard let response = transaction(monitor.device,
                                             frame: Self.capabilitiesFrame(offset: offset),
                                             readLength: 64) else {
                failures += 1
                continue
            }
            // The USB bridge wraps the monitor's reply in its own envelope,
            // so locate the inner capabilities frame rather than assuming
            // it starts at byte zero.
            guard let base = Self.innerFrameOffset(in: response, offset: offset) else {
                failures += 1
                continue
            }
            let length = Int(response[base + 1] & 0x7F) - 3
            if length <= 0 { break }
            let end = min(response.count - 1, base + 5 + length)
            let fragment = response[(base + 5)..<end].filter { $0 != 0 }
            if fragment.isEmpty { break }
            data.append(contentsOf: fragment)
            offset += length
            failures = 0
        }
        let printable = data.filter { (0x20...0x7E).contains($0) }
        guard !printable.isEmpty, let text = String(bytes: printable, encoding: .ascii) else { return nil }
        return DDCCapabilities(raw: text)
    }

    private func transaction(_ device: IOHIDDevice, frame: [UInt8], readLength: Int) -> [UInt8]? {
        guard i2cWrite(device, frame: frame) else { return nil }
        usleep(45_000)
        return i2cRead(device, length: readLength)
    }

    private func i2cWrite(_ device: IOHIDDevice, frame: [UInt8]) -> Bool {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = 0x40
        report[1] = 0xC6
        report[6] = UInt8(min(frame.count, 181))
        report[8] = 0x6E
        report[10] = 0x80
        for (index, byte) in frame.prefix(181).enumerated() {
            report[64 + index] = byte
        }
        return send(device, report)
    }

    private func i2cRead(_ device: IOHIDDevice, length: Int) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        report[0] = 0x40
        report[1] = 0xD6
        report[6] = UInt8(min(max(length, 1), 192))
        report[8] = 0x6E
        report[10] = 0x80
        guard send(device, report) else { return nil }
        usleep(10_000)
        return read(device, length)
    }

    private func send(_ device: IOHIDDevice, _ bytes: [UInt8]) -> Bool {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        for (index, byte) in bytes.prefix(Self.reportLength).enumerated() {
            report[index] = byte
        }
        let result = report.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device,
                                 kIOHIDReportTypeOutput,
                                 0,
                                 buffer.baseAddress!,
                                 Self.reportLength)
        }
        if result != kIOReturnSuccess {
            usbLog.debug("HID write failed: \(result, privacy: .public)")
            return false
        }
        return true
    }

    private func read(_ device: IOHIDDevice, _ length: Int) -> [UInt8]? {
        var report = [UInt8](repeating: 0, count: Self.reportLength)
        var received = Self.reportLength
        let result = report.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceGetReport(device,
                                 kIOHIDReportTypeInput,
                                 0,
                                 buffer.baseAddress!,
                                 &received)
        }
        guard result == kIOReturnSuccess else {
            usbLog.debug("HID read failed: \(result, privacy: .public)")
            return nil
        }
        return Array(report.prefix(min(length, Int(received))))
    }

    // MARK: Frames

    private static func getFrame(_ code: UInt8) -> [UInt8] {
        let inner: [UInt8] = [0x51, 0x82, 0x01, code, 0]
        return envelope(inner, command: 0xEB)
    }

    private static func setFrame(_ code: UInt8, value: Int) -> [UInt8] {
        let inner: [UInt8] = [0x51, 0x84, 0x03, code,
                              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF), 0]
        return envelope(inner, command: 0xEA)
    }

    private static func capabilitiesFrame(offset: Int) -> [UInt8] {
        let inner: [UInt8] = [0x51, 0x83, 0xF3,
                              UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), 0]
        return envelope(inner, command: 0xEB)
    }

    private static func readFrame(command: UInt8, register: UInt8) -> [UInt8] {
        var frame: [UInt8] = [0x51, 0x82, command, register, 0]
        frame[4] = checksum(frame)
        return frame
    }

    private static func envelope(_ inner: [UInt8], command: UInt8) -> [UInt8] {
        var inner = inner
        inner[inner.count - 1] = checksum(inner)
        let length = 4 + inner.count
        var frame: [UInt8] = [0x51, UInt8(0x80 | length), command, 0xFE, 0x00, 0x00]
        frame.append(contentsOf: inner)
        frame.append(checksum(frame))
        return frame
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E) { $0 ^ $1 }
    }

    /// Finds the start of the inner capabilities reply (0x6E ... 0xE3) whose
    /// payload offset matches the request.
    private static func innerFrameOffset(in response: [UInt8], offset: Int) -> Int? {
        guard response.count >= 6 else { return nil }
        for base in 0...(response.count - 6) {
            guard response[base] == 0x6E, response[base + 2] == 0xE3 else { continue }
            let high = Int(response[base + 3])
            let low = Int(response[base + 4])
            if (high << 8 | low) == offset { return base }
        }
        return nil
    }

    static func isNullMessage(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        return (0...(bytes.count - 3)).contains {
            bytes[$0] == 0x6E && bytes[$0 + 1] == 0x80 && bytes[$0 + 2] == 0xBE
        }
    }

    private static func parse(_ response: [UInt8], code: UInt8) -> Reading? {
        guard response.count >= 10 else { return nil }
        for base in 0...max(0, response.count - 10) where base + 9 < response.count {
            guard response[base] == 0x6E, response[base + 1] & 0x80 != 0,
                  response[base + 2] == 0x02, response[base + 4] == code else { continue }
            if base + 10 < response.count {
                let expected = response[base...(base + 9)].reduce(UInt8(0x50)) { $0 ^ $1 }
                guard expected == response[base + 10] else { continue }
            }
            if response[base + 3] == 0x01 { return .unsupported }
            guard response[base + 3] == 0x00 else { continue }
            let maximum = Int(response[base + 6]) << 8 | Int(response[base + 7])
            let current = Int(response[base + 8]) << 8 | Int(response[base + 9])
            return .value(current: current, maximum: maximum)
        }
        return nil
    }

    private static func normalize(_ name: String) -> String {
        var text = name.lowercased()
        if text.hasPrefix("dell ") { text.removeFirst(5) }
        return text.filter { $0.isLetter || $0.isNumber }
    }
}
