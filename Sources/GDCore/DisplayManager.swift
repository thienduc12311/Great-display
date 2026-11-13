import Foundation
import AppKit
import CoreGraphics
import IOKit
import GDCBridge
import Combine

/// Enumerates displays, exposes their modes and applies display-configuration
/// changes through CoreGraphics display configuration transactions.
@MainActor
public final class DisplayManager: ObservableObject {
    public static let shared = DisplayManager()

    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public private(set) var lastError: String?

    private var refreshWorkItem: DispatchWorkItem?
    private var callbackInstalled = false

    public init() {}

    // MARK: Lifecycle

    private static let reconfigurationCallback: CGDisplayReconfigurationCallBack = { id, flags, userInfo in
        guard let userInfo else { return }
        // The "begin" notification arrives before anything has changed.
        if flags.contains(.beginConfigurationFlag) { return }
        let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        let modeChanged = flags.contains(.setModeFlag)
        Task { @MainActor in
            if modeChanged { manager.modeDidChange.send(id) }
            manager.scheduleRefresh()
        }
    }

    /// Fires after a display changed mode (from this app or anywhere else).
    /// macOS resets the colour table on a mode change, so listeners re-apply
    /// software dimming and image adjustments.
    public let modeDidChange = PassthroughSubject<CGDirectDisplayID, Never>()

    public func start() {
        guard !callbackInstalled else { return }
        callbackInstalled = true
        CGDisplayRegisterReconfigurationCallback(DisplayManager.reconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        refresh()
    }

    public func stop() {
        guard callbackInstalled else { return }
        CGDisplayRemoveReconfigurationCallback(DisplayManager.reconfigurationCallback,
                                                   Unmanaged.passUnretained(self).toOpaque())
        callbackInstalled = false
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // MARK: Enumeration

    public func refresh() {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            displays = []
            return
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return }

        let screens = NSScreen.screens
        var result: [DisplayInfo] = []

        for id in ids.prefix(Int(count)) {
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let name = screen?.localizedName ?? DisplayManager.fallbackName(for: id)
            let vendor = CGDisplayVendorNumber(id)
            let model = CGDisplayModelNumber(id)
            let serial = CGDisplaySerialNumber(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let isVirtual = vendor == 0x5678 || DisplayManager.virtualDisplayIDs.contains(id)

            let current = CGDisplayCopyDisplayMode(id)
            var modes: [ModeInfo] = []
            if let all = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] {
                var seen = Set<String>()
                for (index, mode) in all.enumerated() {
                    // Hide modes that the display cannot drive in the desktop GUI.
                    if mode.width <= 0 || mode.height <= 0 || mode.pixelWidth <= 0 { continue }
                    let key = "\(mode.width)x\(mode.height)@\(mode.pixelWidth)x\(mode.pixelHeight)-\(Int(mode.refreshRate.rounded()))"
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    let flags = mode.ioFlags
                    modes.append(ModeInfo(id: index,
                                          width: mode.width,
                                          height: mode.height,
                                          pixelWidth: mode.pixelWidth,
                                          pixelHeight: mode.pixelHeight,
                                          refreshRate: mode.refreshRate,
                                          isHiDPI: mode.pixelWidth > mode.width,
                                          isUsable: mode.isUsableForDesktopGUI(),
                                          mode: mode,
                                          isDefault: flags & 0x0000_0004 != 0,
                                          isNative: flags & 0x0200_0000 != 0))
                }
                modes.sort {
                    if $0.width != $1.width { return $0.width < $1.width }
                    if $0.height != $1.height { return $0.height < $1.height }
                    if $0.isHiDPI != $1.isHiDPI { return !$0.isHiDPI }
                    return $0.refreshRate < $1.refreshRate
                }
            }

            let currentInfo = current.flatMap { mode in
                modes.first { $0.mode === mode } ??
                modes.first { $0.width == mode.width && $0.height == mode.height &&
                    $0.pixelWidth == mode.pixelWidth && Int($0.refreshRate.rounded()) == Int(mode.refreshRate.rounded()) } ?? ModeInfo(id: -1,
                                                             width: mode.width,
                                                             height: mode.height,
                                                             pixelWidth: mode.pixelWidth,
                                                             pixelHeight: mode.pixelHeight,
                                                             refreshRate: mode.refreshRate,
                                                             isHiDPI: mode.pixelWidth > mode.width,
                                                             isUsable: true,
                                                             mode: mode)
            }

            result.append(DisplayInfo(id: id,
                                      name: name,
                                      vendorID: vendor,
                                      modelID: model,
                                      serialNumber: serial,
                                      isBuiltIn: builtIn,
                                      isVirtual: isVirtual,
                                      isMain: CGDisplayIsMain(id) != 0,
                                      isMirrored: CGDisplayIsInMirrorSet(id) != 0,
                                      isOnline: CGDisplayIsOnline(id) != 0,
                                      isAsleep: CGDisplayIsAsleep(id) != 0,
                                      rotation: Double(CGDisplayRotation(id)),
                                      bounds: CGDisplayBounds(id),
                                      modes: modes,
                                      currentMode: currentInfo,
                                      hasHardwareBrightness: BrightnessEngine.shared.hasNativeBrightness(id),
                                      hasDDC: DDCController.shared.hasService(for: id)))
        }

        // Publishing an identical list would re-render every observer; display
        // reconfiguration callbacks arrive several times per change.
        if result != displays {
            displays = result
        }

        // A display that came back (reconnected elsewhere or by the system)
        // is no longer listed as disconnected.
        let online = Set(result.map(\.id))
        if disconnected.contains(where: { online.contains($0.id) }) {
            disconnected.removeAll { online.contains($0.id) }
        }
    }

    // MARK: Connection

    /// Displays this app disconnected during the current login session.
    @Published public var disconnected: [DisconnectedDisplay] = []

    public var canDisconnect: Bool { gd_display_enable_available() != 0 }

    /// Removes a display from the desktop layout without cutting its power.
    /// Refuses to disconnect the last physical display.
    @discardableResult
    public func disconnect(_ id: CGDirectDisplayID) -> Bool {
        guard let display = display(id: id) else { return false }
        if display.isVirtual {
            lastError = "Use the virtual screen controls to disconnect a virtual screen."
            return false
        }
        let remainingPhysical = displays.filter { !$0.isVirtual && $0.id != id }
        guard !remainingPhysical.isEmpty else {
            lastError = "\(display.name) is the only physical display and cannot be disconnected."
            return false
        }
        let result = gd_display_set_enabled(id, 0)
        guard result == 0 else {
            lastError = "Could not disconnect \(display.name) (\(result))."
            return false
        }
        if !disconnected.contains(where: { $0.id == id }) {
            disconnected.append(DisconnectedDisplay(id: id, name: display.name, identity: display.identity))
        }
        refresh()
        scheduleRefresh()
        return true
    }

    @discardableResult
    public func reconnect(_ id: CGDirectDisplayID) -> Bool {
        let result = gd_display_set_enabled(id, 1)
        guard result == 0 else {
            lastError = "Could not reconnect display \(id) (\(result))."
            return false
        }
        disconnected.removeAll { $0.id == id }
        scheduleRefresh()
        return true
    }

    public func reconnectAll() {
        for entry in disconnected { _ = reconnect(entry.id) }
    }

    // MARK: Rotation and HDR

    public func canRotate(_ id: CGDirectDisplayID) -> Bool {
        gd_display_can_rotate(id) == 1
    }

    @discardableResult
    public func setRotation(_ degrees: Int, for id: CGDirectDisplayID) -> Bool {
        guard [0, 90, 180, 270].contains(degrees) else {
            lastError = "Rotation must be 0, 90, 180 or 270 degrees."
            return false
        }
        let result = gd_display_set_rotation(id, Int32(degrees))
        guard result == 0 else {
            lastError = result == -2 ? "This display cannot be rotated." : "Rotation is unavailable on this system."
            return false
        }
        scheduleRefresh()
        return true
    }

    public func hasHDR(_ id: CGDirectDisplayID) -> Bool {
        gd_display_has_hdr(id) == 1
    }

    public func isHDREnabled(_ id: CGDirectDisplayID) -> Bool {
        gd_display_hdr_enabled(id) == 1
    }

    @discardableResult
    public func setHDR(_ enabled: Bool, for id: CGDirectDisplayID) -> Bool {
        guard gd_display_set_hdr_enabled(id, enabled ? 1 : 0) == 0 else {
            lastError = "HDR is not available on this display."
            return false
        }
        scheduleRefresh()
        return true
    }

    // MARK: Mode helpers

    /// Refresh rates available for the current resolution and density.
    public func refreshRates(for display: DisplayInfo) -> [ModeInfo] {
        guard let current = display.currentMode else { return [] }
        var seen = Set<Int>()
        return display.modes
            .filter { $0.width == current.width && $0.height == current.height &&
                $0.pixelWidth == current.pixelWidth && $0.pixelHeight == current.pixelHeight }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert(Int(($0.refreshRate * 100).rounded())).inserted }
    }

    /// Desktop sizes for the resolution slider: same density and aspect ratio as
    /// the current mode, one entry per size, smallest first. Always includes the
    /// current mode.
    public func sliderModes(for display: DisplayInfo, hideLowResolutions: Bool = true) -> [ModeInfo] {
        guard let current = display.currentMode else { return [] }
        let aspect = current.aspectRatio
        let reference = current.refreshRate
        var bySize: [String: ModeInfo] = [:]
        for mode in display.modes where mode.isHiDPI == current.isHiDPI && mode.aspectRatio == aspect && mode.isUsable {
            if hideLowResolutions && mode.height < 720 && !mode.matches(current) { continue }
            let key = "\(mode.width)x\(mode.height)"
            if let existing = bySize[key] {
                if abs(mode.refreshRate - reference) < abs(existing.refreshRate - reference) { bySize[key] = mode }
            } else {
                bySize[key] = mode
            }
        }
        bySize["\(current.width)x\(current.height)"] = current
        return bySize.values.sorted { $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width }
    }

    // MARK: Arrangement

    public enum Placement: String, CaseIterable, Identifiable {
        case left = "Left of Main Display"
        case right = "Right of Main Display"
        case above = "Above Main Display"
        case below = "Below Main Display"
        public var id: String { rawValue }
        public var symbol: String {
            switch self {
            case .left: return "arrow.left.square"
            case .right: return "arrow.right.square"
            case .above: return "arrow.up.square"
            case .below: return "arrow.down.square"
            }
        }
    }

    /// Places a display edge-to-edge next to the main display, centred on it.
    @discardableResult
    public func place(_ id: CGDirectDisplayID, _ placement: Placement) -> Bool {
        guard let display = display(id: id), let main = displays.first(where: { $0.isMain }), main.id != id else {
            return false
        }
        let m = main.bounds
        let b = display.bounds
        let point: CGPoint
        switch placement {
        case .left: point = CGPoint(x: m.minX - b.width, y: m.midY - b.height / 2)
        case .right: point = CGPoint(x: m.maxX, y: m.midY - b.height / 2)
        case .above: point = CGPoint(x: m.midX - b.width / 2, y: m.minY - b.height)
        case .below: point = CGPoint(x: m.midX - b.width / 2, y: m.maxY)
        }
        return move(id, to: point)
    }

    public static var virtualDisplayIDs: Set<CGDirectDisplayID> = []

    private static func fallbackName(for id: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
        let vendor = CGDisplayVendorNumber(id)
        let model = CGDisplayModelNumber(id)
        return String(format: "Display %u (%04X:%04X)", id, vendor, model)
    }

    public func display(id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    // MARK: Configuration

    @discardableResult
    private func perform(_ body: (CGDisplayConfigRef) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            lastError = "Could not begin a display configuration."
            return false
        }
        let result = body(config)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            lastError = "Display configuration failed (\(result.rawValue))."
            return false
        }
        // Completing consumes the configuration whether or not it succeeds, so
        // it must not be cancelled afterwards.
        let completed = CGCompleteDisplayConfiguration(config, .forSession)
        guard completed == .success else {
            lastError = "Display configuration failed (\(completed.rawValue))."
            return false
        }
        refresh()
        return true
    }

    @discardableResult
    public func setMode(_ mode: CGDisplayMode, for id: CGDirectDisplayID) -> Bool {
        perform { CGConfigureDisplayWithDisplayMode($0, id, mode, nil) }
    }

    /// Applies a mode without blocking the main thread. The window server can
    /// take a second or more to finish a mode change; running the transaction
    /// on a background queue keeps the menu responsive and animating.
    ///
    /// Callers fade only the affected display through its colour table.
    public func applyMode(_ mode: CGDisplayMode, for id: CGDirectDisplayID) async -> Bool {
        nonisolated(unsafe) let mode = mode
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var config: CGDisplayConfigRef?
                guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                    continuation.resume(returning: -1)
                    return
                }
                // No CGConfigureDisplayFadeEffect: with any explicit fade the
                // transaction fails with kCGErrorNotImplemented (1006) on
                // macOS 27. The caller fades the affected display itself.
                let configured = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
                guard configured == .success else {
                    CGCancelDisplayConfiguration(config)
                    continuation.resume(returning: configured.rawValue)
                    return
                }
                continuation.resume(returning: CGCompleteDisplayConfiguration(config, .forSession).rawValue)
            }
        }
        guard status == CGError.success.rawValue else {
            lastError = "Display configuration failed (\(status))."
            refresh()
            return false
        }
        refresh()
        return true
    }

    /// Applies a logical resolution at the requested density.
    ///
    /// The density is strict: asking for HiDPI never silently falls back to a
    /// low-resolution mode (and the reverse), because that would look like a
    /// successful change while the pixels are actually different.
    ///
    /// Modes the display reports as usable for the desktop are preferred over
    /// unusable ones of the same size; `usableOnly` refuses the latter outright
    /// (used when re-applying a saved configuration unattended).
    @discardableResult
    public func setResolution(width: Int, height: Int, hiDPI: Bool, refreshRate: Double? = nil,
                              usableOnly: Bool = false, for id: CGDirectDisplayID) -> Bool {
        guard let display = display(id: id) else {
            lastError = "Display \(id) is not connected."
            return false
        }
        let matching = display.modes.filter {
            $0.width == width && $0.height == height && $0.isHiDPI == hiDPI
        }
        let usable = matching.filter(\.isUsable)
        let candidates = usable.isEmpty && !usableOnly ? matching : usable
        guard !candidates.isEmpty else {
            lastError = "No \(hiDPI ? "HiDPI" : "low resolution") mode for \(width) × \(height) on \(display.name)."
            return false
        }
        // Prefer the refresh rate the display is currently running at, otherwise
        // the highest available one.
        let mode: ModeInfo
        if let reference = refreshRate ?? display.currentMode?.refreshRate {
            mode = candidates.min {
                abs($0.refreshRate - reference) < abs($1.refreshRate - reference)
            } ?? candidates[0]
        } else {
            mode = candidates.max { $0.refreshRate < $1.refreshRate } ?? candidates[0]
        }
        return setMode(mode.mode, for: id)
    }

    /// Turns HiDPI rendering on or off for the current logical resolution.
    @discardableResult
    public func toggleHiDPI(for id: CGDirectDisplayID) -> Bool {
        guard let display = display(id: id), let current = display.currentMode else { return false }
        let wanted = !current.isHiDPI
        let candidates = display.modes.filter { $0.width == current.width && $0.height == current.height && $0.isHiDPI == wanted }
        guard let mode = candidates.first(where: { Int($0.refreshRate.rounded()) == Int(current.refreshRate.rounded()) }) ?? candidates.first else {
            lastError = "This display has no \(wanted ? "HiDPI" : "low resolution") variant for the current resolution."
            return false
        }
        return setMode(mode.mode, for: id)
    }

    /// Shows the content of `source` on `target` (the target becomes a mirror
    /// of the source). This is the direction needed to put a virtual screen onto
    /// a physical display.
    ///
    /// The target adopts the source's timing, so its mode is captured first and
    /// restored when the mirror is removed.
    @discardableResult
    public func setMirror(source: CGDirectDisplayID, on target: CGDirectDisplayID?) -> Bool {
        if let target {
            guard target != source else { return false }
            // Moving the mirror to another display: release the previous target
            // first, or it would stay in the mirror set with nothing tracking it.
            if let previous = mirrorTargets[source], previous != target {
                guard setMirror(source: source, on: nil) else { return false }
            }
            if mirrorTargets[source] != target, let mode = CGDisplayCopyDisplayMode(target) {
                preMirrorModes[target] = mode
            }
            let ok = perform { CGConfigureDisplayMirrorOfDisplay($0, target, source) }
            if ok { mirrorTargets[source] = target }
            return ok
        }

        // The target this process set up, else whatever the window server
        // reports: a mirror started by an earlier launch or by the command line
        // is not in `mirrorTargets` but must still be removable.
        var targets = mirrorTargets[source].map { [$0] } ?? liveMirrorTargets(of: source)
        // A target that was unplugged meanwhile has nothing left to undo.
        targets.removeAll { CGDisplayIsOnline($0) == 0 }
        guard !targets.isEmpty else {
            mirrorTargets.removeValue(forKey: source)
            return true
        }
        let ok = perform { config in
            for target in targets {
                let error = CGConfigureDisplayMirrorOfDisplay(config, target, kCGNullDirectDisplay)
                if error != .success { return error }
            }
            return .success
        }
        guard ok else { return false }
        mirrorTargets.removeValue(forKey: source)
        for target in targets {
            if let saved = preMirrorModes.removeValue(forKey: target) {
                _ = setMode(saved, for: target)
            }
        }
        return true
    }

    /// Online displays that currently show `source`'s content, according to
    /// the window server (independent of which process started the mirror).
    public func liveMirrorTargets(of source: CGDirectDisplayID) -> [CGDirectDisplayID] {
        displays.map(\.id).filter { $0 != source && CGDisplayMirrorsDisplay($0) == source }
    }

    public func mirrorTarget(for source: CGDirectDisplayID) -> CGDirectDisplayID? {
        mirrorTargets[source] ?? liveMirrorTargets(of: source).first
    }

    /// Used when a mirror source disappears without an explicit un-mirror.
    public func releaseMirrors(sourcing source: CGDirectDisplayID) {
        if mirrorTargets[source] != nil {
            _ = setMirror(source: source, on: nil)
        }
    }

    private var mirrorTargets: [CGDirectDisplayID: CGDirectDisplayID] = [:]
    private var preMirrorModes: [CGDirectDisplayID: CGDisplayMode] = [:]

    @discardableResult
    public func setMain(_ id: CGDirectDisplayID) -> Bool {
        // The display at the global origin owns the menu bar.
        let display = self.display(id: id)
        let dx = display.map { -$0.bounds.origin.x } ?? 0
        let dy = display.map { -$0.bounds.origin.y } ?? 0
        return perform { config in
            var error: CGError = .success
            for other in self.displays where other.id != id {
                let point = CGPoint(x: other.bounds.origin.x + dx, y: other.bounds.origin.y + dy)
                error = CGConfigureDisplayOrigin(config, other.id, Int32(point.x.rounded()), Int32(point.y.rounded()))
                if error != .success { return error }
            }
            return CGConfigureDisplayOrigin(config, id, 0, 0)
        }
    }

    @discardableResult
    public func move(_ id: CGDirectDisplayID, to point: CGPoint) -> Bool {
        // The origin can come from a settings file: converting a non-finite or
        // out-of-range value to Int32 would trap.
        let limit: CGFloat = 1_000_000
        guard point.x.isFinite, point.y.isFinite, abs(point.x) < limit, abs(point.y) < limit else {
            lastError = "Display position is out of range."
            return false
        }
        return perform { CGConfigureDisplayOrigin($0, id, Int32(point.x.rounded()), Int32(point.y.rounded())) }
    }

    /// Rotates the display a further 90° clockwise.
    @discardableResult
    public func rotate(_ id: CGDirectDisplayID) -> Bool {
        let current = Int(gd_display_rotation(id))
        return setRotation((max(0, current) + 90) % 360, for: id)
    }

    /// Re-applies a saved configuration to the display `id`. Returns true when
    /// everything applied.
    ///
    /// The caller matches the configuration to a display by identity; the
    /// display ID saved inside it is not used, because macOS can hand a monitor
    /// a different ID after a reboot or when it moves to another port.
    public func restore(configuration: DisplayConfiguration, to id: CGDirectDisplayID) -> Bool {
        guard let display = display(id: id) else { return false }
        var ok = true
        if let width = configuration.logicalWidth, let height = configuration.logicalHeight {
            let hiDPI = configuration.hiDPI ?? false
            let current = display.currentMode
            let alreadyThere = current.map { $0.width == width && $0.height == height && $0.isHiDPI == hiDPI } ?? false
            // Keep the refresh rate: the saved one, else the one running now.
            // (Picking the first match used to drop 60 Hz panels to 30 Hz.)
            if !alreadyThere {
                // Unattended: never re-apply a mode the display cannot show.
                ok = setResolution(width: width, height: height, hiDPI: hiDPI,
                                   refreshRate: configuration.refreshRate ?? current?.refreshRate,
                                   usableOnly: true, for: id) && ok
            }
        }
        if let origin = configuration.origin {
            ok = move(id, to: origin) && ok
        }
        if configuration.isMain {
            ok = setMain(id) && ok
        }
        return ok
    }
}

public struct DisplayConfiguration: Codable, Equatable {
    public var displayID: CGDirectDisplayID
    public var identity: String
    public var logicalWidth: Int?
    public var logicalHeight: Int?
    public var hiDPI: Bool?
    public var refreshRate: Double?
    public var origin: CGPoint?
    public var isMain: Bool = false
    public var hardwareBrightness: Float?
    public var softwareDimming: Double?
    public var contrast: Float?

    public init(displayID: CGDirectDisplayID, identity: String) {
        self.displayID = displayID
        self.identity = identity
    }
}
