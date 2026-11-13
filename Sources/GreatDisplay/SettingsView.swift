import SwiftUI
import AppKit
import GDCore

// Settings window: a display-first sidebar (every display is one click away,
// with a live thumbnail and status), a search field that jumps straight to a
// setting, and a detail area whose pages share one header + card language.

enum SettingsPane: Hashable {
    case displays
    case display(CGDirectDisplayID)
    case virtualScreens
    case virtualScreen(UUID)
    case application
    case menu
    case keyboard
    case about
}

/// Tabs on a display's page.
enum DisplayTab: String, CaseIterable, Hashable {
    case picture, color, monitor, options

    var title: String {
        switch self {
        case .picture: return "Picture"
        case .color: return "Color"
        case .monitor: return "Monitor"
        case .options: return "Options"
        }
    }

    var symbol: String {
        switch self {
        case .picture: return "sun.max"
        case .color: return "paintpalette"
        case .monitor: return "slider.horizontal.3"
        case .options: return "gearshape"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selection: SettingsPane? = .displays
    @Published var displayTab: DisplayTab = .picture
    @Published var search = ""

    func select(_ pane: SettingsPane) {
        selection = pane
    }

    /// Kept for callers that navigate between devices.
    func selectDevice(_ pane: SettingsPane) {
        selection = pane
    }

    /// The display a display-scoped search result should open.
    func open(tab: DisplayTab) {
        let controller = DisplayController.shared
        if case .display(let id) = selection, controller.display(id) != nil {
            // Stay on the current display.
        } else if let display = controller.displays.first(where: { $0.isMain }) ?? controller.displays.first {
            selection = .display(display.id)
        }
        displayTab = tab
    }
}

extension Notification.Name {
    /// Asks the menu bar controller to open the app menu.
    static let greatDisplayShowMenu = Notification.Name("GreatDisplayShowMenu")
}

enum DisplayGlyph {
    static func symbol(for display: DisplayInfo) -> String {
        if display.isBuiltIn { return "laptopcomputer" }
        if display.isVirtual { return "rectangle.dashed" }
        if display.name.localizedCaseInsensitiveContains("displaylink") { return "rectangle.on.rectangle.angled" }
        return "display"
    }
}

// MARK: - Window layout

struct SettingsView: View {
    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 240)
            Divider()
            SettingsDetail()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(SettingsStyle.contentBackground)
        }
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 600)
    }
}

struct SettingsDetail: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared

    var body: some View {
        let pane = navigation.selection ?? .displays
        page(pane).id(pane)
    }

    @ViewBuilder
    private func page(_ pane: SettingsPane) -> some View {
        switch pane {
        case .displays:
            DisplaysOverviewPage()
        case .display(let id):
            if let screen = virtualScreens.active.first(where: { $0.displayID == id }) {
                VirtualScreenDetailPage(configurationID: screen.id)
            } else if let display = controller.display(id) {
                DisplayDetailPage(display: display)
            } else if let entry = controller.disconnected.first(where: { $0.id == id }) {
                DisconnectedDisplayPage(entry: entry)
            } else {
                DisplaysOverviewPage()
            }
        case .virtualScreens:
            VirtualScreensPage()
        case .virtualScreen(let id):
            VirtualScreenDetailPage(configurationID: id)
        case .application:
            GeneralSettingsView()
        case .menu:
            MenuSettingsView()
        case .keyboard:
            KeyboardSettingsView()
        case .about:
            AboutView()
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @ObservedObject private var navigation = SettingsNavigation.shared
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared
    @ObservedObject private var keyboard = KeyboardController.shared
    @State private var creating = false

    private var selection: SettingsPane { navigation.selection ?? .displays }

    private var physicalDisplays: [DisplayInfo] {
        controller.displays.filter { display in
            !virtualScreens.active.contains { $0.displayID == display.id }
        }
    }

    private var keyboardNeedsAttention: Bool {
        (store.state.general.handleBrightnessKeys && !keyboard.trusted) || !keyboard.conflictingApps.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 46)   // traffic lights
            SidebarSearchField(text: $navigation.search)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if navigation.search.trimmingCharacters(in: .whitespaces).isEmpty {
                        navigationList
                    } else {
                        SettingsSearchResults(query: navigation.search)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            Divider().opacity(0.6)
            footer
        }
        .frame(maxHeight: .infinity)
        .background(VisualEffectBackground(material: .sidebar))
        .sheet(isPresented: $creating) { NewVirtualScreenSheet() }
    }

    @ViewBuilder
    private var navigationList: some View {
        SidebarRow(title: "All Displays",
                   subtitle: "\(controller.displays.count) connected",
                   selected: selection == .displays,
                   action: { navigation.select(.displays) }) {
            IconTile(symbol: "rectangle.3.group", tint: .blue, size: 24)
        }

        SidebarHeader(title: "Displays")
        ForEach(physicalDisplays) { display in
            let selected = selection == .display(display.id)
            SidebarRow(title: display.name,
                       subtitle: modeSummary(display),
                       selected: selected,
                       badge: display.isMain ? "Main" : nil,
                       action: { navigation.select(.display(display.id)) }) {
                ScreenThumbnail(aspect: display.aspect, selected: selected, isMain: display.isMain)
            }
        }
        ForEach(controller.disconnected) { entry in
            SidebarRow(title: entry.name, subtitle: "Disconnected",
                       selected: selection == .display(entry.id),
                       action: { navigation.select(.display(entry.id)) }) {
                ScreenThumbnail(aspect: 16.0 / 9, dimmed: true)
            }
        }

        SidebarHeader(title: "Virtual Screens") {
            Button { creating = true } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Virtual Screen…")
            .disabled(!virtualScreens.isSupported)
        }
        ForEach(store.state.virtualScreens) { configuration in
            let selected = isSelected(configuration)
            let active = virtualScreens.isActive(configuration)
            SidebarRow(title: configuration.name,
                       subtitle: active ? "On · \(configuration.aspectDescription)" : "Off · \(configuration.aspectDescription)",
                       selected: selected,
                       action: { navigation.select(.virtualScreen(configuration.id)) }) {
                ScreenThumbnail(aspect: CGFloat(configuration.width) / CGFloat(max(1, configuration.height)),
                                selected: selected, dimmed: !active, dashed: true)
            }
        }
        if store.state.virtualScreens.isEmpty {
            SidebarRow(title: "New Virtual Screen…", subtitle: nil, selected: false,
                       action: { creating = true }) {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 22)
            }
            .disabled(!virtualScreens.isSupported)
        }

        SidebarHeader(title: "Preferences")
        SidebarRow(title: "General", subtitle: nil, selected: selection == .application,
                   action: { navigation.select(.application) }) {
            IconTile(symbol: "gearshape.fill", tint: .gray, size: 24)
        }
        SidebarRow(title: "Menu Bar", subtitle: nil, selected: selection == .menu,
                   action: { navigation.select(.menu) }) {
            IconTile(symbol: "menubar.rectangle", tint: .teal, size: 24)
        }
        SidebarRow(title: "Keyboard & OSD", subtitle: nil, selected: selection == .keyboard,
                   attention: keyboardNeedsAttention,
                   action: { navigation.select(.keyboard) }) {
            IconTile(symbol: "keyboard.fill", tint: .indigo, size: 24)
        }
        SidebarRow(title: "About", subtitle: nil, selected: selection == .about,
                   action: { navigation.select(.about) }) {
            IconTile(symbol: "info", tint: .secondary, size: 24)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NotificationCenter.default.post(name: .greatDisplayShowMenu, object: nil)
            } label: {
                Label("Open Menu", systemImage: "menubar.arrow.up.rectangle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Button { controller.redetect() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Redetect displays")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func isSelected(_ configuration: VirtualScreenConfiguration) -> Bool {
        if selection == .virtualScreen(configuration.id) { return true }
        if case .display(let id) = selection, virtualScreens.displayID(for: configuration) == id { return true }
        return false
    }

    private func modeSummary(_ display: DisplayInfo) -> String {
        guard let mode = controller.effectiveMode(for: display) else { return "No active mode" }
        return "\(mode.width)×\(mode.height) · \(mode.refreshText)"
    }
}

private struct SidebarHeader<Accessory: View>: View {
    var title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 3)
    }
}

extension SidebarHeader where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

struct SidebarRow<Icon: View>: View {
    var title: String
    var subtitle: String?
    var selected: Bool
    var badge: String? = nil
    var attention: Bool = false
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if attention {
                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                        .help("Needs attention")
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((selected ? Color.accentColor : Color.secondary).opacity(0.14)))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: subtitle == nil ? 34 : 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16)
                                   : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.09 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
        )
    }
}

// MARK: - Search

private struct SettingsSearchEntry: Identifiable {
    enum Target { case pane(SettingsPane), tab(DisplayTab) }

    let title: String
    let location: String
    let keywords: String
    let symbol: String
    let target: Target
    var id: String { location + title }

    static let all: [SettingsSearchEntry] = {
        func tab(_ tab: DisplayTab, _ title: String, _ keywords: String) -> SettingsSearchEntry {
            SettingsSearchEntry(title: title, location: "Display › \(tab.title)", keywords: keywords,
                                symbol: tab.symbol, target: .tab(tab))
        }
        func pane(_ pane: SettingsPane, _ location: String, _ symbol: String, _ title: String, _ keywords: String) -> SettingsSearchEntry {
            SettingsSearchEntry(title: title, location: location, keywords: keywords, symbol: symbol, target: .pane(pane))
        }
        return [
            tab(.picture, "Brightness", "backlight dim dimming light dark"),
            tab(.picture, "Resolution", "display mode size scale scaled larger text more space"),
            tab(.picture, "Refresh rate", "hz frequency 120 144 60"),
            tab(.picture, "HiDPI", "retina sharp density"),
            tab(.picture, "Rotation", "portrait orientation rotate"),
            tab(.picture, "High Dynamic Range", "hdr"),
            tab(.color, "Color presets", "warm cool evening night reading"),
            tab(.color, "Gamma", "tone curve midtones"),
            tab(.color, "Color temperature", "warm cool white point night"),
            tab(.color, "Contrast (software)", "contrast"),
            tab(.color, "Color balance", "red green blue gain rgb tint"),
            tab(.color, "Invert colors", "negative"),
            tab(.monitor, "DDC/CI control", "ddc hardware monitor mccs vcp"),
            tab(.monitor, "Input source", "hdmi displayport usb-c input switch"),
            tab(.monitor, "Volume", "speakers audio mute sound"),
            tab(.monitor, "Picture mode", "preset game movie"),
            tab(.monitor, "Sharpness", "sharp"),
            tab(.monitor, "Standby", "power off sleep monitor"),
            tab(.options, "Show in the app menu", "hide menu"),
            tab(.options, "Main display", "primary menu bar dock"),
            tab(.options, "Arrangement", "move left right above below position"),
            tab(.options, "Disconnect display", "turn off disable remove connect"),
            tab(.options, "Display information", "serial vendor model id"),
            pane(.virtualScreens, "Virtual Screens", "rectangle.dashed", "Virtual screens", "virtual dummy headless stream mirror"),
            pane(.application, "General", "gearshape", "Launch at login", "startup login start"),
            pane(.application, "General", "gearshape", "Restore configuration on launch", "restore saved"),
            pane(.application, "General", "gearshape", "Prevent sleep", "awake caffeinate"),
            pane(.application, "General", "gearshape", "Reconnect displays when quitting", "quit reconnect"),
            pane(.application, "General", "gearshape", "Brightness method", "color table software combined dimming"),
            pane(.application, "General", "gearshape", "Screen Recording permission", "stream privacy capture"),
            pane(.application, "General", "gearshape", "Show explanations", "help descriptions"),
            pane(.application, "General", "gearshape", "Diagnostics", "ddc displayservices status"),
            pane(.application, "General", "gearshape", "Reset all saved settings", "erase clear defaults"),
            pane(.menu, "Menu Bar", "menubar.rectangle", "Menu sliders", "resolution contrast volume slider"),
            pane(.menu, "Menu Bar", "menubar.rectangle", "Quit button", "quit"),
            pane(.menu, "Menu Bar", "menubar.rectangle", "Brightness percentage in menu bar", "percent icon"),
            pane(.menu, "Menu Bar", "menubar.rectangle", "Hide low resolutions", "720"),
            pane(.menu, "Menu Bar", "menubar.rectangle", "Fade when changing resolution", "fade transition"),
            pane(.keyboard, "Keyboard & OSD", "keyboard", "Brightness keys", "f1 f2 f14 f15 media keys"),
            pane(.keyboard, "Keyboard & OSD", "keyboard", "Accessibility permission", "privacy trust"),
            pane(.keyboard, "Keyboard & OSD", "keyboard", "Brightness step", "steps increment"),
            pane(.keyboard, "Keyboard & OSD", "keyboard", "On-screen display", "osd hud feedback overlay"),
            pane(.about, "About", "info.circle", "Version", "about update release"),
        ]
    }()

    func matches(_ words: [String]) -> Bool {
        let haystack = (title + " " + keywords + " " + location).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

private struct SettingsSearchResults: View {
    let query: String
    @ObservedObject private var navigation = SettingsNavigation.shared

    private var results: [SettingsSearchEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return SettingsSearchEntry.all.filter { $0.matches(words) }
    }

    var body: some View {
        SidebarHeader(title: results.isEmpty ? "No Results" : "Results")
        if results.isEmpty {
            Text("Try “brightness”, “HDR”, “input” or “login”.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        ForEach(results) { entry in
            SidebarRow(title: entry.title, subtitle: entry.location, selected: false,
                       action: { open(entry) }) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
            }
        }
    }

    private func open(_ entry: SettingsSearchEntry) {
        switch entry.target {
        case .pane(let pane): navigation.select(pane)
        case .tab(let tab): navigation.open(tab: tab)
        }
        navigation.search = ""
    }
}
