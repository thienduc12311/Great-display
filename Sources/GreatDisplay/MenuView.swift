import SwiftUI
import AppKit
import GDCore

/// Expansion state that survives closing and reopening the menu.
@MainActor
final class MenuState: ObservableObject {
    static let shared = MenuState()

    enum Feature: String {
        case displayMode, refreshRate, rotation, mirror, stream, input, deviceControl, adjustments, manage, arrange
        case virtualScreens, systemColors
    }

    /// Device sections whose first level (brightness, resolution) is visible.
    @Published var expandedDevices: Set<String> = []
    /// Device whose "more options" are open (one at a time).
    @Published var moreOptionsDevice: String?
    /// The open feature panel, keyed by device (or "tools").
    @Published var openFeature: (owner: String, feature: Feature)?
    @Published var showTools = false
    private var initialised = false

    func prepare(with displays: [DisplayInfo]) {
        guard !initialised, !displays.isEmpty else { return }
        initialised = true
        if let main = displays.first(where: { $0.isMain }) ?? displays.first {
            expandedDevices = [main.identityKey]
        }
    }

    func toggleDevice(_ key: String) {
        if expandedDevices.contains(key) {
            expandedDevices.remove(key)
            if moreOptionsDevice == key { moreOptionsDevice = nil }
        } else {
            if SettingsStore.shared.state.general.singleExpandedSection {
                expandedDevices = [key]
                if moreOptionsDevice != key { moreOptionsDevice = nil }
            } else {
                expandedDevices.insert(key)
            }
        }
    }

    func toggleMoreOptions(_ key: String) {
        moreOptionsDevice = moreOptionsDevice == key ? nil : key
        if moreOptionsDevice == nil, openFeature?.owner == key { openFeature = nil }
    }

    func isOpen(_ owner: String, _ feature: Feature) -> Bool {
        openFeature?.owner == owner && openFeature?.feature == feature
    }

    func toggle(_ owner: String, _ feature: Feature) {
        openFeature = isOpen(owner, feature) ? nil : (owner, feature)
    }

    /// Closing the menu collapses expanded features.
    func menuDidClose() {
        openFeature = nil
    }
}

extension DisplayInfo {
    /// Stable key for UI state across reconnects (display IDs can change).
    var identityKey: String { "\(identity)-\(isVirtual ? "v" : "p")-\(id)" }
}

struct MenuView: View {
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared
    @ObservedObject private var state = MenuState.shared
    @ObservedObject private var sleep = SleepController.shared
    @ObservedObject private var updates = UpdateController.shared
    @ObservedObject private var keyboard = KeyboardController.shared
    let onOpenSettings: (SettingsPane?) -> Void

    @State private var contentHeight: CGFloat = 300

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
                content
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
                    })
            }
            .frame(height: min(contentHeight, maxHeight))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }

            Divider().padding(.horizontal, 10)
            bottomBar
        }
        .frame(width: MenuMetrics.width)
        .onAppear { state.prepare(with: controller.displays) }
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.displays.isEmpty && controller.disconnected.isEmpty {
                emptyState
            }
            let shown = controller.displays.filter { settings.preferences(for: $0.identity).showInMenu }
            let showHeaders = shown.count + controller.disconnected.count + inactiveVirtualScreens.count > 1
                || settings.state.general.alwaysShowDeviceHeader
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, display in
                if index > 0 { MenuDivider() }
                DeviceSection(display: display,
                              showHeader: showHeaders,
                              onOpenSettings: onOpenSettings)
            }
            ForEach(controller.disconnected) { entry in
                MenuDivider()
                DeviceHeader(symbol: "display", name: entry.name, subtitle: "Disconnected",
                             badges: [], isExpanded: false, isConnected: false, switchEnabled: true,
                             onToggleExpand: {}, onSwitch: { on in if on { controller.reconnect(entry.id) } })
            }
            ForEach(inactiveVirtualScreens) { configuration in
                MenuDivider()
                DeviceHeader(symbol: "rectangle.dashed", name: configuration.name,
                             subtitle: "Virtual screen · \(configuration.pixelDescription)",
                             badges: [], isExpanded: false, isConnected: false,
                             switchEnabled: virtualScreens.isSupported,
                             onToggleExpand: {}, onSwitch: { on in
                                 if on { _ = virtualScreens.create(configuration) }
                             })
            }
            if state.showTools {
                MenuDivider()
                ToolsSection(onOpenSettings: onOpenSettings)
            }
        }
        .padding(.vertical, 6)
    }

    private var inactiveVirtualScreens: [VirtualScreenConfiguration] {
        settings.state.virtualScreens.filter { !virtualScreens.isActive($0) }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No displays found").font(.callout)
            Button("Redetect Displays") { controller.redetect() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 4) {
            BarButton(symbol: "gearshape", help: "Settings (⌘,)") { onOpenSettings(nil) }
                .keyboardShortcut(",", modifiers: .command)
            if settings.state.general.handleBrightnessKeys && !keyboard.trusted {
                Button {
                    keyboard.checkTrust()
                    if !keyboard.trusted { _ = keyboard.requestAccess() }
                    onOpenSettings(.keyboard)
                } label: {
                    Label("Set Up Permissions", systemImage: "exclamationmark.shield")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            if settings.state.general.handleBrightnessKeys && keyboard.trusted && !keyboard.conflictingApps.isEmpty {
                Button {
                    onOpenSettings(.keyboard)
                } label: {
                    Label("Key conflict", systemImage: "keyboard.badge.exclamationmark")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("\(keyboard.conflictingApps.compactMap(\.localizedName).joined(separator: ", ")) is also handling the brightness keys")
            }
            if let release = updates.availableRelease {
                Button {
                    UpdateWindowController.shared.show()
                } label: {
                    Label("Update \(release.version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Great Display \(release.version) is available")
            }
            Spacer()
            if sleep.isPreventingSleep {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .help("Prevent Sleep is on")
            }
            BarButton(symbol: state.showTools ? "ellipsis.circle.fill" : "ellipsis.circle",
                      help: state.showTools ? "Hide Tools" : "Show Tools") {
                withAnimation(.easeInOut(duration: 0.16)) { state.showTools.toggle() }
            }
            if settings.state.general.showQuitButton {
                BarButton(symbol: "power", help: "Quit Great Display") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct BarButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tools

struct ToolsSection: View {
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared
    @ObservedObject private var colors = SystemColorsController.shared
    @ObservedObject private var sleep = SleepController.shared
    @ObservedObject private var state = MenuState.shared
    let onOpenSettings: (SettingsPane?) -> Void

    private let owner = "tools"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.12)).frame(width: 26, height: 26)
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("Tools").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, MenuMetrics.contentInset + 2)
            .padding(.vertical, 5)

            FeatureRow(symbol: "rectangle.on.rectangle", title: "Displays and Virtual Screens", value: nil,
                       isExpanded: state.isOpen(owner, .virtualScreens)) { state.toggle(owner, .virtualScreens) }
            if state.isOpen(owner, .virtualScreens) {
                FeaturePanel { virtualScreenPanel }
            }

            FeatureRow(symbol: "paintpalette", title: "System Colors", value: nil,
                       isExpanded: state.isOpen(owner, .systemColors)) {
                colors.refresh()
                state.toggle(owner, .systemColors)
            }
            if state.isOpen(owner, .systemColors) {
                FeaturePanel {
                    MenuRow(symbol: "moon", title: "Enable Dark Mode", checked: colors.darkMode) {
                        colors.setDarkMode(!colors.darkMode)
                    }
                    MenuRow(symbol: "sun.horizon", title: "Enable Night Shift", checked: colors.nightShift == true,
                            enabled: colors.nightShift != nil) {
                        colors.setNightShift(!(colors.nightShift ?? false))
                    }
                    MenuRow(symbol: "circle.lefthalf.striped.horizontal", title: "Enable True Tone",
                            subtitle: colors.trueTone == nil ? "Unavailable" : nil,
                            checked: colors.trueTone == true, enabled: colors.trueTone != nil) {
                        colors.setTrueTone(!(colors.trueTone ?? false))
                    }
                }
            }

            MenuRow(symbol: sleep.isPreventingSleep ? "cup.and.saucer.fill" : "cup.and.saucer",
                    title: "Prevent Sleep", checked: sleep.isPreventingSleep) {
                sleep.setPreventSleep(!sleep.isPreventingSleep)
            }
            MenuRow(symbol: "arrow.clockwise", title: "Redetect Displays") { controller.redetect() }
            MenuRow(symbol: "arrow.down.circle", title: "Check for Updates…") {
                UpdateController.shared.check()
                UpdateWindowController.shared.show()
            }
            MenuRow(symbol: "gearshape", title: "Settings…") { onOpenSettings(nil) }
        }
    }

    @ViewBuilder
    private var virtualScreenPanel: some View {
        MenuCaption(text: "Create New Virtual Screen")
        ForEach(VirtualScreenPreset.all) { preset in
            MenuRow(symbol: "plus.rectangle.on.rectangle", title: preset.name, subtitle: preset.detail,
                    enabled: virtualScreens.isSupported) {
                createVirtualScreen(preset)
            }
        }
        if !settings.state.virtualScreens.isEmpty {
            MenuCaption(text: "Virtual Screens")
            ForEach(settings.state.virtualScreens) { configuration in
                let active = virtualScreens.isActive(configuration)
                MenuRow(symbol: active ? "rectangle.inset.filled" : "rectangle.dashed",
                        title: configuration.name, subtitle: configuration.pixelDescription, checked: active) {
                    if active { virtualScreens.destroy(configuration.id) } else { _ = virtualScreens.create(configuration) }
                }
            }
        }
        MenuDivider()
        MenuRow(symbol: "bolt.horizontal", title: "Connect All Displays",
                enabled: !controller.disconnected.isEmpty) { controller.reconnectAll() }
        MenuRow(symbol: "slider.horizontal.3", title: "Manage Virtual Screens…") { onOpenSettings(.virtualScreens) }
        if let error = virtualScreens.lastError, !error.isEmpty {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
        }
    }

    private func createVirtualScreen(_ preset: VirtualScreenPreset) {
        var configuration = VirtualScreenConfiguration()
        configuration.name = "Virtual \(preset.shortName)"
        configuration.width = preset.width
        configuration.height = preset.height
        configuration.hiDPI = true
        settings.state.virtualScreens.append(configuration)
        _ = virtualScreens.create(configuration)
    }
}

struct VirtualScreenPreset: Identifiable {
    let name: String
    let shortName: String
    let width: Int
    let height: Int
    var id: String { name }
    var detail: String { "\(width) × \(height) HiDPI" }

    static let all: [VirtualScreenPreset] = [
        VirtualScreenPreset(name: "16:9 Full HD", shortName: "1080p", width: 1920, height: 1080),
        VirtualScreenPreset(name: "16:9 QHD", shortName: "1440p", width: 2560, height: 1440),
        VirtualScreenPreset(name: "16:10 WQXGA", shortName: "16:10", width: 2560, height: 1600),
        VirtualScreenPreset(name: "21:9 Ultrawide", shortName: "Ultrawide", width: 3440, height: 1440),
    ]
}
