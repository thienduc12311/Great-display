import Foundation
import CoreGraphics
import Combine

public struct GeneralSettings: Codable, Equatable {
    public var launchAtLogin: Bool = false
    public var showOSD: Bool = true
    public var osdDuration: Double = 1.4
    public var brightnessStep: Double = 0.0625
    public var handleBrightnessKeys: Bool = true
    public var menuBarShowsPercentage: Bool = false
    public var restoreConfigurationOnLaunch: Bool = true
    public var softwareDimmingEnabled: Bool = true
    public var showResolutionPicker: Bool = true
    // Menu
    public var combinedBrightness: Bool = true
    public var showResolutionSlider: Bool = true
    public var showContrastSlider: Bool = true
    public var showVolumeSlider: Bool = true
    public var showQuitButton: Bool = true
    public var singleExpandedSection: Bool = true
    public var alwaysShowDeviceHeader: Bool = false
    public var hideLowResolutions: Bool = true
    public var fadeOnModeChange: Bool = true
    public var showMenuBarIconBadge: Bool = false
    // Application
    public var preventSleep: Bool = false
    public var reconnectDisplaysOnQuit: Bool = true
    // Settings window
    public var showHelp: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        showOSD = v(.showOSD, d.showOSD)
        osdDuration = v(.osdDuration, d.osdDuration)
        brightnessStep = v(.brightnessStep, d.brightnessStep)
        handleBrightnessKeys = v(.handleBrightnessKeys, d.handleBrightnessKeys)
        menuBarShowsPercentage = v(.menuBarShowsPercentage, d.menuBarShowsPercentage)
        restoreConfigurationOnLaunch = v(.restoreConfigurationOnLaunch, d.restoreConfigurationOnLaunch)
        softwareDimmingEnabled = v(.softwareDimmingEnabled, d.softwareDimmingEnabled)
        showResolutionPicker = v(.showResolutionPicker, d.showResolutionPicker)
        combinedBrightness = v(.combinedBrightness, d.combinedBrightness)
        showResolutionSlider = v(.showResolutionSlider, d.showResolutionSlider)
        showContrastSlider = v(.showContrastSlider, d.showContrastSlider)
        showVolumeSlider = v(.showVolumeSlider, d.showVolumeSlider)
        showQuitButton = v(.showQuitButton, d.showQuitButton)
        singleExpandedSection = v(.singleExpandedSection, d.singleExpandedSection)
        alwaysShowDeviceHeader = v(.alwaysShowDeviceHeader, d.alwaysShowDeviceHeader)
        hideLowResolutions = v(.hideLowResolutions, d.hideLowResolutions)
        fadeOnModeChange = v(.fadeOnModeChange, d.fadeOnModeChange)
        showMenuBarIconBadge = v(.showMenuBarIconBadge, d.showMenuBarIconBadge)
        preventSleep = v(.preventSleep, d.preventSleep)
        reconnectDisplaysOnQuit = v(.reconnectDisplaysOnQuit, d.reconnectDisplaysOnQuit)
        showHelp = v(.showHelp, d.showHelp)
    }
}

/// Per-display preferences from the display's settings page.
public struct DisplayPreferences: Codable, Equatable {
    public var showInMenu: Bool = true
    public var keyboardControl: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showInMenu = (try? c.decodeIfPresent(Bool.self, forKey: .showInMenu)) ?? true
        keyboardControl = (try? c.decodeIfPresent(Bool.self, forKey: .keyboardControl)) ?? true
    }
}

/// A display that was logically disconnected by the app during this login session.
public struct DisconnectedDisplay: Codable, Identifiable, Equatable {
    public var id: CGDirectDisplayID
    public var name: String
    public var identity: String

    public init(id: CGDirectDisplayID, name: String, identity: String) {
        self.id = id
        self.name = name
        self.identity = identity
    }
}

public struct VirtualScreenConfiguration: Codable, Identifiable, Equatable {
    public var id: UUID = UUID()
    public var name: String = "Virtual Screen"
    /// Default (and largest preferred) logical size.
    public var width: Int = 1920
    public var height: Int = 1080
    public var refreshRate: Double = 60
    public var millimeterWidth: Double = 600
    public var millimeterHeight: Double = 340
    public var hiDPI: Bool = true
    public var autoStart: Bool = false
    public var mirrorTargetIdentity: String? = nil
    /// Publish a full ladder of sizes for the aspect ratio (flexible scaling).
    public var flexibleModes: Bool = true
    /// Displays this virtual screen belongs to (by display identity).
    public var associatedDisplayIdentities: [String] = []
    /// Auto-connect: connect while an associated display is online and
    /// disconnect when none is.
    public var connectWithAssociated: Bool = true
    /// Auto-connect when all associated displays are offline (and disconnect
    /// when one comes online), e.g. a fallback screen for a KVM switch.
    public var connectWhenAssociatedOffline: Bool = false
    /// Enforce mirroring of the virtual screen onto an associated display.
    public var enforceMirroring: Bool = false
    /// Auto-start full screen streaming onto an associated display.
    public var autoStream: Bool = false
    /// Rotate with the associated display (portrait ↔ landscape).
    public var followOrientation: Bool = false
    /// Size the virtual screen to the associated display's aspect ratio.
    public var matchAssociatedAspect: Bool = false

    /// The first associated display (convenience for single associations).
    public var associatedDisplayIdentity: String? {
        get { associatedDisplayIdentities.first }
        set { associatedDisplayIdentities = newValue.map { [$0] } ?? [] }
    }

    public var streamToAssociated: Bool {
        get { autoStream }
        set { autoStream = newValue }
    }

    public var isAssociated: Bool { !associatedDisplayIdentities.isEmpty }

    /// True when an association rule connects and disconnects this screen. A
    /// manual connect or disconnect would be undone by the rule moments later.
    public var connectionFollowsAssociation: Bool {
        isAssociated && (connectWithAssociated || connectWhenAssociatedOffline)
    }

    private enum LegacyKeys: String, CodingKey {
        case associatedDisplayIdentity, streamToAssociated, associatedAction
    }
    /// Allows framebuffers up to 16K × 16K (8K × 8K HiDPI) instead of 8K.
    public var allowOver8K: Bool = false

    public init() {}

    public var pixelDescription: String {
        "\(width) × \(height)\(hiDPI ? " HiDPI" : "")"
    }

    public var aspectDescription: String { ModeInfo.aspectLabel(width: width, height: height) }

    /// Stable per-screen serial number, so each virtual screen has its own
    /// display identity (saved settings, associations, streams).
    public var serialNumber: UInt32 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        let value = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return max(2, value & 0x7FFF_FFFF)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VirtualScreenConfiguration()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = v(.id, d.id)
        name = v(.name, d.name)
        width = v(.width, d.width)
        height = v(.height, d.height)
        refreshRate = v(.refreshRate, d.refreshRate)
        millimeterWidth = v(.millimeterWidth, d.millimeterWidth)
        millimeterHeight = v(.millimeterHeight, d.millimeterHeight)
        hiDPI = v(.hiDPI, d.hiDPI)
        autoStart = v(.autoStart, d.autoStart)
        mirrorTargetIdentity = try? c.decodeIfPresent(String.self, forKey: .mirrorTargetIdentity)
        flexibleModes = v(.flexibleModes, d.flexibleModes)
        connectWithAssociated = v(.connectWithAssociated, d.connectWithAssociated)
        connectWhenAssociatedOffline = v(.connectWhenAssociatedOffline, d.connectWhenAssociatedOffline)
        enforceMirroring = v(.enforceMirroring, d.enforceMirroring)
        autoStream = v(.autoStream, d.autoStream)
        followOrientation = v(.followOrientation, d.followOrientation)
        matchAssociatedAspect = v(.matchAssociatedAspect, d.matchAssociatedAspect)
        associatedDisplayIdentities = v(.associatedDisplayIdentities, d.associatedDisplayIdentities)
        // Earlier versions stored one association and a stream flag.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if associatedDisplayIdentities.isEmpty,
           let single = try? legacy.decodeIfPresent(String.self, forKey: .associatedDisplayIdentity) {
            associatedDisplayIdentities = [single]
        }
        if (try? legacy.decodeIfPresent(Bool.self, forKey: .streamToAssociated)) == true { autoStream = true }
        switch try? legacy.decodeIfPresent(String.self, forKey: .associatedAction) {
        case "mirror": enforceMirroring = true
        case "stream": autoStream = true
        default: break
        }
        allowOver8K = v(.allowOver8K, d.allowOver8K)
    }
}

/// How a stream is drawn on its target display.
public struct StreamConfiguration: Codable, Identifiable, Equatable {
    public enum Scaling: String, Codable, CaseIterable { case fit, pixelPerfect, integer, fill }
    public enum VerticalAlignment: String, Codable, CaseIterable { case top, center, bottom }
    public enum HorizontalAlignment: String, Codable, CaseIterable { case left, center, right }
    public enum VideoFilter: String, Codable, CaseIterable {
        case none, monochrome, invert, sepia, thermal, xray, comic
        public var title: String {
            switch self {
            case .none: return "None"
            case .monochrome: return "Monochrome"
            case .invert: return "Invert Colors"
            case .sepia: return "Sepia"
            case .thermal: return "Thermal"
            case .xray: return "X-Ray"
            case .comic: return "Comic Effect"
            }
        }
    }

    public var id: UUID = UUID()
    public var sourceIdentity: String
    /// Same as the source for a self-stream.
    public var targetIdentity: String
    public var resumeOnConnect: Bool = false
    /// The pointer moves onto the source display when it enters the stream,
    /// so the stream works like the screen itself (clicks, typing, menus).
    public var interactive: Bool = true
    public var showCursor: Bool = true
    public var scaling: Scaling = .fit
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false
    /// 0, 90, 180 or 270 degrees, clockwise.
    public var rotation: Int = 0
    public var vertical: VerticalAlignment = .center
    public var horizontal: HorizontalAlignment = .center
    /// 1…4.
    public var zoom: Double = 1
    /// 0.5…1: shrinks the picture inside the target.
    public var underscan: Double = 1
    /// 0.1…1: window opacity.
    public var alpha: Double = 1
    /// Frames per second; 0 = as fast as the source updates.
    public var targetFPS: Int = 0
    public var filter: VideoFilter = .none
    public var cropEnabled: Bool = false
    /// Fractions of the source cut from each edge (0…0.45).
    public var cropTop: Double = 0
    public var cropBottom: Double = 0
    public var cropLeft: Double = 0
    public var cropRight: Double = 0

    public init(sourceIdentity: String, targetIdentity: String) {
        self.sourceIdentity = sourceIdentity
        self.targetIdentity = targetIdentity
    }

    public var isSelfStream: Bool { sourceIdentity == targetIdentity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceIdentity = try c.decode(String.self, forKey: .sourceIdentity)
        targetIdentity = try c.decode(String.self, forKey: .targetIdentity)
        var d = StreamConfiguration(sourceIdentity: sourceIdentity, targetIdentity: targetIdentity)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        d.id = v(.id, d.id)
        d.resumeOnConnect = v(.resumeOnConnect, d.resumeOnConnect)
        d.interactive = v(.interactive, d.interactive)
        d.showCursor = v(.showCursor, d.showCursor)
        d.scaling = v(.scaling, d.scaling)
        d.flipHorizontal = v(.flipHorizontal, d.flipHorizontal)
        d.flipVertical = v(.flipVertical, d.flipVertical)
        d.rotation = v(.rotation, d.rotation)
        d.vertical = v(.vertical, d.vertical)
        d.horizontal = v(.horizontal, d.horizontal)
        d.zoom = v(.zoom, d.zoom)
        d.underscan = v(.underscan, d.underscan)
        d.alpha = v(.alpha, d.alpha)
        d.targetFPS = v(.targetFPS, d.targetFPS)
        d.filter = v(.filter, d.filter)
        d.cropEnabled = v(.cropEnabled, d.cropEnabled)
        d.cropTop = v(.cropTop, d.cropTop)
        d.cropBottom = v(.cropBottom, d.cropBottom)
        d.cropLeft = v(.cropLeft, d.cropLeft)
        d.cropRight = v(.cropRight, d.cropRight)
        self = d
    }
}

public struct PersistedState: Codable {
    public var general = GeneralSettings()
    public var virtualScreens: [VirtualScreenConfiguration] = []
    public var perDisplay: [String: DisplayConfiguration] = [:]
    public var brightnessByDisplay: [String: Double] = [:]
    public var imageAdjustments: [String: ImageAdjustments] = [:]
    public var disconnectedDisplays: [DisconnectedDisplay] = []
    public var displayPreferences: [String: DisplayPreferences] = [:]
    /// One stream configuration per source display.
    public var streams: [StreamConfiguration] = []
    /// Last known name of every display seen, by identity (for listing
    /// displays that are currently disconnected).
    public var knownDisplayNames: [String: String] = [:]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = (try? c.decodeIfPresent(GeneralSettings.self, forKey: .general)) ?? GeneralSettings()
        virtualScreens = (try? c.decodeIfPresent([VirtualScreenConfiguration].self, forKey: .virtualScreens)) ?? []
        perDisplay = (try? c.decodeIfPresent([String: DisplayConfiguration].self, forKey: .perDisplay)) ?? [:]
        brightnessByDisplay = (try? c.decodeIfPresent([String: Double].self, forKey: .brightnessByDisplay)) ?? [:]
        imageAdjustments = (try? c.decodeIfPresent([String: ImageAdjustments].self, forKey: .imageAdjustments)) ?? [:]
        disconnectedDisplays = (try? c.decodeIfPresent([DisconnectedDisplay].self, forKey: .disconnectedDisplays)) ?? []
        displayPreferences = (try? c.decodeIfPresent([String: DisplayPreferences].self, forKey: .displayPreferences)) ?? [:]
        streams = (try? c.decodeIfPresent([StreamConfiguration].self, forKey: .streams)) ?? []
        knownDisplayNames = (try? c.decodeIfPresent([String: String].self, forKey: .knownDisplayNames)) ?? [:]
    }
}

/// Small JSON-backed settings store.
@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var state: PersistedState {
        didSet { scheduleSave() }
    }

    private let defaultsKey = "greatdisplay.state.v1"
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
    }

    /// Off for development snapshots, so temporary state is never written.
    public var persistenceEnabled = true

    private func scheduleSave() {
        guard persistenceEnabled else { return }
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            // Checked again when the save runs: persistence may have been
            // switched off after this save was scheduled.
            guard let self, self.persistenceEnabled else { return }
            if let data = try? JSONEncoder().encode(self.state) {
                UserDefaults.standard.set(data, forKey: self.defaultsKey)
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    public func saveNow() {
        guard persistenceEnabled else { return }
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    public func configuration(for identity: String) -> DisplayConfiguration? {
        state.perDisplay[identity]
    }

    public func setConfiguration(_ configuration: DisplayConfiguration) {
        state.perDisplay[configuration.identity] = configuration
    }

    public func setBrightness(_ value: Double, for identity: String) {
        state.brightnessByDisplay[identity] = value
    }

    public func brightness(for identity: String) -> Double? {
        state.brightnessByDisplay[identity]
    }

    public func preferences(for identity: String) -> DisplayPreferences {
        state.displayPreferences[identity] ?? DisplayPreferences()
    }

    public func setPreferences(_ preferences: DisplayPreferences, for identity: String) {
        state.displayPreferences[identity] = preferences == DisplayPreferences() ? nil : preferences
    }

    public func resetAll() {
        var fresh = PersistedState()
        // Not a preference: the displays are still disconnected, and this list
        // is how the app finds them again to reconnect them.
        fresh.disconnectedDisplays = state.disconnectedDisplays
        state = fresh
        saveNow()
    }
}
