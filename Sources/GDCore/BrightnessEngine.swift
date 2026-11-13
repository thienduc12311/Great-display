import Foundation
import CoreGraphics

/// Native, DDC and gamma-table brightness control for a display.
///
/// Three layers are supported:
///  1. Native panel brightness (Apple displays) through the DisplayServices client.
///  2. DDC/CI brightness for external displays over the video-interface side channel.
///  3. Gamma-table software dimming for any display, used below the hardware floor
///     or when no hardware path exists.
public final class BrightnessEngine {
    public static let shared = BrightnessEngine()

    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetLinearFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetLinearFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private var canChangeFn: CanChangeFn?
    private var getFn: GetFn?
    private var setFn: SetFn?
    private var getLinearFn: GetLinearFn?
    private var setLinearFn: SetLinearFn?

    private struct GammaTable {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
        var count: UInt32
        var appliedScale: Double = 1.0
        var adjustments: ImageAdjustments = .neutral
        /// Extra multiplier used only while fading across a mode change.
        var transition: Double = 1.0

        var isIdentity: Bool { appliedScale >= 0.9995 && adjustments.isNeutral && transition >= 0.9995 }
    }

    private var gammaTables: [CGDirectDisplayID: GammaTable] = [:]
    private var gammaGenerations: [CGDirectDisplayID: UInt64] = [:]
    private let softwareQueue = DispatchQueue(label: "greatdisplay.brightness.software")

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        guard let handle else { return }
        if let p = dlsym(handle, "DisplayServicesCanChangeBrightness") {
            canChangeFn = unsafeBitCast(p, to: CanChangeFn.self)
        }
        if let p = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(p, to: GetFn.self)
        }
        if let p = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(p, to: SetFn.self)
        }
        if let p = dlsym(handle, "DisplayServicesGetLinearBrightness") {
            getLinearFn = unsafeBitCast(p, to: GetLinearFn.self)
        }
        if let p = dlsym(handle, "DisplayServicesSetLinearBrightness") {
            setLinearFn = unsafeBitCast(p, to: SetLinearFn.self)
        }
    }

    public var hasDisplayServices: Bool {
        getFn != nil && setFn != nil
    }

    // MARK: Capability

    public func hasNativeBrightness(_ id: CGDirectDisplayID) -> Bool {
        guard let canChangeFn else { return false }
        return canChangeFn(id) != 0
    }

    public func hasHardwareBrightness(_ id: CGDirectDisplayID) -> Bool {
        hasNativeBrightness(id) || DDCController.shared.hasService(for: id)
    }

    // MARK: Reading / writing hardware brightness

    public func hardwareBrightness(_ id: CGDirectDisplayID) -> Float? {
        if hasNativeBrightness(id), let getFn {
            var value: Float = 0
            if getFn(id, &value) == 0 {
                return max(0, min(1, value))
            }
        }
        if let ddc = DDCController.shared.value(.brightness, display: id) {
            // Some monitors report a current value above their maximum.
            return Float(max(0, min(1, ddc)))
        }
        return nil
    }

    @discardableResult
    public func setHardwareBrightness(_ value: Float, display id: CGDirectDisplayID) -> Bool {
        let clamped = max(0, min(1, value))
        if hasNativeBrightness(id), let setFn {
            if setFn(id, clamped) == 0 {
                return true
            }
        }
        return DDCController.shared.setValue(Double(clamped), vcp: .brightness, display: id)
    }

    /// Linear (nits-relative) brightness where the platform exposes it.
    public func linearBrightness(_ id: CGDirectDisplayID) -> Float? {
        guard let getLinearFn else { return nil }
        var value: Float = 0
        guard getLinearFn(id, &value) == 0 else { return nil }
        return value
    }

    @discardableResult
    public func setLinearBrightness(_ value: Float, display id: CGDirectDisplayID) -> Bool {
        guard let setLinearFn else { return false }
        return setLinearFn(id, max(0, min(1, value))) == 0
    }

    // MARK: Combined brightness

    /// Applies a unified brightness level. Hardware is driven as far as it can go,
    /// and the remainder is applied with gamma-table dimming.
    public func setCombinedBrightness(_ level: Double, display id: CGDirectDisplayID) {
        let level = max(0, min(1, level))
        let hardwareFloor = 0.02
        if hasHardwareBrightness(id) {
            let hardware = max(hardwareFloor, level)
            _ = setHardwareBrightness(Float(hardware), display: id)
            let software = level < hardwareFloor ? level / hardwareFloor : 1.0
            applySoftwareDimming(software, display: id)
        } else {
            applySoftwareDimming(level, display: id)
        }
    }

    // MARK: Software dimming and image adjustments

    /// Multiplies the display gamma table. A level of 1.0 restores the original table.
    public func applySoftwareDimming(_ level: Double, display id: CGDirectDisplayID) {
        let level = max(0, min(1, level))
        softwareQueue.async { [weak self] in
            guard let self else { return }
            // Nothing to undo: do not capture a baseline just to leave it as is.
            if level >= 0.9995 && self.gammaTables[id] == nil { return }
            guard var table = self.capturedTable(id) else { return }
            if abs(table.appliedScale - level) < 0.0005 { return }
            table.appliedScale = level
            self.gammaTables[id] = table
            self.schedulePush(table, display: id)
        }
    }

    /// Applies colour/tone adjustments on top of the software dimming level.
    public func setImageAdjustments(_ adjustments: ImageAdjustments, display id: CGDirectDisplayID) {
        softwareQueue.async { [weak self] in
            guard let self else { return }
            // Nothing to undo: do not capture a baseline just to leave it as is.
            if adjustments.isNeutral && self.gammaTables[id] == nil { return }
            guard var table = self.capturedTable(id) else { return }
            if table.adjustments == adjustments { return }
            table.adjustments = adjustments
            self.gammaTables[id] = table
            self.schedulePush(table, display: id)
        }
    }

    public func imageAdjustments(_ id: CGDirectDisplayID) -> ImageAdjustments {
        softwareQueue.sync { gammaTables[id]?.adjustments ?? .neutral }
    }

    public func currentSoftwareDimming(_ id: CGDirectDisplayID) -> Double {
        softwareQueue.sync { gammaTables[id]?.appliedScale ?? 1.0 }
    }

    public func resetSoftwareDimming(_ id: CGDirectDisplayID) {
        applySoftwareDimming(1.0, display: id)
    }

    /// Restores every captured transfer table (dimming and adjustments).
    public func resetAllSoftwareDimming() {
        let tables = softwareQueue.sync { () -> [(CGDirectDisplayID, GammaTable)] in
            let snapshot = gammaTables.map { ($0.key, $0.value) }
            for key in gammaTables.keys {
                gammaTables[key]?.appliedScale = 1
                gammaTables[key]?.adjustments = .neutral
                gammaTables[key]?.transition = 1
            }
            return snapshot
        }
        for (id, table) in tables {
            var neutral = table
            neutral.appliedScale = 1
            neutral.adjustments = .neutral
            neutral.transition = 1
            pushGamma(neutral, display: id)
        }
    }

    /// Removes a departed monitor's baseline and cancels queued writes. Never
    /// restore that baseline onto a different monitor that inherits its ID.
    public func forgetDisplay(_ id: CGDirectDisplayID) {
        softwareQueue.sync {
            gammaTables.removeValue(forKey: id)
            gammaGenerations[id, default: 0] &+= 1
        }
    }

    /// Forgets the captured table so the next change re-reads it (after a
    /// display reconnects or the colour profile changes).
    public func invalidateGamma(_ id: CGDirectDisplayID) {
        softwareQueue.async { [weak self] in
            guard let self, let table = self.gammaTables[id] else { return }
            if table.isIdentity {
                self.gammaTables.removeValue(forKey: id)
            }
        }
    }

    // MARK: Mode-change transitions

    /// Re-pushes the current table. macOS restores the colour profile's table
    /// after a mode change, which would otherwise drop dimming and adjustments.
    public func reapply(_ id: CGDirectDisplayID) {
        softwareQueue.async { [weak self] in
            guard let self, let table = self.gammaTables[id], !table.isIdentity else { return }
            self.schedulePush(table, display: id)
        }
    }

    /// Sets the transition multiplier and pushes it immediately (main thread).
    public func setTransition(_ value: Double, display id: CGDirectDisplayID) {
        let table: GammaTable? = softwareQueue.sync {
            guard var table = capturedTable(id) else { return nil }
            table.transition = max(0, min(1, value))
            gammaTables[id] = table
            return table
        }
        if let table { pushGamma(table, display: id) }
    }

    /// Eases the transition multiplier to `target` over `duration` seconds on
    /// one display only.
    @MainActor
    public func animateTransition(to target: Double, duration: TimeInterval, display id: CGDirectDisplayID) async {
        let generation = softwareQueue.sync { gammaGenerations[id, default: 0] }
        let start = softwareQueue.sync { gammaTables[id]?.transition ?? 1 }
        let duration = duration.isFinite ? max(0, min(10, duration)) : 0
        let frames = max(1, Int(duration * 60))
        for frame in 1...frames {
            guard softwareQueue.sync(execute: { gammaGenerations[id, default: 0] == generation }) else { return }
            let t = Double(frame) / Double(frames)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            setTransition(start + (target - start) * eased, display: id)
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(frames) * 1_000_000_000))
        }
    }

    private func capturedTable(_ id: CGDirectDisplayID) -> GammaTable? {
        if let table = gammaTables[id] { return table }
        guard let captured = captureGamma(id) else { return nil }
        gammaTables[id] = captured
        return captured
    }

    private func schedulePush(_ table: GammaTable, display id: CGDirectDisplayID) {
        let generation = gammaGenerations[id, default: 0]
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.softwareQueue.sync(execute: { self.gammaGenerations[id, default: 0] == generation }) else { return }
            self.pushGamma(table, display: id)
        }
    }

    private func captureGamma(_ id: CGDirectDisplayID) -> GammaTable? {
        let capacity: UInt32 = 1024
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count)
        guard result == .success, count > 0 else { return nil }
        return GammaTable(red: Array(red.prefix(Int(count))),
                          green: Array(green.prefix(Int(count))),
                          blue: Array(blue.prefix(Int(count))),
                          count: count)
    }

    private func pushGamma(_ table: GammaTable, display id: CGDirectDisplayID) {
        let count = table.count
        guard count > 0 else { return }
        let level = table.appliedScale * table.transition
        let adjustments = table.adjustments
        let neutral = adjustments.isNeutral
        var red = [CGGammaValue](repeating: 0, count: Int(count))
        var green = [CGGammaValue](repeating: 0, count: Int(count))
        var blue = [CGGammaValue](repeating: 0, count: Int(count))
        for index in 0..<Int(count) {
            if neutral {
                red[index] = table.red[index] * CGGammaValue(level)
                green[index] = table.green[index] * CGGammaValue(level)
                blue[index] = table.blue[index] * CGGammaValue(level)
            } else {
                red[index] = CGGammaValue(adjustments.transform(Double(table.red[index]), channel: 0) * level)
                green[index] = CGGammaValue(adjustments.transform(Double(table.green[index]), channel: 1) * level)
                blue[index] = CGGammaValue(adjustments.transform(Double(table.blue[index]), channel: 2) * level)
            }
        }
        CGSetDisplayTransferByTable(id, count, &red, &green, &blue)
    }
}
