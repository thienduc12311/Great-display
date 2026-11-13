import Foundation
import CoreGraphics

/// Immutable description of one selectable display mode.
public struct ModeInfo: Identifiable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isHiDPI: Bool
    public let isUsable: Bool
    public let mode: CGDisplayMode
    /// The mode macOS picks by default for this display.
    public var isDefault: Bool = false
    /// The mode that maps one pixel to one panel pixel.
    public var isNative: Bool = false

    /// "16:9", "16:10", … or a decimal ratio for uncommon shapes.
    public var aspectRatio: String {
        ModeInfo.aspectLabel(width: pixelWidth, height: pixelHeight)
    }

    public var resolutionText: String { "\(width) × \(height)" }

    public var refreshText: String {
        refreshRate > 0 ? String(format: refreshRate.rounded() == refreshRate ? "%.0f Hz" : "%.2f Hz", refreshRate) : "—"
    }

    public static func aspectLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let ratio = Double(width) / Double(height)
        let known: [(String, Double)] = [("16:9", 16.0 / 9), ("16:10", 1.6), ("4:3", 4.0 / 3), ("5:4", 1.25),
                                         ("21:9", 64.0 / 27), ("32:9", 32.0 / 9), ("3:2", 1.5), ("1:1", 1),
                                         ("9:16", 9.0 / 16), ("10:16", 0.625), ("3:4", 0.75)]
        if let match = known.first(where: { abs($0.1 - ratio) < 0.012 }) { return match.0 }
        return String(format: "%.2f:1", ratio)
    }

    public var summary: String {
        var text = "\(width) × \(height)"
        if isHiDPI { text += " HiDPI" }
        if refreshRate > 0 { text += String(format: " · %.0f Hz", refreshRate) }
        return text
    }

    public var fullSummary: String {
        "\(width)×\(height) @\(pixelWidth)×\(pixelHeight)" + (isHiDPI ? " HiDPI" : "")
    }

    /// Compares geometry and refresh rate rather than object identity, which is
    /// not stable across enumeration calls.
    public func matches(_ other: ModeInfo?) -> Bool {
        guard let other else { return false }
        return width == other.width &&
            height == other.height &&
            pixelWidth == other.pixelWidth &&
            pixelHeight == other.pixelHeight &&
            Int(refreshRate.rounded()) == Int(other.refreshRate.rounded())
    }
}

/// Everything the UI needs to know about a connected display.
public struct DisplayInfo: Identifiable, Hashable {
    public let id: CGDirectDisplayID
    public var name: String
    public var vendorID: UInt32
    public var modelID: UInt32
    public var serialNumber: UInt32
    public var isBuiltIn: Bool
    public var isVirtual: Bool
    public var isMain: Bool
    public var isMirrored: Bool
    public var isOnline: Bool
    public var isAsleep: Bool
    public var rotation: Double
    public var bounds: CGRect
    public var modes: [ModeInfo]
    public var currentMode: ModeInfo?
    public var hasHardwareBrightness: Bool
    public var hasDDC: Bool

    public var identity: String {
        "\(vendorID)-\(modelID)-\(serialNumber)"
    }

    public var resolutionSummary: String {
        guard let mode = currentMode else { return "No active mode" }
        return mode.summary
    }

    public var scaleSummary: String {
        guard let mode = currentMode, mode.width > 0 else { return "—" }
        let scale = Double(mode.pixelWidth) / Double(mode.width)
        return String(format: "%.1f×", scale)
    }

    public static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.identity == rhs.identity &&
        lhs.isVirtual == rhs.isVirtual &&
        lhs.isMain == rhs.isMain &&
        lhs.isMirrored == rhs.isMirrored &&
        lhs.isAsleep == rhs.isAsleep &&
        ((lhs.currentMode == nil && rhs.currentMode == nil) || (lhs.currentMode?.matches(rhs.currentMode) ?? false)) &&
        lhs.currentMode?.isHiDPI == rhs.currentMode?.isHiDPI &&
        lhs.modes.count == rhs.modes.count &&
        lhs.hasDDC == rhs.hasDDC &&
        lhs.hasHardwareBrightness == rhs.hasHardwareBrightness &&
        lhs.rotation == rhs.rotation &&
        lhs.bounds == rhs.bounds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(isMain)
        // Not the current mode's id: `==` compares modes by geometry, and two
        // equal values must hash alike.
    }
}

/// Gamma-table image adjustments for one display. Neutral values leave the
/// display's own transfer table untouched.
public struct ImageAdjustments: Codable, Equatable {
    /// Exponent applied to the tonal curve. Above 1 darkens mid-tones.
    public var gamma: Double = 1.0
    /// -1 (cool) … 0 (neutral) … 1 (warm).
    public var temperature: Double = 0
    /// 0.5 … 1.5, pivoting around mid-grey.
    public var contrast: Double = 1.0
    public var redGain: Double = 1.0
    public var greenGain: Double = 1.0
    public var blueGain: Double = 1.0
    public var invert: Bool = false
    /// Temporarily bypasses everything above without losing the values.
    public var suspended: Bool = false

    public init() {}

    public static let neutral = ImageAdjustments()

    public var isNeutral: Bool {
        var copy = self
        copy.suspended = false
        return suspended || copy == .neutral
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        redGain = try c.decodeIfPresent(Double.self, forKey: .redGain) ?? 1
        greenGain = try c.decodeIfPresent(Double.self, forKey: .greenGain) ?? 1
        blueGain = try c.decodeIfPresent(Double.self, forKey: .blueGain) ?? 1
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        suspended = try c.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
    }

    /// Per-channel multipliers for the colour temperature setting.
    var temperatureGains: (Double, Double, Double) {
        let t = max(-1, min(1, temperature))
        if t >= 0 { return (1, 1 - 0.18 * t, 1 - 0.5 * t) }
        return (1 + 0.45 * t, 1 + 0.12 * t, 1)
    }

    /// Maps one transfer-table value (0…1) for a channel (0 = red, 1 = green, 2 = blue).
    func transform(_ value: Double, channel: Int) -> Double {
        if suspended { return value }
        var v = max(0, min(1, value))
        if contrast != 1 { v = (v - 0.5) * contrast + 0.5 }
        v = max(0, min(1, v))
        if gamma != 1 { v = pow(v, gamma) }
        let temp = temperatureGains
        switch channel {
        case 0: v *= redGain * temp.0
        case 1: v *= greenGain * temp.1
        default: v *= blueGain * temp.2
        }
        v = max(0, min(1, v))
        return invert ? 1 - v : v
    }
}

/// Common DDC/CI input source values (VCP 0x60).
public struct InputSource: Identifiable, Hashable {
    public let value: Int
    public let name: String
    public let symbol: String
    public var id: Int { value }

    /// MCCS input source names (VCP 0x60), with the USB-C values monitors use in practice.
    public static func named(_ value: Int) -> InputSource {
        let table: [Int: (String, String)] = [
            0x01: ("VGA 1", "cable.connector.horizontal"), 0x02: ("VGA 2", "cable.connector.horizontal"),
            0x03: ("DVI 1", "cable.connector.horizontal"), 0x04: ("DVI 2", "cable.connector.horizontal"),
            0x05: ("Composite 1", "cable.connector.horizontal"), 0x06: ("Composite 2", "cable.connector.horizontal"),
            0x07: ("S-Video 1", "cable.connector.horizontal"), 0x08: ("S-Video 2", "cable.connector.horizontal"),
            0x09: ("Tuner 1", "antenna.radiowaves.left.and.right"), 0x0C: ("Component 1", "cable.connector.horizontal"),
            0x0D: ("Component 2", "cable.connector.horizontal"), 0x0E: ("Component 3", "cable.connector.horizontal"),
            0x0F: ("DisplayPort 1", "rectangle.connected.to.line.below"),
            0x10: ("DisplayPort 2", "rectangle.connected.to.line.below"),
            0x11: ("HDMI 1", "cable.connector.horizontal"), 0x12: ("HDMI 2", "cable.connector.horizontal"),
            0x13: ("HDMI 3", "cable.connector.horizontal"), 0x19: ("USB-C 2 / Thunderbolt", "bolt.horizontal"),
            0x1A: ("USB-C 3", "cable.connector"), 0x1B: ("USB-C", "cable.connector"),
        ]
        let entry = table[value] ?? (String(format: "Input 0x%02X", value), "cable.connector")
        return InputSource(value: value, name: entry.0, symbol: entry.1)
    }

    public static let common: [InputSource] = [
        InputSource(value: 0x0F, name: "DisplayPort 1", symbol: "rectangle.connected.to.line.below"),
        InputSource(value: 0x10, name: "DisplayPort 2", symbol: "rectangle.connected.to.line.below"),
        InputSource(value: 0x11, name: "HDMI 1", symbol: "cable.connector.horizontal"),
        InputSource(value: 0x12, name: "HDMI 2", symbol: "cable.connector.horizontal"),
        InputSource(value: 0x1B, name: "USB-C", symbol: "cable.connector"),
        InputSource(value: 0x19, name: "USB-C 2 / Thunderbolt", symbol: "bolt.horizontal"),
        InputSource(value: 0x03, name: "DVI 1", symbol: "cable.connector.horizontal"),
        InputSource(value: 0x01, name: "VGA", symbol: "cable.connector.horizontal"),
    ]
}

/// MCCS names for the colour preset (VCP 0x14) and picture mode (VCP 0xDC) values.
public enum DDCValueNames {
    public static func colorPreset(_ value: Int) -> String {
        let names: [Int: String] = [0x01: "sRGB", 0x02: "Native", 0x03: "4000 K", 0x04: "5000 K", 0x05: "6500 K",
                                    0x06: "7500 K", 0x07: "8200 K", 0x08: "9300 K", 0x09: "10000 K",
                                    0x0A: "11500 K", 0x0B: "User 1", 0x0C: "User 2", 0x0D: "User 3"]
        return names[value] ?? String(format: "Preset 0x%02X", value)
    }

    public static func pictureMode(_ value: Int) -> String {
        let names: [Int: String] = [0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed", 0x03: "Movie",
                                    0x04: "User", 0x05: "Game", 0x06: "Sports", 0x07: "Professional",
                                    0x08: "Standard (low power)", 0x09: "Standard (lowest power)",
                                    0x0A: "Demonstration", 0xF0: "Dynamic Contrast"]
        return names[value] ?? String(format: "Mode 0x%02X", value)
    }
}
