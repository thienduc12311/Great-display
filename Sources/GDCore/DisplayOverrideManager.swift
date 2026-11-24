import Foundation
import CoreGraphics

/// Manages macOS display override plists (`scale-resolutions`) in
/// `/Library/Displays/Contents/Resources/Overrides/` so physical displays can
/// expose custom HiDPI resolutions beyond the limited set macOS offers by
/// default.
public final class DisplayOverrideManager: @unchecked Sendable {
    public static let shared = DisplayOverrideManager()

    public static let userOverridesRoot = URL(fileURLWithPath: "/Library/Displays/Contents/Resources/Overrides", isDirectory: true)
    public static let systemOverridesRoot = URL(fileURLWithPath: "/System/Library/Displays/Contents/Resources/Overrides", isDirectory: true)

    public enum OverrideError: LocalizedError, Equatable {
        case unsupportedDisplay(String)
        case emptyResolutions
        case invalidResolution(String)
        case encodingFailed(String)
        case cancelled
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedDisplay(let reason): return reason
            case .emptyResolutions: return "Add at least one resolution before applying an override."
            case .invalidResolution(let reason): return reason
            case .encodingFailed(let reason): return "Could not build display override plist: \(reason)"
            case .cancelled: return "Administrator authentication was cancelled."
            case .commandFailed(let reason): return reason
            }
        }
    }

    private init() {}

    // MARK: - Paths

    public static func vendorDirectoryName(vendorID: UInt32) -> String {
        String(format: "DisplayVendorID-%x", vendorID)
    }

    public static func productFileName(modelID: UInt32) -> String {
        String(format: "DisplayProductID-%x", modelID)
    }

    public func userOverrideURL(vendorID: UInt32, modelID: UInt32) -> URL {
        Self.userOverridesRoot
            .appendingPathComponent(Self.vendorDirectoryName(vendorID: vendorID), isDirectory: true)
            .appendingPathComponent(Self.productFileName(modelID: modelID), isDirectory: false)
    }

    public func systemOverrideURL(vendorID: UInt32, modelID: UInt32) -> URL {
        Self.systemOverridesRoot
            .appendingPathComponent(Self.vendorDirectoryName(vendorID: vendorID), isDirectory: true)
            .appendingPathComponent(Self.productFileName(modelID: modelID), isDirectory: false)
    }

    public func canOverride(_ display: DisplayInfo) -> Bool {
        !display.isVirtual && display.vendorID != 0 && display.modelID != 0
    }

    public func hasInstalledOverride(for display: DisplayInfo) -> Bool {
        guard canOverride(display) else { return false }
        let url = userOverrideURL(vendorID: display.vendorID, modelID: display.modelID)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Binary scale-resolutions encoding

    /// Encodes a logical resolution into macOS's big-endian `scale-resolutions`
    /// binary format.
    ///
    /// HiDPI entries store twice the logical width and height as the backing
    /// framebuffer, followed by `0x00000001` (HiDPI) and `0x00200000` (scaled).
    public static func encodeScaleResolution(_ resolution: CustomResolution) -> Data {
        var words: [UInt32]
        if resolution.hiDPI {
            words = [
                UInt32(resolution.width * 2).bigEndian,
                UInt32(resolution.height * 2).bigEndian,
                UInt32(0x0000_0001).bigEndian,
                UInt32(0x0020_0000).bigEndian,
            ]
        } else {
            words = [
                UInt32(resolution.width).bigEndian,
                UInt32(resolution.height).bigEndian,
            ]
        }
        return words.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decodes a `scale-resolutions` entry (8, 12, 16 or 20 bytes) back into a
    /// logical `CustomResolution`.
    public static func decodeScaleResolution(_ data: Data) -> CustomResolution? {
        guard data.count >= 8 else { return nil }
        func readUInt32(at offset: Int) -> UInt32 {
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { target in
                data.copyBytes(to: target, from: offset..<(offset + 4))
            }
            return UInt32(bigEndian: raw)
        }
        let rawWidth = readUInt32(at: 0)
        let rawHeight = readUInt32(at: 4)
        guard rawWidth >= 320, rawHeight >= 200, rawWidth <= 16384, rawHeight <= 16384 else { return nil }
        if data.count >= 12 {
            let flags = readUInt32(at: 8)
            if (flags & 0x0000_0001) != 0 {
                let logicalW = Int(rawWidth / 2)
                let logicalH = Int(rawHeight / 2)
                guard logicalW >= 320, logicalH >= 200 else { return nil }
                return CustomResolution(width: logicalW, height: logicalH, hiDPI: true)
            }
        }
        return CustomResolution(width: Int(rawWidth), height: Int(rawHeight), hiDPI: false)
    }

    // MARK: - Reading & building plists

    /// Reads the custom resolutions currently installed in `/Library/Displays/...`
    /// for this display.
    public func readInstalledResolutions(for display: DisplayInfo) -> [CustomResolution] {
        guard canOverride(display) else { return [] }
        let url = userOverrideURL(vendorID: display.vendorID, modelID: display.modelID)
        return readResolutions(at: url)
    }

    public func readResolutions(at url: URL) -> [CustomResolution] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entries = plist["scale-resolutions"] as? [Data] else {
            return []
        }
        var seen = Set<String>()
        var result: [CustomResolution] = []
        for entry in entries {
            if let decoded = Self.decodeScaleResolution(entry), seen.insert(decoded.id).inserted {
                result.append(decoded)
            }
        }
        return result.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.hiDPI && !$1.hiDPI
        }
    }

    /// Builds an XML display override plist preserving any existing user or
    /// system override keys (such as colour primaries or product name) while
    /// replacing `scale-resolutions` with the requested list.
    public func buildOverridePlist(for display: DisplayInfo, resolutions: [CustomResolution]) throws -> Data {
        guard canOverride(display) else {
            throw OverrideError.unsupportedDisplay("Display overrides apply only to physical displays with valid vendor and product IDs.")
        }
        guard !resolutions.isEmpty else {
            throw OverrideError.emptyResolutions
        }
        for res in resolutions {
            guard res.width >= 320, res.height >= 200,
                  res.pixelWidth <= 16384, res.pixelHeight <= 16384 else {
                throw OverrideError.invalidResolution("\(res.summary) is outside the supported framebuffer range (up to 16384 px).")
            }
        }

        let userURL = userOverrideURL(vendorID: display.vendorID, modelID: display.modelID)
        let systemURL = systemOverrideURL(vendorID: display.vendorID, modelID: display.modelID)

        var dict: [String: Any] = [:]
        for candidate in [systemURL, userURL] {
            if let data = try? Data(contentsOf: candidate),
               let existing = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                for (key, value) in existing {
                    dict[key] = value
                }
            }
        }

        dict["DisplayVendorID"] = Int(display.vendorID)
        dict["DisplayProductID"] = Int(display.modelID)
        if dict["DisplayProductName"] == nil {
            dict["DisplayProductName"] = display.name
        }

        var seen = Set<String>()
        var encoded: [Data] = []
        for res in resolutions where seen.insert(res.id).inserted {
            encoded.append(Self.encodeScaleResolution(res))
        }
        dict["scale-resolutions"] = encoded

        do {
            return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw OverrideError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Suggested HiDPI presets

    /// Returns a rich set of HiDPI logical resolutions matching the display's
    /// native aspect ratio, giving far more scaling steps than macOS exposes
    /// by default.
    public static func suggestedHiDPIResolutions(for display: DisplayInfo) -> [CustomResolution] {
        let native = nativePixelSize(for: display)
        let ratio = Double(native.width) / Double(max(1, native.height))
        let isPortrait = ratio < 1.0
        let nativeLong = max(native.width, native.height)

        // Cap sensible HiDPI suggestions so 1080p/1440p/4K/5K/ultrawide panels
        // all receive useful scaled HiDPI steps without excessive GPU memory.
        let maxLong: Int
        if ratio > 2.2 || (isPortrait && (1.0 / ratio) > 2.2) {
            maxLong = min(5120, max(nativeLong, 3840))
        } else {
            maxLong = min(3840, max(nativeLong, 2560))
        }

        let ladder = [
            960, 1024, 1152, 1280, 1344, 1440, 1536, 1600, 1680, 1728, 1792, 1856,
            1920, 2048, 2112, 2176, 2240, 2304, 2400, 2496, 2560, 2688, 2752, 2880,
            2944, 3008, 3072, 3200, 3360, 3440, 3584, 3840, 4096, 4608, 5120,
        ]

        var seen = Set<String>()
        var result: [CustomResolution] = []

        for step in ladder where step <= maxLong {
            let width = isPortrait ? Int((Double(step) * ratio / 2).rounded()) * 2 : step
            let height = isPortrait ? step : Int((Double(step) / ratio / 2).rounded()) * 2
            guard width >= 640, height >= 480, width * 2 <= 10240, height * 2 <= 8192 else { continue }
            let res = CustomResolution(width: width, height: height, hiDPI: true)
            if seen.insert(res.id).inserted {
                result.append(res)
            }
        }

        // Also include the exact native pixel dimensions as a HiDPI logical size
        // (e.g. 1920×1080 HiDPI on a 1080p display or 2560×1440 HiDPI on 1440p).
        if native.width >= 640, native.height >= 480, native.width <= 4096, native.height <= 4096 {
            let exact = CustomResolution(width: native.width, height: native.height, hiDPI: true)
            if seen.insert(exact.id).inserted {
                result.append(exact)
            }
        }

        return result.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.height > $1.height
        }
    }

    public static func nativePixelSize(for display: DisplayInfo) -> (width: Int, height: Int) {
        if let native = display.modes.first(where: \.isNative) {
            return (native.pixelWidth, native.pixelHeight)
        }
        if let largest = display.modes.max(by: { ($0.pixelWidth * $0.pixelHeight) < ($1.pixelWidth * $1.pixelHeight) }) {
            return (largest.pixelWidth, largest.pixelHeight)
        }
        if let current = display.currentMode {
            return (current.pixelWidth, current.pixelHeight)
        }
        return (max(1, Int(display.bounds.width)), max(1, Int(display.bounds.height)))
    }

    // MARK: - Installing & removing overrides

    /// Writes the display override plist into `/Library/Displays/Contents/Resources/Overrides/`.
    /// Prompts for administrator privileges when not already running as root.
    public func installOverride(for display: DisplayInfo, resolutions: [CustomResolution]) async -> Result<URL, OverrideError> {
        let plistData: Data
        do {
            plistData = try buildOverridePlist(for: display, resolutions: resolutions)
        } catch let error as OverrideError {
            return .failure(error)
        } catch {
            return .failure(.encodingFailed(error.localizedDescription))
        }

        let targetURL = userOverrideURL(vendorID: display.vendorID, modelID: display.modelID)
        let targetDir = targetURL.deletingLastPathComponent()

        if geteuid() == 0 {
            do {
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
                try plistData.write(to: targetURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: targetURL.path)
                return .success(targetURL)
            } catch {
                return .failure(.commandFailed(error.localizedDescription))
            }
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("greatdisplay-override-\(UUID().uuidString).plist")
        do {
            try plistData.write(to: tempURL, options: .atomic)
        } catch {
            return .failure(.commandFailed("Could not stage temporary plist: \(error.localizedDescription)"))
        }

        let shell = "mkdir -p \(shellQuote(targetDir.path)) && cp \(shellQuote(tempURL.path)) \(shellQuote(targetURL.path)) && chmod 644 \(shellQuote(targetURL.path))"
        let result = await runPrivilegedShell(shell)
        try? FileManager.default.removeItem(at: tempURL)
        switch result {
        case .success: return .success(targetURL)
        case .failure(let error): return .failure(error)
        }
    }

    /// Removes the installed override plist for this display from
    /// `/Library/Displays/Contents/Resources/Overrides/`.
    public func removeOverride(for display: DisplayInfo) async -> Result<Void, OverrideError> {
        guard canOverride(display) else {
            return .failure(.unsupportedDisplay("Display overrides apply only to physical displays with valid vendor and product IDs."))
        }
        let targetURL = userOverrideURL(vendorID: display.vendorID, modelID: display.modelID)
        let targetDir = targetURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            return .success(())
        }

        if geteuid() == 0 {
            do {
                try FileManager.default.removeItem(at: targetURL)
                try? FileManager.default.removeItem(at: targetDir) // succeeds only if empty
                return .success(())
            } catch {
                return .failure(.commandFailed(error.localizedDescription))
            }
        }

        let shell = "rm -f \(shellQuote(targetURL.path)) && (rmdir \(shellQuote(targetDir.path)) 2>/dev/null || true)"
        return await runPrivilegedShell(shell)
    }

    // MARK: - Privileged execution

    private func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runPrivilegedShell(_ command: String) async -> Result<Void, OverrideError> {
        let escaped = appleScriptEscape(command)
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return .failure(.commandFailed("Could not launch administrator prompt: \(error.localizedDescription)"))
            }
            if process.terminationStatus == 0 {
                return .success(())
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if errText.contains("-128") || errText.localizedCaseInsensitiveContains("User canceled") {
                return .failure(.cancelled)
            }
            return .failure(.commandFailed(errText.isEmpty ? "Administrator command failed (status \(process.terminationStatus))." : errText))
        }.value
    }
}
