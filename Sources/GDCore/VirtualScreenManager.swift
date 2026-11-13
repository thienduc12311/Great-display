import Foundation
import GDCBridge
import CoreGraphics
import Combine

public struct ActiveVirtualScreen: Identifiable {
    public let id: UUID
    public var configuration: VirtualScreenConfiguration
    public let displayID: CGDirectDisplayID
    /// Largest framebuffer this screen accepts without reconnecting.
    public var maxPixels: (wide: UInt32, high: UInt32) = (0, 0)
}

/// Owns the lifetime of the virtual screens created through the CoreGraphics
/// virtual-display facility, their (flexible) mode lists, and the rules that
/// tie a virtual screen to an associated physical display.
@MainActor
public final class VirtualScreenManager: ObservableObject {
    public static let shared = VirtualScreenManager()

    @Published public private(set) var active: [ActiveVirtualScreen] = []
    @Published public private(set) var lastError: String?

    private var handles: [UUID: OpaquePointer] = [:]
    private var recentlyDestroyed: [UUID: Date] = [:]
    private var retries: [UUID: Int] = [:]
    private var creating: Set<UUID> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Ceiling for a virtual framebuffer (pixels per side): 8K, or 16K when
    /// the screen allows resolutions over 8K.
    public static func maximumPixels(for configuration: VirtualScreenConfiguration) -> Int {
        configuration.allowOver8K ? 16384 : 7680
    }

    /// Smallest logical side of a virtual screen, in points.
    public static let minimumSide = 320
    /// Widest shape a virtual screen may have (long side : short side).
    public static let maximumAspect = 6.0

    /// The same configuration with a geometry the system can represent: the
    /// aspect ratio within bounds, the framebuffer within the pixel ceiling
    /// and both sides at least the minimum. The screen is scaled as a whole,
    /// so its shape is kept; clamping each side on its own would distort it
    /// (a 5120 × 1440 HiDPI screen would become 3840 × 1440).
    public static func fitted(_ configuration: VirtualScreenConfiguration) -> VirtualScreenConfiguration {
        var width = Double(max(1, configuration.width))
        var height = Double(max(1, configuration.height))
        if width / height > maximumAspect { height = width / maximumAspect }
        if height / width > maximumAspect { width = height / maximumAspect }
        let limit = Double(maximumPixels(for: configuration) / (configuration.hiDPI ? 2 : 1))
        let over = max(width, height) / limit
        if over > 1 { width /= over; height /= over }
        let under = Double(minimumSide) / min(width, height)
        if under > 1 { width *= under; height *= under }
        var result = configuration
        result.width = Int((width / 2).rounded()) * 2
        result.height = Int((height / 2).rounded()) * 2
        return result
    }

    /// Off for command line diagnostics: association rules and auto-start
    /// must not connect, mirror or stream the user's saved screens there.
    public var automaticConnectionEnabled = true

    private init() {
        // Associated displays: connect/disconnect and stream with the physical display.
        DisplayManager.shared.$displays
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] displays in self?.applyAssociations(displays) }
            .store(in: &cancellables)
        // …and right away when an association is switched on or edited.
        SettingsStore.shared.$state
            .map(\.virtualScreens)
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.applyAssociations(DisplayManager.shared.displays) }
            .store(in: &cancellables)
    }

    public var isSupported: Bool { gd_virtual_display_available() != 0 }

    // MARK: Modes

    /// Logical sizes published for a configuration: the configured size first,
    /// then (when flexible) a ladder of common widths in the same aspect ratio,
    /// from 640 up to 1.5 × the configured size, within the pixel ceiling.
    public static func logicalSizes(for configuration: VirtualScreenConfiguration) -> [(width: Int, height: Int)] {
        let base = (width: max(320, configuration.width), height: max(200, configuration.height))
        guard configuration.flexibleModes else { return [base] }
        let ratio = Double(base.width) / Double(base.height)
        let density = configuration.hiDPI ? 2 : 1
        let ceiling = maximumPixels(for: configuration)
        let ceilingWidth = Double(ceiling / density)
        let ceilingHeight = Double(ceiling / density)
        let upper = min(Double(base.width) * 1.5, ceilingWidth, ceilingHeight * ratio)
        let ladder = [640, 720, 800, 960, 1024, 1152, 1280, 1366, 1440, 1600, 1680, 1792, 1920, 2048, 2240,
                      2304, 2560, 2880, 3008, 3200, 3360, 3440, 3840, 4096, 5120, 6016, 6144, 7680]
        var sizes = [base]
        var seen = Set([base.width])
        let isPortrait = ratio < 1
        for step in ladder {
            // For portrait screens the ladder describes the height.
            let width = isPortrait ? Int((Double(step) * ratio / 2).rounded()) * 2 : step
            let height = isPortrait ? step : Int((Double(step) / ratio / 2).rounded()) * 2
            guard Double(width) <= upper, width >= 480, height >= 360, !seen.contains(width) else { continue }
            seen.insert(width)
            sizes.append((width, height))
        }
        return sizes
    }

    private static func pixelModes(for configuration: VirtualScreenConfiguration) -> (widths: [UInt32], heights: [UInt32]) {
        let density = configuration.hiDPI ? 2 : 1
        let ceiling = maximumPixels(for: configuration)
        let sizes = logicalSizes(for: configuration)
        return (sizes.map { UInt32(min(ceiling, $0.width * density)) },
                sizes.map { UInt32(min(ceiling, $0.height * density)) })
    }

    // MARK: Lifetime

    @discardableResult
    public func create(_ configuration: VirtualScreenConfiguration) -> CGDirectDisplayID? {
        let configuration = Self.fitted(configuration)
        guard isSupported else {
            lastError = String(cString: gd_virtual_display_error())
            return nil
        }
        if let existing = active.first(where: { $0.id == configuration.id }) { return existing.displayID }
        // Never create a second display for the same screen (a lost handle
        // would leave an orphan virtual display connected).
        guard handles[configuration.id] == nil, !creating.contains(configuration.id) else { return nil }
        creating.insert(configuration.id)
        defer { creating.remove(configuration.id) }

        let name = configuration.name.isEmpty ? "Virtual Screen" : configuration.name
        let modes = Self.pixelModes(for: configuration)
        // Headroom up to the ceiling lets later resizes (any aspect ratio) be
        // applied live; fall back to the exact size if the system refuses it.
        var handle: OpaquePointer?
        var limits: (UInt32, UInt32) = (0, 0)
        for headroom in [true, false] {
            let ceiling = UInt32(Self.maximumPixels(for: configuration))
            let maxWide = headroom ? ceiling : (modes.widths.max() ?? 1920)
            let maxHigh = headroom ? ceiling : (modes.heights.max() ?? 1080)
            handle = name.withCString { pointer in
                modes.widths.withUnsafeBufferPointer { widths in
                    modes.heights.withUnsafeBufferPointer { heights in
                        gd_virtual_display_create_modes(pointer, widths.baseAddress, heights.baseAddress,
                                                        UInt32(modes.widths.count), configuration.refreshRate,
                                                        configuration.millimeterWidth, configuration.millimeterHeight,
                                                        configuration.serialNumber, 0x5678, 0x1234,
                                                        configuration.hiDPI ? 1 : 0, maxWide, maxHigh)
                    }
                }
            }
            if handle != nil { limits = (maxWide, maxHigh); break }
        }
        guard let handle else {
            lastError = String(cString: gd_virtual_display_error())
            // Re-creating a screen right after disconnecting it fails while the
            // window server is still tearing the old one down: retry shortly.
            if let destroyed = recentlyDestroyed[configuration.id], Date().timeIntervalSince(destroyed) < 8 {
                let attempt = (retries[configuration.id] ?? 0) + 1
                if attempt <= 6 {
                    retries[configuration.id] = attempt
                    scheduleCreate(configuration, after: 1.0)
                }
            }
            return nil
        }
        retries.removeValue(forKey: configuration.id)

        let displayID = gd_virtual_display_id(handle)
        handles[configuration.id] = handle
        if displayID != 0 { DisplayManager.virtualDisplayIDs.insert(displayID) }
        active.append(ActiveVirtualScreen(id: configuration.id, configuration: configuration, displayID: displayID,
                                          maxPixels: limits))
        lastError = nil

        // The window server publishes the new display and its mode table
        // asynchronously: refresh, select the configured size, apply mirroring.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            DisplayManager.shared.refresh()
            self.selectPreferredMode(configuration, displayID: displayID)
            if let targetIdentity = configuration.mirrorTargetIdentity,
               let target = DisplayManager.shared.displays.first(where: { $0.identity == targetIdentity }) {
                _ = DisplayManager.shared.setMirror(source: displayID, on: target.id)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            DisplayManager.shared.refresh()
        }
        return displayID
    }

    private func selectPreferredMode(_ configuration: VirtualScreenConfiguration, displayID: CGDirectDisplayID) {
        guard let display = DisplayManager.shared.display(id: displayID) else { return }
        if let current = display.currentMode, current.width == configuration.width,
           current.height == configuration.height, current.isHiDPI == configuration.hiDPI { return }
        _ = DisplayManager.shared.setResolution(width: configuration.width, height: configuration.height,
                                                hiDPI: configuration.hiDPI, for: displayID)
    }

    /// Changes size, aspect ratio, density or refresh rate. A connected screen
    /// keeps its display ID: the new mode list is applied in place, and only if
    /// the system refuses that is the screen reconnected.
    public func update(_ configuration: VirtualScreenConfiguration) {
        let configuration = Self.fitted(configuration)
        if let index = SettingsStore.shared.state.virtualScreens.firstIndex(where: { $0.id == configuration.id }) {
            SettingsStore.shared.state.virtualScreens[index] = configuration
        }
        guard let index = active.firstIndex(where: { $0.id == configuration.id }),
              let handle = handles[configuration.id] else { return }
        let previous = active[index].configuration
        active[index].configuration = configuration
        if previous.allowOver8K != configuration.allowOver8K {
            // The framebuffer ceiling is fixed at creation: reconnect.
            destroy(configuration.id)
            scheduleCreate(configuration, after: 0.8)
            return
        }
        let geometryChanged = previous.width != configuration.width || previous.height != configuration.height
            || previous.hiDPI != configuration.hiDPI || previous.refreshRate != configuration.refreshRate
            || previous.flexibleModes != configuration.flexibleModes
        guard geometryChanged else { return }

        let modes = Self.pixelModes(for: configuration)
        let result = modes.widths.withUnsafeBufferPointer { widths in
            modes.heights.withUnsafeBufferPointer { heights in
                gd_virtual_display_set_modes(handle, widths.baseAddress, heights.baseAddress,
                                             UInt32(modes.widths.count), configuration.refreshRate,
                                             configuration.hiDPI ? 1 : 0)
            }
        }
        let displayID = active[index].displayID
        if result == 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                DisplayManager.shared.refresh()
                self.selectPreferredMode(configuration, displayID: displayID)
                try? await Task.sleep(nanoseconds: 900_000_000)
                DisplayManager.shared.refresh()
            }
        } else {
            keyboardLog.notice("virtual screen \(configuration.name, privacy: .public): live mode change refused (\(result)); reconnecting")
            destroy(configuration.id)
            scheduleCreate(configuration, after: 0.8)
        }
    }

    /// Screens with a (re)creation scheduled; association rules leave them alone.
    private var pendingCreates: Set<UUID> = []
    private var creationGeneration = UUID()

    public func isCreationPending(_ configuration: VirtualScreenConfiguration) -> Bool {
        pendingCreates.contains(configuration.id)
    }

    /// Schedules one creation per screen (later requests while one is pending
    /// are dropped). Uses the saved configuration at that time, when present.
    private func scheduleCreate(_ configuration: VirtualScreenConfiguration, after delay: TimeInterval) {
        guard !pendingCreates.contains(configuration.id) else { return }
        pendingCreates.insert(configuration.id)
        let generation = creationGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Reset/teardown invalidates sleeping work without letting an old
            // task remove a newer request for the same screen.
            guard generation == self.creationGeneration else { return }
            self.pendingCreates.remove(configuration.id)
            guard self.handles[configuration.id] == nil else { return }
            let saved = SettingsStore.shared.state.virtualScreens.first { $0.id == configuration.id }
            // A screen that was discarded meanwhile is not brought back.
            guard let latest = saved ?? (self.retries[configuration.id] != nil ? nil : configuration) else { return }
            _ = self.create(latest)
        }
    }

    public func destroy(_ id: UUID) {
        guard let handle = handles.removeValue(forKey: id) else { return }
        if let screen = active.first(where: { $0.id == id }) {
            // Not a user stop: the stream may resume when the screen returns.
            FullScreenStreamController.shared.stop(source: screen.displayID, byUser: false)
            DisplayManager.shared.releaseMirrors(sourcing: screen.displayID)
            DisplayManager.virtualDisplayIDs.remove(screen.displayID)
        }
        gd_virtual_display_destroy(handle)
        recentlyDestroyed[id] = Date()
        active.removeAll { $0.id == id }
        DisplayManager.shared.refresh()
    }

    public func destroyAll() {
        creationGeneration = UUID()
        pendingCreates.removeAll()
        for id in Array(handles.keys) { destroy(id) }
    }

    public func startAutoStartScreens() {
        for configuration in SettingsStore.shared.state.virtualScreens where configuration.autoStart {
            // Screens tied to a display follow that display instead.
            if configuration.connectionFollowsAssociation { continue }
            if active.contains(where: { $0.id == configuration.id }) { continue }
            _ = create(configuration)
        }
    }

    public func isActive(_ configuration: VirtualScreenConfiguration) -> Bool {
        handles[configuration.id] != nil
    }

    public func displayID(for configuration: VirtualScreenConfiguration) -> CGDirectDisplayID? {
        active.first { $0.id == configuration.id }?.displayID
    }

    // MARK: Associated displays

    /// Applies the association rules of every virtual screen (its
    /// Association Settings):
    /// - auto-connect while an associated display is online, or (the
    ///   alternative) while all associated displays are offline;
    /// - enforce mirroring onto the first online associated display;
    /// - auto-start full screen streaming onto an associated display (the next
    ///   one when mirroring already uses the first);
    /// - follow the associated display's orientation.
    private func applyAssociations(_ displays: [DisplayInfo]) {
        guard automaticConnectionEnabled else { return }
        for var configuration in SettingsStore.shared.state.virtualScreens where configuration.isAssociated {
            let ownID = displayID(for: configuration)
            let online = configuration.associatedDisplayIdentities.compactMap { identity in
                displays.first { $0.identity == identity && $0.id != ownID }
            }
            let isOn = isActive(configuration)

            // Connection.
            var wanted: Bool?
            if configuration.connectWithAssociated {
                wanted = !online.isEmpty
            } else if configuration.connectWhenAssociatedOffline {
                wanted = online.isEmpty
            }
            keyboardLog.debug("association \(configuration.name, privacy: .public): online=\(online.count) wanted=\(String(describing: wanted), privacy: .public) on=\(isOn)")
            if wanted == true && !isOn {
                guard !pendingCreates.contains(configuration.id) else { continue }
                let created = create(configuration)   // the rest applies once it is online
                keyboardLog.notice("association \(configuration.name, privacy: .public): connect -> \(created.map(String.init) ?? "nil", privacy: .public) \(self.lastError ?? "", privacy: .public)")
                continue
            }
            if wanted == false && isOn {
                destroy(configuration.id)
                continue
            }
            guard isOn, let primary = online.first else { continue }

            // Shape: orientation (and, if asked, the exact aspect ratio).
            var shaped = configuration
            let portrait = primary.bounds.height > primary.bounds.width
            if configuration.matchAssociatedAspect, let mode = primary.currentMode, mode.width > 0, mode.height > 0 {
                let longSide = max(configuration.width, configuration.height)
                let ratio = Double(min(mode.width, mode.height)) / Double(max(mode.width, mode.height))
                let shortSide = Int((Double(longSide) * ratio / 2).rounded()) * 2
                (shaped.width, shaped.height) = portrait ? (shortSide, longSide) : (longSide, shortSide)
            } else if configuration.followOrientation, portrait != (configuration.height > configuration.width) {
                swap(&shaped.width, &shaped.height)
            }
            // Compare the geometry update() will actually save so an extreme
            // associated aspect cannot keep deferring mirroring and streaming.
            shaped = Self.fitted(shaped)
            if shaped.width != configuration.width || shaped.height != configuration.height {
                configuration = shaped
                update(configuration)
                continue   // mirror/stream once the new modes are live
            }

            guard let virtualID = ownID, displays.contains(where: { $0.id == virtualID }) else { continue }
            let mirrorTarget = configuration.enforceMirroring ? primary : nil
            let streamTarget: DisplayInfo? = configuration.autoStream
                ? (configuration.enforceMirroring ? (online.count > 1 ? online[1] : nil) : primary)
                : nil

            if let mirrorTarget, DisplayManager.shared.mirrorTarget(for: virtualID) != mirrorTarget.id {
                FullScreenStreamController.shared.stop(source: virtualID, byUser: false)
                _ = DisplayManager.shared.setMirror(source: virtualID, on: mirrorTarget.id)
            }
            // Not again after the user stopped it by hand; a reconnect of either
            // display re-arms it.
            let stoppedByUser = displays.first { $0.id == virtualID }
                .map { FullScreenStreamController.shared.wasStoppedByUser(sourceIdentity: $0.identity) } ?? false
            if let streamTarget, !stoppedByUser,
               FullScreenStreamController.shared.stream(for: virtualID)?.target != streamTarget.id {
                Task { @MainActor in
                    _ = await FullScreenStreamController.shared.start(source: virtualID, on: streamTarget.id, activate: false)
                }
            }
        }
    }
}
