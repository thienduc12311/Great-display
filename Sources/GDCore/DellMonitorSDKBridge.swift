import Foundation
import os

private let sdkLog = Logger(subsystem: "app.greatdisplay", category: "dell-sdk")

/// In-process access to Dell's monitor SDK for monitors whose USB bridge does
/// not use the Realtek HID report path. DDPM ships the SDK; Great Display only
/// loads it when it is present and never starts DDPM or its command-line tool.
final class DellMonitorSDKBridge {
    static let shared = DellMonitorSDKBridge()

    struct Monitor: Equatable {
        let index: Int
        let name: String
    }

    private typealias InitializeFn = @convention(c) () -> Int32
    private typealias AvailableFn = @convention(c) (UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ConnectFn = @convention(c) (Int32, UnsafeMutablePointer<UInt16>) -> Int32
    private typealias DisconnectFn = @convention(c) () -> Int32
    private typealias NameFn = @convention(c) (UnsafeMutablePointer<CChar>) -> Int32
    private typealias GetDDCFn = @convention(c) (UnsafePointer<UInt8>, Int32, UnsafeMutablePointer<UInt8>, Int32) -> Int32
    private typealias SetDDCFn = @convention(c) (UnsafePointer<UInt8>, Int32) -> Int32

    private static let path = "/Applications/DDPM/DDPM.app/Contents/Frameworks/libDellMonitorSdkLib.dylib"
    private static let token: UInt16 = 2

    private let lock = NSRecursiveLock()
    private var handle: UnsafeMutableRawPointer?
    private var initializeFn: InitializeFn?
    private var availableFn: AvailableFn?
    private var connectFn: ConnectFn?
    private var disconnectFn: DisconnectFn?
    private var nameFn: NameFn?
    private var getDDCFn: GetDDCFn?
    private var setDDCFn: SetDDCFn?

    private var monitors: [Monitor] = []
    private var enumerated = false
    private var enumeratedAt: Date?
    private var connected: Int?

    private init() {
        guard FileManager.default.fileExists(atPath: Self.path),
              let handle = dlopen(Self.path, RTLD_NOW) else { return }
        self.handle = handle
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }
        initializeFn = symbol("Initialize", InitializeFn.self)
        availableFn = symbol("GetAvailableMonitors", AvailableFn.self)
        connectFn = symbol("ConnectMonitorEx", ConnectFn.self)
        disconnectFn = symbol("DisconnectMonitor", DisconnectFn.self)
        nameFn = symbol("GetMonitorName", NameFn.self)
        getDDCFn = symbol("GetDDCCICommand", GetDDCFn.self)
        setDDCFn = symbol("SetDDCCICommand", SetDDCFn.self)
        _ = initializeFn?()
    }

    var isAvailable: Bool {
        initializeFn != nil && availableFn != nil && connectFn != nil &&
            nameFn != nil && getDDCFn != nil && setDDCFn != nil
    }

    func monitor(named rawName: String) -> Monitor? {
        let name = Self.normalize(rawName)
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if !enumerated { enumerate() }
        var matches = monitors.filter { Self.normalize($0.name) == name }
        if matches.isEmpty, let enumeratedAt, Date().timeIntervalSince(enumeratedAt) > 5 {
            enumerate()
            matches = monitors.filter { Self.normalize($0.name) == name }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    func read(code: UInt8, monitor: Monitor) -> DDCController.Reading {
        guard let reply = rawCommand(code: code, monitor: monitor) else { return .noReply }
        return Self.parse(reply, code: code) ?? .noReply
    }

    func rawCommand(code: UInt8, monitor: Monitor) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard prepare(monitor) else { return nil }
        var frame: [UInt8] = [0x51, 0x82, 0x01, code, 0]
        frame[4] = Self.checksum(frame)
        return command(frame, readLength: 32)
    }

    @discardableResult
    func write(code: UInt8, value: Int, monitor: Monitor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard prepare(monitor) else { return false }
        let clamped = max(0, min(0xFFFF, value))
        var frame: [UInt8] = [0x51, 0x84, 0x03, code,
                              UInt8((clamped >> 8) & 0xFF), UInt8(clamped & 0xFF), 0]
        frame[6] = Self.checksum(frame)
        guard let setDDCFn else { return false }
        let result = frame.withUnsafeBufferPointer {
            setDDCFn($0.baseAddress!, Int32($0.count))
        }
        if result != 0 {
            sdkLog.debug("SetDDCCICommand failed: \(result, privacy: .public)")
            return false
        }
        usleep(50_000)
        return true
    }

    func capabilities(monitor: Monitor) -> DDCCapabilities? {
        lock.lock()
        defer { lock.unlock() }
        guard prepare(monitor) else { return nil }
        var data: [UInt8] = []
        var offset = 0
        var failures = 0
        while offset < 2048 && failures < 3 {
            var frame: [UInt8] = [0x51, 0x83, 0xF3,
                                  UInt8((offset >> 8) & 0xFF), UInt8(offset & 0xFF), 0]
            frame[5] = Self.checksum(frame)
            guard let reply = command(frame, readLength: 64) else {
                failures += 1
                continue
            }
            guard reply.count > 5, reply[0] == 0x6E, reply[2] == 0xE3,
                  Int(reply[3]) << 8 | Int(reply[4]) == offset else {
                failures += 1
                continue
            }
            let length = Int(reply[1] & 0x7F) - 3
            if length <= 0 { break }
            let end = min(reply.count - 1, 5 + length)
            let fragment = reply[5..<end].filter { $0 != 0 }
            if fragment.isEmpty { break }
            data.append(contentsOf: fragment)
            offset += length
            failures = 0
        }
        let printable = data.filter { (0x20...0x7E).contains($0) }
        guard !printable.isEmpty, let text = String(bytes: printable, encoding: .ascii) else { return nil }
        return DDCCapabilities(raw: text)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        disconnect()
        monitors.removeAll()
        enumerated = false
        enumeratedAt = nil
    }

    // MARK: Session

    private func enumerate() {
        guard let availableFn, let connectFn, let nameFn, let disconnectFn else { return }
        disconnect()
        enumerated = true
        enumeratedAt = Date()
        var count: UInt8 = 0
        guard availableFn(&count) == 0 else { return }
        for index in 0..<Int(count) {
            var token = Self.token
            guard connectFn(Int32(index), &token) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: 64)
            let result = nameFn(&buffer)
            _ = disconnectFn()
            guard result == 0 else { continue }
            let name = String(cString: buffer)
            if !name.isEmpty {
                monitors.append(Monitor(index: index, name: name))
            }
        }
    }

    private func prepare(_ monitor: Monitor) -> Bool {
        guard isAvailable else { return false }
        if connected == monitor.index { return true }
        disconnect()
        guard let connectFn else { return false }
        var token = Self.token
        guard connectFn(Int32(monitor.index), &token) == 0 else {
            sdkLog.debug("ConnectMonitorEx failed for index \(monitor.index, privacy: .public)")
            return false
        }
        connected = monitor.index
        return true
    }

    private func disconnect() {
        guard let connected, let disconnectFn else { return }
        _ = disconnectFn()
        self.connected = nil
    }

    private func command(_ frame: [UInt8], readLength: Int) -> [UInt8]? {
        guard let getDDCFn else { return nil }
        var output = [UInt8](repeating: 0, count: readLength)
        let result = frame.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                getDDCFn(input.baseAddress!, Int32(input.count),
                         output.baseAddress!, Int32(output.count))
            }
        }
        guard result == 0 else {
            sdkLog.debug("GetDDCCICommand failed: \(result, privacy: .public)")
            return nil
        }
        return output
    }

    // MARK: Replies

    private static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(0x6E) { $0 ^ $1 }
    }

    private static func parse(_ response: [UInt8], code: UInt8) -> DDCController.Reading? {
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
