import Foundation
import AppKit
import CoreGraphics
import Combine
import GDCBridge

/// UI-facing controller that combines the display inventory with brightness,
/// contrast and volume state.
@MainActor
public final class DisplayController: ObservableObject {
    public static let shared = DisplayController()

    @Published public private(set) var displays: [DisplayInfo] = []
    @Published public private(set) var brightness: [CGDirectDisplayID: Double] = [:]
    @Published public private(set) var dimming: [CGDirectDisplayID: Double] = [:]
    @Published public private(set) var contrast: [CGDirectDisplayID: Double] = [:]
    @Published public private(set) var volume: [CGDirectDisplayID: Double] = [:]
    @Published public private(set) var mute: [CGDirectDisplayID: Bool] = [:]
    @Published public private(set) var adjustments: [CGDirectDisplayID: ImageAdjustments] = [:]
    @Published public private(set) var inputSource: [CGDirectDisplayID: Int] = [:]
    @Published public private(set) var canRotate: Set<CGDirectDisplayID> = []
    @Published public private(set) var hdrCapable: Set<CGDirectDisplayID> = []
    @Published public private(set) var hdrEnabled: Set<CGDirectDisplayID> = []
    @Published public private(set) var disconnected: [DisconnectedDisplay] = []

    private var cancellables: Set<AnyCancellable> = []
    private let manager = DisplayManager.shared
    private let engine = BrightnessEngine.shared
    private let ddc = DDCController.shared
    private var rememberedDimming: [String: Double] = [:]
    private var displayGenerations: [CGDirectDisplayID: UInt64] = [:]

    private init() {
        // DisplayManager publishes on the main actor; delivering synchronously
        // (no extra run-loop hop) keeps the menu and the manager in step, so a
        // finished mode change never shows the old mode for a frame.
        manager.$displays
            .sink { [weak self] displays in
                guard let self else { return }
                let previous = self.displays
                self.displays = displays
                self.displaysDidChange(from: previous, to: displays)
                for display in displays where !self.modeInFlight.contains(display.id) {
                    if let pending = self.pendingMode[display.id], let current = display.currentMode,
                       current.matches(pending), current.isHiDPI == pending.isHiDPI {
                        self.pendingMode.removeValue(forKey: display.id)
                    }
                }
                self.refreshValues(for: displays)
                self.rememberNames(of: displays)
            }
            .store(in: &cancellables)

        manager.modeDidChange
            .sink { [weak self] id in
                guard let self, !self.modeInFlight.contains(id) else { return }
                // Changed elsewhere (System Settings, another app): restore our
                // colour table once macOS has reset it.
                for delay in [0.15, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.engine.reapply(id) }
                }
            }
            .store(in: &cancellables)

        manager.$disconnected
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                self?.disconnected = list
                SettingsStore.shared.state.disconnectedDisplays = list
            }
            .store(in: &cancellables)

        KeyboardController.shared.onBrightnessStep = { [weak self] direction in
            Task { @MainActor in
                guard let self else { return }
                let step = SettingsStore.shared.state.general.brightnessStep
                self.adjustAllBrightness(by: direction * step)
            }
        }

        // macOS can reload the profile's colour table while a display sleeps,
        // without the mode-change flag that normally triggers a re-apply.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.screensDidWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for display in self.displays { self.engine.reapply(display.id) }
            }
            .store(in: &cancellables)
    }

    /// Keeps per-display state in step with displays coming and going.
    private func displaysDidChange(from previous: [DisplayInfo], to current: [DisplayInfo]) {
        let oldIdentities = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0.identity) })
        let newIdentities = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.identity) })
        for display in previous where newIdentities[display.id] != display.identity {
            let id = display.id
            displayGenerations[id, default: 0] &+= 1
            rememberedDimming[display.identity] = engine.currentSoftwareDimming(id)
            // A display ID can be handed to a different monitor later: values
            // read from this one must not be shown for the next.
            brightness.removeValue(forKey: id)
            contrast.removeValue(forKey: id)
            volume.removeValue(forKey: id)
            mute.removeValue(forKey: id)
            inputSource.removeValue(forKey: id)
            adjustments.removeValue(forKey: id)
            dimming.removeValue(forKey: id)
            loadedDisplays.remove(id)
            loadedWithDDC.removeValue(forKey: id)
            pendingMode.removeValue(forKey: id)
            queuedMode.removeValue(forKey: id)
            modeInFlight.remove(id)
            ddcInfo.removeValue(forKey: id)
            lastUserWrite.removeValue(forKey: id)
            engine.forgetDisplay(id)
        }
        for display in current where oldIdentities[display.id] != display.identity {
            // Preserve session dimming by monitor identity, but capture a fresh
            // colour-profile baseline when that monitor returns.
            if let software = rememberedDimming[display.identity] {
                engine.applySoftwareDimming(software, display: display.id)
            }
        }
    }

    /// `autoStartVirtualScreens` is off for command line diagnostics, which
    /// must not connect the user's saved virtual screens as a side effect.
    public func start(autoStartVirtualScreens: Bool = true) {
        // Displays disconnected earlier in this login session stay disconnected
        // after a relaunch; remember them so they can be reconnected.
        let online = Set(manager.displays.map(\.id))
        manager.disconnected = SettingsStore.shared.state.disconnectedDisplays.filter { !online.contains($0.id) }
        manager.start()
        if autoStartVirtualScreens {
            VirtualScreenManager.shared.startAutoStartScreens()
        } else {
            VirtualScreenManager.shared.automaticConnectionEnabled = false
        }
    }

    /// True when a brightness key press would change at least one display.
    /// The key tap passes the keys on to macOS when it would not.
    public var hasBrightnessKeyTargets: Bool {
        keyboardDisplays.contains { !$0.isMirrored }
    }

    // MARK: Value loading

    /// Displays whose hardware values were read since they appeared.
    private var loadedDisplays: Set<CGDirectDisplayID> = []
    private var loadedWithDDC: [CGDirectDisplayID: Bool] = [:]
    private var lastCapabilityIDs: [CGDirectDisplayID] = []

    /// Loads values for displays that just appeared. Hardware (DDC) reads are
    /// slow and arrive late, so they are not repeated on every reconfiguration;
    /// `redetect()` forces a full reload.
    private func refreshValues(for displays: [DisplayInfo], force: Bool = false) {
        let ids = displays.map(\.id)
        loadedDisplays.formIntersection(ids)
        for display in displays {
            let changed = engine.currentSoftwareDimming(display.id)
            if dimming[display.id] != changed { dimming[display.id] = changed }
            // Reload when new, forced, or when the DDC service match changed.
            guard force || !loadedDisplays.contains(display.id) || loadedWithDDC[display.id] != display.hasDDC else { continue }
            loadedDisplays.insert(display.id)
            loadedWithDDC[display.id] = display.hasDDC
            if engine.hasNativeBrightness(display.id) {
                if let value = engine.hardwareBrightness(display.id) {
                    update(&brightness, display.id, Double(value))
                }
            } else if !ddcAvailable(display) {
                // Software brightness until (unless) DDC answers.
                if let software = SettingsStore.shared.brightness(for: display.identity), !display.hasDDC {
                    update(&brightness, display.id, software)
                } else if brightness[display.id] == nil {
                    brightness[display.id] = 1.0
                }
            }
            if adjustments[display.id] == nil {
                let saved = SettingsStore.shared.state.imageAdjustments[display.identity] ?? .neutral
                adjustments[display.id] = saved
                // Also when neutral: the engine may still hold the adjustments
                // of another monitor that used this display ID before.
                engine.setImageAdjustments(saved, display: display.id)
            }
            loadDDCValues(for: display)
        }
        if force || ids != lastCapabilityIDs {
            lastCapabilityIDs = ids
            loadSystemCapabilities(for: displays)
        }
    }

    /// Keeps the last known name of each display, so settings can list
    /// displays that are not connected right now.
    private func rememberNames(of displays: [DisplayInfo]) {
        let ours = Set(VirtualScreenManager.shared.active.map(\.displayID))
        var names = SettingsStore.shared.state.knownDisplayNames
        for display in displays where !ours.contains(display.id) {
            names[display.identity] = display.name
        }
        if names != SettingsStore.shared.state.knownDisplayNames {
            SettingsStore.shared.state.knownDisplayNames = names
        }
    }

    /// Assigns only real changes, so @Published does not re-render the menu
    /// for values that arrive unchanged.
    private func update<Value: Equatable>(_ dictionary: inout [CGDirectDisplayID: Value],
                                          _ id: CGDirectDisplayID, _ value: Value) {
        if dictionary[id] != value { dictionary[id] = value }
    }

    /// Rotation/HDR support comes from MonitorPanel, which is not thread-safe:
    /// query it on the main thread, after the display list has settled.
    private func loadSystemCapabilities(for displays: [DisplayInfo]) {
        let ids = displays.map(\.id)
        capabilityWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var rotate = Set<CGDirectDisplayID>()
            var capable = Set<CGDirectDisplayID>()
            var enabled = Set<CGDirectDisplayID>()
            let online = Set(self.manager.displays.map(\.id))
            for id in ids where online.contains(id) {
                if gd_display_can_rotate(id) == 1 { rotate.insert(id) }
                if gd_display_has_hdr(id) == 1 {
                    capable.insert(id)
                    if gd_display_hdr_enabled(id) == 1 { enabled.insert(id) }
                }
            }
            if self.canRotate != rotate { self.canRotate = rotate }
            if self.hdrCapable != capable { self.hdrCapable = capable }
            if self.hdrEnabled != enabled { self.hdrEnabled = enabled }
        }
        capabilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private var capabilityWork: DispatchWorkItem?

    /// What the monitor's DDC/CI interface reported.
    public struct DDCInfo: Equatable {
        /// nil while unknown, false when the monitor never answered.
        public var responsive: Bool?
        public var capabilities: DDCCapabilities?
        /// Raw current/maximum per VCP code for the extra controls.
        public var values: [UInt8: DDCValue] = [:]
    }

    public struct DDCValue: Equatable {
        public var current: Int
        public var maximum: Int
        public var fraction: Double { maximum > 0 ? Double(current) / Double(maximum) : 0 }
    }

    @Published public private(set) var ddcInfo: [CGDirectDisplayID: DDCInfo] = [:]

    /// DDC is used only once the monitor has actually answered; a matched video
    /// service that never replies (common behind docks) falls back to software.
    public func ddcAvailable(_ display: DisplayInfo) -> Bool {
        display.hasDDC && ddcInfo[display.id]?.responsive == true
    }

    private static let extraCodes: [DDCController.VCP] = [.colorPreset, .redGain, .greenGain, .blueGain, .sharpness]
    public static let pictureModeCode: UInt8 = 0xDC

    private func loadDDCValues(for display: DisplayInfo, full: Bool = true) {
        // Probe whenever a service matched; `ddcAvailable` is the result of this probe.
        guard display.hasDDC else { return }
        let id = display.id
        let started = Date()
        let includeExtras = full
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let ddc = self.ddc
            // Brightness doubles as the "is anyone there" probe.
            guard let brightnessReading = ddc.read(.brightness, display: id) else {
                DispatchQueue.main.async {
                    var info = self.ddcInfo[id] ?? DDCInfo()
                    info.responsive = false
                    if self.ddcInfo[id] != info { self.ddcInfo[id] = info }
                    if self.brightness[id] == nil { self.brightness[id] = 1.0 }
                }
                return
            }
            let contrastValue = ddc.value(.contrast, display: id)
            let volumeValue = ddc.value(.volume, display: id)
            let muteRaw = ddc.read(.mute, display: id)?.current
            let input = ddc.read(.inputSource, display: id)?.current
            DispatchQueue.main.async {
                var info = self.ddcInfo[id] ?? DDCInfo()
                info.responsive = true
                if self.ddcInfo[id] != info { self.ddcInfo[id] = info }
                // Values the user changed while this read was running win.
                guard !self.isStale(id, readStartedAt: started) else { return }
                if brightnessReading.maximum > 0 {
                    self.update(&self.brightness, id, Double(brightnessReading.current) / Double(brightnessReading.maximum))
                }
                if let input { self.update(&self.inputSource, id, input & 0xFF) }
                if let contrastValue { self.update(&self.contrast, id, contrastValue) }
                if let volumeValue { self.update(&self.volume, id, volumeValue) }
                // MCCS 0x8D: 1 = muted, 2 = unmuted.
                if let muteRaw { self.update(&self.mute, id, muteRaw == 1) }
            }

            guard includeExtras else { return }
            // Capabilities are slow (~2 s) and read once; they decide which
            // extra controls and input sources the menu offers.
            let caps = ddc.capabilities(display: id)
            var values: [UInt8: DDCValue] = [:]
            var codes = Self.extraCodes.map(\.rawValue)
            if caps?.codes[Self.pictureModeCode] != nil { codes.append(Self.pictureModeCode) }
            for code in codes where caps == nil || caps?.codes[code] != nil {
                if let reading = ddc.read(code: code, display: id) {
                    values[code] = DDCValue(current: reading.current, maximum: reading.maximum)
                }
            }
            DispatchQueue.main.async {
                var info = self.ddcInfo[id] ?? DDCInfo()
                info.capabilities = caps
                if self.isStale(id, readStartedAt: started) {
                    // Keep what the user set; take only codes not yet known.
                    info.values.merge(values) { current, _ in current }
                } else {
                    info.values = values
                }
                if self.ddcInfo[id] != info { self.ddcInfo[id] = info }
            }
        }
    }

    // MARK: Generic DDC controls

    private let ddcQueue = DispatchQueue(label: "greatdisplay.ddc-writes")
    private enum DDCPayload { case raw(Int), fraction(Double) }
    private var pendingDDC: [String: (CGDirectDisplayID, UInt8, DDCPayload)] = [:]
    private var ddcInFlight: Set<String> = []
    /// When the user last changed a hardware value, per display. Reads that
    /// started before this are stale and must not move the sliders back.
    private var lastUserWrite: [CGDirectDisplayID: Date] = [:]

    private func noteUserWrite(_ id: CGDirectDisplayID) { lastUserWrite[id] = Date() }

    private func isStale(_ id: CGDirectDisplayID, readStartedAt start: Date) -> Bool {
        if hardwareInFlight.contains(id) { return true }
        if let last = lastUserWrite[id], last >= start { return true }
        return ddcInFlight.contains { $0.hasPrefix("\(id)-") }
    }

    /// Queues a DDC write; while one is on the wire only the latest value per
    /// display and code is kept, so the monitor tracks the slider without a backlog.
    private func enqueueDDC(_ id: CGDirectDisplayID, _ code: UInt8, _ payload: DDCPayload) {
        noteUserWrite(id)
        let key = "\(id)-\(code)"
        pendingDDC[key] = (id, code, payload)
        guard !ddcInFlight.contains(key) else { return }
        ddcInFlight.insert(key)
        drainDDC(key)
    }

    /// Writes a raw VCP value, collapsing rapid slider updates per code.
    public func setDDC(code: UInt8, raw: Int, for display: DisplayInfo) {
        guard ddcAvailable(display) else { return }
        var info = ddcInfo[display.id] ?? DDCInfo()
        if var value = info.values[code] {
            value.current = raw
            info.values[code] = value
            ddcInfo[display.id] = info
        }
        enqueueDDC(display.id, code, .raw(raw))
    }

    private func drainDDC(_ key: String) {
        guard let (id, code, payload) = pendingDDC.removeValue(forKey: key) else {
            ddcInFlight.remove(key)
            return
        }
        let ddc = self.ddc
        ddcQueue.async { [weak self] in
            switch payload {
            case .raw(let raw):
                _ = ddc.write(code: code, value: raw, display: id)
            case .fraction(let fraction):
                if let vcp = DDCController.VCP(rawValue: code) {
                    _ = ddc.setValue(fraction, vcp: vcp, display: id)
                }
            }
            DispatchQueue.main.async {
                self?.noteUserWrite(id)
                self?.drainDDC(key)
            }
        }
    }

    public func ddcValue(_ code: UInt8, for id: CGDirectDisplayID) -> DDCValue? {
        ddcInfo[id]?.values[code]
    }

    /// One-shot commands (power, factory resets) that need no value tracking.
    public func sendDDCCommand(code: UInt8, value: Int, for display: DisplayInfo, completion: (() -> Void)? = nil) {
        guard ddcAvailable(display) else { return }
        let id = display.id
        let ddc = self.ddc
        ddcQueue.async { [weak self] in
            _ = ddc.write(code: code, value: value, display: id)
            usleep(600_000)
            DispatchQueue.main.async {
                // Resets change several values; read them again.
                if let self, let display = self.display(id) { self.loadDDCValues(for: display) }
                completion?()
            }
        }
    }

    /// Input sources for the menu: the monitor's own list when its
    /// capabilities string has one, otherwise the common MCCS values.
    public func inputSources(for display: DisplayInfo) -> [InputSource] {
        guard let values = ddcInfo[display.id]?.capabilities?.values(for: .inputSource), !values.isEmpty else {
            return InputSource.common
        }
        return values.map { InputSource.named($0) }
    }

    public func display(_ id: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    // MARK: Brightness

    public func brightness(for id: CGDirectDisplayID) -> Double {
        brightness[id] ?? 1.0
    }

    public func setBrightness(_ value: Double, for display: DisplayInfo) {
        let clamped = setBrightnessWithoutOSD(value, for: display)
        showBrightnessOSD(display: display, value: clamped)
    }

    public func adjustBrightness(_ delta: Double, for display: DisplayInfo) {
        setBrightness(brightness(for: display.id) + delta, for: display)
    }

    /// Displays the brightness/volume keys act on (per-display preference).
    private var keyboardDisplays: [DisplayInfo] {
        displays.filter { SettingsStore.shared.preferences(for: $0.identity).keyboardControl }
    }

    /// Brightness keys: every display moves one step from its own level (a
    /// dim monitor and a bright one stay apart instead of snapping together).
    public func adjustAllBrightness(by delta: Double) {
        let targets = keyboardDisplays.filter { !$0.isMirrored }
        guard !targets.isEmpty else { return }
        var shown: (DisplayInfo, Double)?
        for display in targets {
            if usesCombinedBrightness(display) {
                let next = max(0, min(1, combinedBrightness(for: display) + delta))
                setCombinedBrightness(next, for: display, showOSD: false)
                if shown == nil || display.isMain { shown = (display, next) }
            } else {
                let next = max(0, min(1, brightness(for: display.id) + delta))
                setBrightnessWithoutOSD(next, for: display)
                if shown == nil || display.isMain { shown = (display, next) }
            }
        }
        if let (display, value) = shown, SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: value < 0.35 ? "sun.min.fill" : "sun.max.fill",
                                      title: targets.count > 1 ? "Brightness" : display.name,
                                      value: value,
                                      detail: targets.count > 1 ? "\(targets.count) displays · each from its own level" : nil)
        }
    }

    /// Applies and saves a brightness level (hardware where the display has
    /// it, gamma dimming otherwise). Returns the clamped value.
    @discardableResult
    private func setBrightnessWithoutOSD(_ value: Double, for display: DisplayInfo) -> Double {
        let clamped = max(0, min(1, value))
        brightness[display.id] = clamped
        SettingsStore.shared.setBrightness(clamped, for: display.identity)
        if display.hasHardwareBrightness || ddcAvailable(display) {
            writeHardwareBrightness(Float(clamped), display: display.id)
        } else {
            engine.applySoftwareDimming(clamped, display: display.id)
            dimming[display.id] = clamped
        }
        saveConfiguration(for: display)
        return clamped
    }

    public func brightenAll() {
        adjustAllBrightness(by: 0.1)
    }

    private func showBrightnessOSD(display: DisplayInfo, value: Double) {
        guard SettingsStore.shared.state.general.showOSD else { return }
        OSDController.shared.show(symbol: "sun.max.fill",
                                  title: display.name,
                                  value: value,
                                  detail: display.hasHardwareBrightness ? "Hardware brightness" : "Software dimming")
    }

    // MARK: Software dimming

    public func dimming(for id: CGDirectDisplayID) -> Double {
        dimming[id] ?? 1.0
    }

    public func setDimming(_ value: Double, for display: DisplayInfo) {
        let clamped = max(0, min(1, value))
        dimming[display.id] = clamped
        engine.applySoftwareDimming(clamped, display: display.id)
        if SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: "circle.lefthalf.filled",
                                      title: "\(display.name) — Dimming",
                                      value: clamped)
        }
    }

    public func resetAdjustments(for display: DisplayInfo) {
        engine.resetSoftwareDimming(display.id)
        dimming[display.id] = 1.0
        if display.hasHardwareBrightness || ddcAvailable(display) {
            // Off the main thread like every other hardware write: a DDC write
            // waits for the I2C lock, which a slow capabilities read can hold.
            brightness[display.id] = 1.0
            SettingsStore.shared.setBrightness(1.0, for: display.identity)
            writeHardwareBrightness(1.0, display: display.id)
        }
        saveConfiguration(for: display)
    }

    // MARK: Contrast / volume

    public func contrast(for id: CGDirectDisplayID) -> Double? {
        contrast[id]
    }

    public func setContrast(_ value: Double, for display: DisplayInfo) {
        guard ddcAvailable(display) else { return }
        let clamped = max(0, min(1, value))
        contrast[display.id] = clamped
        enqueueDDC(display.id, DDCController.VCP.contrast.rawValue, .fraction(clamped))
        if SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: "circle.righthalf.filled",
                                      title: "\(display.name) — Contrast",
                                      value: clamped)
        }
    }

    public func volume(for id: CGDirectDisplayID) -> Double? {
        volume[id]
    }

    public func setVolume(_ value: Double, for display: DisplayInfo) {
        guard ddcAvailable(display) else { return }
        let clamped = max(0, min(1, value))
        volume[display.id] = clamped
        if mute[display.id] == true {
            // Dragging the volume clears mute (MCCS: 2 = unmuted).
            mute[display.id] = false
            enqueueDDC(display.id, DDCController.VCP.mute.rawValue, .raw(2))
        }
        enqueueDDC(display.id, DDCController.VCP.volume.rawValue, .fraction(clamped))
        if SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: "speaker.wave.2.fill",
                                      title: "\(display.name) — Volume",
                                      value: clamped)
        }
    }

    public func toggleMute(for display: DisplayInfo) {
        guard ddcAvailable(display) else { return }
        let newValue = !(mute[display.id] ?? false)
        mute[display.id] = newValue
        // MCCS 0x8D takes raw values: 1 = mute, 2 = unmute.
        enqueueDDC(display.id, DDCController.VCP.mute.rawValue, .raw(newValue ? 1 : 2))
        if SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: newValue ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                      title: "\(display.name) — \(newValue ? "Muted" : "Unmuted")",
                                      value: newValue ? 0 : (volume[display.id] ?? 0.5))
        }
    }

    // MARK: Coalesced hardware writes

    private let hardwareQueue = DispatchQueue(label: "greatdisplay.hardware-brightness")
    private var pendingHardware: [CGDirectDisplayID: Float] = [:]
    private var hardwareInFlight: Set<CGDirectDisplayID> = []

    /// Sends hardware brightness off the main thread, dropping intermediate
    /// values while a (possibly slow DDC) write is still running.
    private func writeHardwareBrightness(_ value: Float, display id: CGDirectDisplayID) {
        noteUserWrite(id)
        pendingHardware[id] = value
        guard !hardwareInFlight.contains(id) else { return }
        hardwareInFlight.insert(id)
        drainHardware(id)
    }

    private func drainHardware(_ id: CGDirectDisplayID) {
        guard let value = pendingHardware.removeValue(forKey: id) else {
            hardwareInFlight.remove(id)
            return
        }
        let engine = self.engine
        hardwareQueue.async { [weak self] in
            _ = engine.setHardwareBrightness(value, display: id)
            DispatchQueue.main.async {
                self?.noteUserWrite(id)
                self?.drainHardware(id)
            }
        }
    }

    /// Blocks until queued hardware writes are sent (command line use).
    public func flushHardwareWrites() {
        hardwareQueue.sync {}
    }

    // MARK: Combined brightness

    /// Position of the "Min HW" marker on the combined slider: below it the
    /// hardware is at its minimum and gamma dimming takes over.
    public static let combinedHardwareFloor = 0.25
    private static let softwareFloor = 0.12

    public func usesCombinedBrightness(_ display: DisplayInfo) -> Bool {
        SettingsStore.shared.state.general.combinedBrightness &&
            SettingsStore.shared.state.general.softwareDimmingEnabled &&
            (display.hasHardwareBrightness || ddcAvailable(display))
    }

    /// The single knob value shown in the menu.
    public func combinedBrightness(for display: DisplayInfo) -> Double {
        guard usesCombinedBrightness(display) else { return brightness(for: display.id) }
        let floor = Self.combinedHardwareFloor
        let software = dimming(for: display.id)
        if software < 0.999 {
            let fraction = (software - Self.softwareFloor) / (1 - Self.softwareFloor)
            return max(0, min(floor, fraction * floor))
        }
        return floor + brightness(for: display.id) * (1 - floor)
    }

    public func setCombinedBrightness(_ value: Double, for display: DisplayInfo, showOSD: Bool = true) {
        guard usesCombinedBrightness(display) else {
            setBrightness(value, for: display)
            return
        }
        let value = max(0, min(1, value))
        let floor = Self.combinedHardwareFloor
        let hardware = value >= floor ? (value - floor) / (1 - floor) : 0
        let software = value >= floor ? 1 : Self.softwareFloor + (value / floor) * (1 - Self.softwareFloor)
        if abs((brightness[display.id] ?? -1) - hardware) > 0.004 {
            brightness[display.id] = hardware
            writeHardwareBrightness(Float(hardware), display: display.id)
        }
        dimming[display.id] = software
        engine.applySoftwareDimming(software, display: display.id)
        SettingsStore.shared.setBrightness(hardware, for: display.identity)
        saveConfiguration(for: display)
        if showOSD && SettingsStore.shared.state.general.showOSD {
            OSDController.shared.show(symbol: value < floor ? "sun.min.fill" : "sun.max.fill",
                                      title: display.name,
                                      value: value,
                                      detail: value < floor ? "Combined · software dimming" : "Combined · hardware")
        }
    }

    // MARK: Image adjustments

    public func adjustments(for id: CGDirectDisplayID) -> ImageAdjustments {
        adjustments[id] ?? .neutral
    }

    public func setAdjustments(_ value: ImageAdjustments, for display: DisplayInfo) {
        adjustments[display.id] = value
        engine.setImageAdjustments(value, display: display.id)
        if value == .neutral {
            SettingsStore.shared.state.imageAdjustments.removeValue(forKey: display.identity)
        } else {
            SettingsStore.shared.state.imageAdjustments[display.identity] = value
        }
    }

    public func resetImageAdjustments(for display: DisplayInfo) {
        setAdjustments(.neutral, for: display)
    }

    /// Software contrast (0…1, 0.5 neutral) for displays without DDC contrast.
    public func softwareContrast(for id: CGDirectDisplayID) -> Double {
        (adjustments(for: id).contrast - 0.5)
    }

    public func setSoftwareContrast(_ value: Double, for display: DisplayInfo) {
        var current = adjustments(for: display.id)
        current.contrast = 0.5 + max(0, min(1, value))
        setAdjustments(current, for: display)
    }

    // MARK: Input source

    public func setInputSource(_ source: InputSource, for display: DisplayInfo) {
        guard ddcAvailable(display) else { return }
        inputSource[display.id] = source.value
        let id = display.id
        let name = display.name
        DispatchQueue.global(qos: .userInitiated).async { [ddc, weak self] in
            let ok = ddc.write(.inputSource, value: source.value, display: id)
            DispatchQueue.main.async {
                if ok {
                    OSDController.shared.show(symbol: source.symbol, title: "\(name) — \(source.name)", value: 1,
                                              detail: "Input source switched")
                } else {
                    OSDController.shared.show(symbol: "exclamationmark.triangle.fill",
                                              title: "\(name) did not accept the input switch", value: 1)
                    // Show the input the monitor is really on again.
                    if let self, let display = self.display(id) { self.loadDDCValues(for: display, full: false) }
                }
            }
        }
    }

    // MARK: Rotation, HDR, connection, arrangement

    public func rotation(for display: DisplayInfo) -> Int {
        Int(display.rotation.rounded()) % 360
    }

    public func setRotation(_ degrees: Int, for display: DisplayInfo) {
        if !manager.setRotation(degrees, for: display.id) { reportError() }
    }

    public func setHDR(_ enabled: Bool, for display: DisplayInfo) {
        if manager.setHDR(enabled, for: display.id) {
            if enabled { hdrEnabled.insert(display.id) } else { hdrEnabled.remove(display.id) }
        } else {
            reportError()
        }
    }

    @discardableResult
    public func disconnect(_ display: DisplayInfo) -> Bool {
        let ok = manager.disconnect(display.id)
        if !ok { reportError() }
        return ok
    }

    public func reconnect(_ id: CGDirectDisplayID) {
        if !manager.reconnect(id) { reportError() }
    }

    public func reconnectAll() {
        manager.reconnectAll()
    }

    public func place(_ display: DisplayInfo, _ placement: DisplayManager.Placement) {
        if manager.place(display.id, placement) {
            saveConfiguration(for: current(display))
        } else {
            reportError()
        }
    }

    public func refreshRates(for display: DisplayInfo) -> [ModeInfo] {
        manager.refreshRates(for: display)
    }

    public func sliderModes(for display: DisplayInfo) -> [ModeInfo] {
        manager.sliderModes(for: display, hideLowResolutions: SettingsStore.shared.state.general.hideLowResolutions)
    }

    /// Full re-detection (Tools > Redetect Displays): re-reads everything.
    public func redetect() {
        manager.refresh()
        refreshValues(for: displays, force: true)
    }

    /// Called when the menu opens: re-reads only the slider values (picking up
    /// changes made with the monitor's own buttons), skips displays the user
    /// adjusted in the last few seconds, and retries monitors that never answered.
    public func menuWillOpen() {
        manager.refresh()
        for display in displays where display.hasDDC {
            if ddcInfo[display.id]?.responsive != true {
                loadDDCValues(for: display, full: true)
            } else if Date().timeIntervalSince(lastUserWrite[display.id] ?? .distantPast) > 3 {
                loadDDCValues(for: display, full: false)
            }
        }
    }

    // MARK: Volume keys

    /// The display whose speakers macOS is sending audio to, when macOS cannot
    /// set that device's volume itself (DisplayPort/HDMI audio).
    public func volumeKeyTarget() -> DisplayInfo? {
        guard let device = AudioOutput.defaultDevice(), device.isDisplayAudio, !device.hasSoftwareVolume else {
            return nil
        }
        let candidates = keyboardDisplays.filter { ddcAvailable($0) && volume[$0.id] != nil }
        let name = device.name.lowercased()
        return candidates.first { name.contains($0.name.lowercased()) || $0.name.lowercased().contains(name) }
            ?? (candidates.count == 1 ? candidates.first : nil)
    }

    public func handleVolumeKey(_ key: KeyboardController.VolumeKey) {
        guard let display = volumeKeyTarget() else { return }
        switch key {
        case .mute:
            toggleMute(for: display)
        case .up, .down:
            let step = 1.0 / 16
            let current = volume[display.id] ?? 0.5
            setVolume(current + (key == .up ? step : -step), for: display)
        }
    }

    private func reportError() {
        if let error = manager.lastError {
            OSDController.shared.show(symbol: "exclamationmark.triangle.fill", title: error, value: 1)
        }
    }

    // MARK: Configuration

    /// Mode the UI should show: the one being applied, else the current one.
    @Published public private(set) var pendingMode: [CGDirectDisplayID: ModeInfo] = [:]
    private var queuedMode: [CGDirectDisplayID: ModeInfo] = [:]
    private var modeInFlight: Set<CGDirectDisplayID> = []

    public func effectiveMode(for display: DisplayInfo) -> ModeInfo? {
        pendingMode[display.id] ?? display.currentMode
    }

    /// Changes the mode without blocking the UI. The menu shows the requested
    /// mode immediately; rapid requests collapse to the latest one; the display
    /// fades out and back in through its own colour table so only it dims.
    public func setMode(_ mode: ModeInfo, for display: DisplayInfo) {
        if mode.matches(effectiveMode(for: display)) && mode.isHiDPI == effectiveMode(for: display)?.isHiDPI {
            return
        }
        pendingMode[display.id] = mode
        queuedMode[display.id] = mode
        guard !modeInFlight.contains(display.id) else { return }
        runModeQueue(display.id)
    }

    private func runModeQueue(_ id: CGDirectDisplayID) {
        guard let mode = queuedMode.removeValue(forKey: id) else {
            modeInFlight.remove(id)
            // Keep showing the requested mode until the inventory reports it,
            // so the menu never falls back to the old mode for a moment.
            if let pending = pendingMode[id], let current = display(id)?.currentMode,
               !(current.matches(pending) && current.isHiDPI == pending.isHiDPI) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.modeInFlight.contains(id) else { return }
                    self.pendingMode.removeValue(forKey: id)
                }
            } else {
                pendingMode.removeValue(forKey: id)
            }
            return
        }
        modeInFlight.insert(id)
        let generation = displayGenerations[id, default: 0]
        Task { @MainActor in
            guard displayGenerations[id, default: 0] == generation else { return }
            let fade = SettingsStore.shared.state.general.fadeOnModeChange
                && SettingsStore.shared.state.general.softwareDimmingEnabled
            if fade { await engine.animateTransition(to: 0, duration: 0.14, display: id) }
            guard displayGenerations[id, default: 0] == generation else { return }
            let ok = await manager.applyMode(mode.mode, for: id)
            guard displayGenerations[id, default: 0] == generation else { return }
            if fade {
                // Let the window server finish swapping the framebuffer (and
                // macOS restore the profile's table) before fading back in.
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard displayGenerations[id, default: 0] == generation else { return }
                await engine.animateTransition(to: 1, duration: 0.26, display: id)
                guard displayGenerations[id, default: 0] == generation else { return }
                // The fade captured the colour table as its baseline. If nothing
                // else is applied, forget it, so a later colour-profile change is
                // not overwritten with this copy.
                engine.invalidateGamma(id)
            }
            engine.reapply(id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [engine] in engine.reapply(id) }
            if ok {
                if let display = display(id) { saveConfiguration(for: display) }
            } else {
                queuedMode.removeValue(forKey: id)
                reportError()
            }
            runModeQueue(id)
        }
    }

    public func toggleHiDPI(for display: DisplayInfo) {
        guard let current = effectiveMode(for: display) else { return }
        let candidates = display.modes.filter {
            $0.width == current.width && $0.height == current.height && $0.isHiDPI != current.isHiDPI
        }
        guard let mode = candidates.first(where: { Int($0.refreshRate.rounded()) == Int(current.refreshRate.rounded()) })
                ?? candidates.first else {
            OSDController.shared.show(symbol: "exclamationmark.triangle.fill",
                                      title: "No \(current.isHiDPI ? "low resolution" : "HiDPI") variant for \(current.resolutionText)",
                                      value: 1)
            return
        }
        setMode(mode, for: display)
    }

    public func setMain(_ display: DisplayInfo) {
        guard manager.setMain(display.id) else {
            reportError()
            return
        }
        // Every display's origin moved, and the previous main display lost the flag.
        // Displays without a saved configuration stay that way.
        for other in displays where other.id == display.id
            || SettingsStore.shared.configuration(for: other.identity) != nil {
            saveConfiguration(for: other)
        }
    }

    /// The inventory's up-to-date entry for a display. A `DisplayInfo` passed
    /// in by a view predates the change that was just applied.
    private func current(_ display: DisplayInfo) -> DisplayInfo {
        self.display(display.id) ?? display
    }

    public func setMirror(_ display: DisplayInfo, to target: DisplayInfo?) {
        if !manager.setMirror(source: display.id, on: target?.id) { reportError() }
        objectWillChange.send()
    }

    /// The display currently showing `display`'s content, if any.
    public func mirrorTarget(of display: DisplayInfo) -> CGDirectDisplayID? {
        manager.mirrorTarget(for: display.id)
    }

    public func rotate(_ display: DisplayInfo) {
        if !manager.rotate(display.id) { reportError() }
    }

    public func move(_ display: DisplayInfo, by delta: CGPoint) {
        guard manager.move(display.id, to: CGPoint(x: display.bounds.origin.x + delta.x,
                                                   y: display.bounds.origin.y + delta.y)) else {
            reportError()
            return
        }
        saveConfiguration(for: current(display))
    }

    public func identify(_ display: DisplayInfo) {
        IdentifyController.shared.identify(display)
    }

    private func saveConfiguration(for display: DisplayInfo) {
        var configuration = SettingsStore.shared.configuration(for: display.identity)
            ?? DisplayConfiguration(displayID: display.id, identity: display.identity)
        configuration.displayID = display.id
        configuration.logicalWidth = display.currentMode?.width
        configuration.logicalHeight = display.currentMode?.height
        configuration.hiDPI = display.currentMode?.isHiDPI
        configuration.refreshRate = display.currentMode?.refreshRate
        configuration.isMain = display.isMain
        configuration.origin = display.bounds.origin
        configuration.hardwareBrightness = brightness[display.id].map(Float.init)
        configuration.softwareDimming = dimming[display.id]
        SettingsStore.shared.setConfiguration(configuration)
    }

    public func restoreSavedConfigurations() {
        guard SettingsStore.shared.state.general.restoreConfigurationOnLaunch else { return }
        for display in displays {
            if let configuration = SettingsStore.shared.configuration(for: display.identity) {
                _ = manager.restore(configuration: configuration, to: display.id)
                if let brightness = configuration.hardwareBrightness, display.hasHardwareBrightness {
                    _ = engine.setHardwareBrightness(brightness, display: display.id)
                }
                if let software = configuration.softwareDimming, software < 0.999 {
                    engine.applySoftwareDimming(software, display: display.id)
                    dimming[display.id] = software
                }
            }
        }
    }
}
