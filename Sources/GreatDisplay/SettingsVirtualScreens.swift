import SwiftUI
import AppKit
import GDCore

/// Common aspect ratios offered when creating a virtual screen. The size is the
/// default logical (HiDPI) desktop; the flexible mode list spans around it.
struct AspectPreset: Identifiable, Hashable {
    let title: String
    let ratioWidth: Int
    let ratioHeight: Int
    let width: Int
    let height: Int
    var id: String { title }
    var symbol: String { ratioWidth < ratioHeight ? "rectangle.portrait" : "rectangle" }

    static let all: [AspectPreset] = [
        AspectPreset(title: "16:9 – HD/4K/5K/6K", ratioWidth: 16, ratioHeight: 9, width: 2560, height: 1440),
        AspectPreset(title: "16:10 – WXGA/WQXGA", ratioWidth: 16, ratioHeight: 10, width: 2560, height: 1600),
        AspectPreset(title: "21:9 – Ultrawide", ratioWidth: 21, ratioHeight: 9, width: 3440, height: 1440),
        AspectPreset(title: "32:9 – Super Ultrawide", ratioWidth: 32, ratioHeight: 9, width: 5120, height: 1440),
        AspectPreset(title: "3:2 – Laptop/Tablet", ratioWidth: 3, ratioHeight: 2, width: 2400, height: 1600),
        AspectPreset(title: "4:3 – XGA/QXGA", ratioWidth: 4, ratioHeight: 3, width: 2048, height: 1536),
        AspectPreset(title: "1:1 – Square", ratioWidth: 1, ratioHeight: 1, width: 1920, height: 1920),
        AspectPreset(title: "9:16 – Portrait", ratioWidth: 9, ratioHeight: 16, width: 1440, height: 2560),
        AspectPreset(title: "10:16 – Portrait", ratioWidth: 10, ratioHeight: 16, width: 1600, height: 2560),
    ]
}

// MARK: - Overview of virtual screens

struct VirtualScreensOverview: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var manager = VirtualScreenManager.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var creating = false

    var body: some View {
        SettingsCard {
            SettingsIconHeader(symbol: "plus.rectangle.on.rectangle", title: "Virtual Screens",
                               subtitle: manager.isSupported ? "\(store.state.virtualScreens.count) configured" : "Unavailable on this system")
            SettingsHelpText(text: "A virtual screen is similar to a real display but exists only in the computer's memory. Stream or mirror its content to a real display, or use it as a source for screen recording.")
            ForEach(store.state.virtualScreens) { configuration in
                SettingsRowDivider()
                Button { navigation.selectDevice(.virtualScreen(configuration.id)) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.dashed")
                            .font(.system(size: 20))
                            .foregroundStyle(manager.isActive(configuration) ? Color.accentColor : Color.secondary)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(configuration.name).font(.system(size: 13, weight: .medium))
                            Text("\(configuration.aspectDescription) · \(configuration.pixelDescription) · \(manager.isActive(configuration) ? "Connected" : "Disconnected")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            SettingsRowDivider()
            SettingsButtonRow {
                Button("Create New Virtual Screen…") { creating = true }
                    .disabled(!manager.isSupported)
            }
        }
        .sheet(isPresented: $creating) { NewVirtualScreenSheet() }
    }
}

// MARK: - Creation sheet

struct NewVirtualScreenSheet: View {
    enum Kind { case preset, associated, custom }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var kind: Kind = .preset
    @State private var preset = AspectPreset.all[0]
    @State private var associatedIdentity = ""
    @State private var customWidth = "16"
    @State private var customHeight = "9"

    private var physical: [DisplayInfo] { controller.displays.filter { !$0.isVirtual } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsIconHeader(symbol: "plus.rectangle.on.rectangle", title: "Creating a virtual screen")
                Text("A virtual screen is similar to a real display but exists only in virtual space (in the computer's memory). You can stream or mirror its content to a real display, or use it as a source for screen recording or screencasts.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsStyle.rowInset)
                    .padding(.bottom, 10)
            }
            Text("New Virtual Screen Configuration").font(.system(size: 14, weight: .bold)).padding(.leading, 6)
            SettingsCard {
                option(.preset, "Pre-configured settings (recommended)",
                       "Select a common aspect ratio for the virtual screen. The app creates a flexible resolution list based on this.") {
                    Picker("", selection: $preset) {
                        ForEach(AspectPreset.all) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRowDivider()
                option(.associated, "Match aspect ratio of and associate to a display",
                       "Create a virtual screen that matches the aspect ratio of another display and associate the virtual screen with it. Best when the virtual screen should be streamed or mirrored to that display.") {
                    Picker("", selection: $associatedIdentity) {
                        ForEach(physical) { Text($0.name).tag($0.identity) }
                    }
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRowDivider()
                option(.custom, "Custom aspect ratio",
                       "Create a virtual screen with a custom aspect ratio. Size and aspect ratio can be changed later on the virtual screen's page.") {
                    HStack {
                        TextField("", text: $customWidth).frame(width: 60).multilineTextAlignment(.trailing)
                        Text("×")
                        TextField("", text: $customHeight).frame(width: 60).multilineTextAlignment(.trailing)
                    }
                }
            }
            Text("Note: Additional configuration options are available on the created virtual screen's settings page.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Virtual Screen") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 640)
        .onAppear { associatedIdentity = physical.first?.identity ?? "" }
    }

    private var canCreate: Bool {
        switch kind {
        case .preset: return true
        case .associated: return !associatedIdentity.isEmpty
        case .custom: return (Int(customWidth) ?? 0) > 0 && (Int(customHeight) ?? 0) > 0
        }
    }

    private func option<Accessory: View>(_ value: Kind, _ title: String, _ help: String,
                                         @ViewBuilder accessory: () -> Accessory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { kind = value } label: {
                HStack(spacing: 10) {
                    Image(systemName: kind == value ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(kind == value ? Color.accentColor : Color.secondary)
                    Text(title).font(.system(size: 13.5))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(help)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 28)
            HStack { Spacer(); accessory() }
                .disabled(kind != value)
                .opacity(kind == value ? 1 : 0.5)
        }
        .padding(.horizontal, SettingsStyle.rowInset)
        .padding(.vertical, 10)
    }

    private func create() {
        var configuration = VirtualScreenConfiguration()
        configuration.hiDPI = true
        switch kind {
        case .preset:
            configuration.width = preset.width
            configuration.height = preset.height
            configuration.name = "Virtual \(preset.ratioWidth):\(preset.ratioHeight)"
        case .associated:
            guard let display = physical.first(where: { $0.identity == associatedIdentity }) else { return }
            // Same shape as the display on screen (portrait when rotated).
            configuration.width = Int(display.bounds.width)
            configuration.height = Int(display.bounds.height)
            configuration.name = "Virtual for \(display.name)"
            configuration.associatedDisplayIdentity = display.identity
            configuration.connectWithAssociated = true
        case .custom:
            let ratioW = max(1, Int(customWidth) ?? 16), ratioH = max(1, Int(customHeight) ?? 9)
            let longSide = 2560
            if ratioW >= ratioH {
                configuration.width = longSide
                configuration.height = Int((Double(longSide) * Double(ratioH) / Double(ratioW) / 2).rounded()) * 2
            } else {
                configuration.height = longSide
                configuration.width = Int((Double(longSide) * Double(ratioW) / Double(ratioH) / 2).rounded()) * 2
            }
            configuration.name = "Virtual \(ratioW):\(ratioH)"
        }
        // Save what will actually be created (an extreme ratio or a size
        // over the pixel ceiling is brought within bounds).
        configuration = VirtualScreenManager.fitted(configuration)
        store.state.virtualScreens.append(configuration)
        _ = VirtualScreenManager.shared.create(configuration)
        SettingsNavigation.shared.selectDevice(.virtualScreen(configuration.id))
        dismiss()
    }
}

// MARK: - One virtual screen

struct VirtualScreenPage: View {
    let configurationID: UUID
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var manager = VirtualScreenManager.shared
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var streams = FullScreenStreamController.shared
    @State private var ratioWidth = ""
    @State private var ratioHeight = ""
    @State private var showInformation = false

    private var configuration: VirtualScreenConfiguration? {
        store.state.virtualScreens.first { $0.id == configurationID }
    }

    private var display: DisplayInfo? {
        manager.displayID(for: configuration ?? VirtualScreenConfiguration()).flatMap { controller.display($0) }
    }

    var body: some View {
        if let configuration {
            content(configuration)
        } else {
            VirtualScreensOverview()
        }
    }

    @ViewBuilder
    private func content(_ configuration: VirtualScreenConfiguration) -> some View {
        let active = manager.isActive(configuration)

        SettingsCard {
            SettingsIconHeader(symbol: "power", title: "Connect this virtual screen", tint: .red) {
                Toggle("", isOn: Binding(get: { manager.isActive(configuration) },
                                         set: { on in
                                             if on { _ = manager.create(configuration) } else { manager.destroy(configuration.id) }
                                         }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    // The association rule would undo a manual change at once.
                    .disabled(configuration.connectionFollowsAssociation)
            }
            SettingsHelpText(text: configuration.connectionFollowsAssociation
                ? "This screen connects and disconnects with its associated display. Change that under Associated Displays to connect it by hand."
                : "Virtual screens can be connected and disconnected at any time. Size and aspect ratio changes apply while connected; the over-8K option reconnects the screen.")
            SettingsRowDivider()
            SettingsRow(title: "Virtual screen name") {
                TextField("", text: binding(\.name)).frame(width: 240).multilineTextAlignment(.trailing)
            }
            SettingsRowDivider()
            SettingsButtonRow {
                Button("Identify Visually") { if let display { controller.identify(display) } }
                    .disabled(display == nil)
                Button("Discard…") { discard(configuration) }
                Button("Display Information…") { showInformation = true }
                    .disabled(display == nil)
            }
        }

        SettingsSectionTitle(title: "Virtual Screen Configuration")
        SettingsCard {
            SettingsIconHeader(symbol: "aspectratio", title: "Aspect ratio") {
                HStack(spacing: 6) {
                    TextField("", text: $ratioWidth).frame(width: 60).multilineTextAlignment(.trailing)
                        .onSubmit { applyRatio(configuration) }
                    Text("×").foregroundStyle(.secondary)
                    TextField("", text: $ratioHeight).frame(width: 60).multilineTextAlignment(.trailing)
                        .onSubmit { applyRatio(configuration) }
                    Menu {
                        ForEach(AspectPreset.all) { preset in
                            Button(preset.title) {
                                ratioWidth = "\(preset.ratioWidth)"; ratioHeight = "\(preset.ratioHeight)"
                                applyRatio(configuration)
                            }
                        }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 28)
                        .help("Common aspect ratios")
                }
            }
            SettingsRowDivider()
            SettingsRow(title: "Default resolution",
                        help: "The desktop size the screen starts at. With the flexible list on, every size in this aspect ratio up to 1.5× is available in the menu's resolution slider and Display Mode list.") {
                HStack(spacing: 6) {
                    Stepper("\(String(configuration.width)) × \(String(configuration.height))", onIncrement: { scale(configuration, by: 1.1) },
                            onDecrement: { scale(configuration, by: 1 / 1.1) })
                }
            }
            SettingsRowDivider()
            SettingsToggleRow(title: "Flexible resolution list",
                              help: "Creates resolutions that match the virtual screen's aspect ratio. Off publishes only the default resolution.",
                              isOn: liveBinding(\.flexibleModes))
            SettingsRowDivider()
            SettingsToggleRow(title: "Enable resolutions over 8K (4K HiDPI)",
                              help: "Allows resolutions up to 16K × 16K (8K × 8K HiDPI). Very large virtual screens use a lot of memory and may be unstable.",
                              isOn: liveBinding(\.allowOver8K))
            SettingsRowDivider()
            SettingsToggleRow(title: "HiDPI", help: "Renders the desktop at twice the pixel density for sharp text.",
                              isOn: liveBinding(\.hiDPI))
            SettingsRowDivider()
            SettingsToggleRow(title: "Rotated orientation", help: "Rotates the screen (swaps width and height).",
                              isOn: Binding(get: { configuration.height > configuration.width },
                                            set: { _ in
                                                var copy = configuration
                                                swap(&copy.width, &copy.height)
                                                apply(copy)
                                            }))
            SettingsRowDivider()
            SettingsRow(title: "Refresh rate", help: "Virtual screens work at 60 Hz by default. Higher rates are not supported on some older Macs.") {
                Picker("", selection: liveBinding(\.refreshRate)) {
                    Text("30 Hz").tag(30.0)
                    Text("60 Hz").tag(60.0)
                    Text("120 Hz").tag(120.0)
                }
                .labelsHidden()
                .frame(width: 110)
            }
            SettingsRowDivider()
            SettingsToggleRow(title: "Connect at launch", isOn: binding(\.autoStart),
                              enabled: !configuration.isAssociated || !configuration.connectWithAssociated)
        }

        if let display {
            ResolutionCardForVirtual(display: display)
        }

        AssociatedDisplaysCard(configuration: configuration,
                               virtualDisplayID: display?.id,
                               apply: { apply($0) })

        SettingsSectionTitle(title: "Mirroring and Streaming")
        SettingsCard {
            SettingsRow(title: "Mirror onto", help: "Shows the virtual screen's desktop on a physical display, which then adopts its resolution.") {
                Picker("", selection: Binding(
                    get: { configuration.mirrorTargetIdentity ?? "" },
                    set: { value in
                        var copy = configuration
                        copy.mirrorTargetIdentity = value.isEmpty ? nil : value
                        apply(copy)
                        applyMirror(copy)
                    })) {
                    Text("Off").tag("")
                    ForEach(controller.displays.filter { !$0.isVirtual }) { Text($0.name).tag($0.identity) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            if let display {
                SettingsRowDivider()
                let current = streams.stream(for: display.id)
                SettingsRow(title: "Stream to", help: "Shows the virtual screen full screen on another display, which keeps its own resolution. Pointing into the stream works like using the virtual screen directly. More options are in the app menu under Stream Virtual Screen.") {
                    Picker("", selection: Binding(
                        get: { current?.target ?? 0 },
                        set: { target in
                            if target == 0 {
                                streams.stop(source: display.id)
                            } else {
                                Task { @MainActor in _ = await streams.start(source: display.id, on: target) }
                            }
                        })) {
                        Text("Off").tag(CGDirectDisplayID(0))
                        ForEach(controller.displays.filter { $0.id != display.id }) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                if let error = streams.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, SettingsStyle.rowInset).padding(.bottom, 8)
                }
            }
        }

        Color.clear.frame(height: 2)
            .onAppear { syncRatioFields(configuration) }
            .onChange(of: configuration.id) { _, _ in syncRatioFields(configuration) }
            // Also when an association reshapes the screen underneath.
            .onChange(of: [configuration.width, configuration.height]) { _, _ in syncRatioFields(configuration) }
            .sheet(isPresented: $showInformation) {
                if let display { VirtualDisplayInformation(display: display, configuration: configuration) }
            }
    }

    // MARK: Editing

    private func binding<Value>(_ keyPath: WritableKeyPath<VirtualScreenConfiguration, Value>) -> Binding<Value> {
        Binding(get: { (configuration ?? VirtualScreenConfiguration())[keyPath: keyPath] },
                set: { value in
                    guard var copy = configuration else { return }
                    copy[keyPath: keyPath] = value
                    save(copy)
                })
    }

    /// Like `binding`, but geometry changes are applied to the live screen.
    private func liveBinding<Value>(_ keyPath: WritableKeyPath<VirtualScreenConfiguration, Value>) -> Binding<Value> {
        Binding(get: { (configuration ?? VirtualScreenConfiguration())[keyPath: keyPath] },
                set: { value in
                    guard var copy = configuration else { return }
                    copy[keyPath: keyPath] = value
                    apply(copy)
                })
    }

    private func save(_ configuration: VirtualScreenConfiguration) {
        if let index = store.state.virtualScreens.firstIndex(where: { $0.id == configuration.id }) {
            store.state.virtualScreens[index] = configuration
        }
    }

    private func apply(_ configuration: VirtualScreenConfiguration) {
        // `update` saves the configuration; fitting it first keeps the fields
        // here in step with what was saved.
        let fitted = VirtualScreenManager.fitted(configuration)
        manager.update(fitted)
        syncRatioFields(fitted)
    }

    private func syncRatioFields(_ configuration: VirtualScreenConfiguration) {
        let divisor = gcd(configuration.width, configuration.height)
        var w = configuration.width / max(1, divisor), h = configuration.height / max(1, divisor)
        // Show familiar ratios (64:27 → 21:9) when close.
        if let preset = AspectPreset.all.first(where: {
            // Marketing ratios are loose: 3440 × 1440 is sold as 21:9.
            abs(Double($0.ratioWidth) / Double($0.ratioHeight) - Double(configuration.width) / Double(configuration.height))
                < (w > 32 || h > 32 ? 0.06 : 0.012)
        }) {
            w = preset.ratioWidth; h = preset.ratioHeight
        }
        ratioWidth = "\(w)"
        ratioHeight = "\(h)"
    }

    private func applyRatio(_ configuration: VirtualScreenConfiguration) {
        // "inf" and "nan" parse as Double; neither is a ratio.
        guard let w = Double(ratioWidth), let h = Double(ratioHeight),
              w.isFinite, h.isFinite, w > 0, h > 0 else {
            syncRatioFields(configuration)
            return
        }
        // Bounded before any conversion to Int, which traps on values it
        // cannot represent.
        let limit = VirtualScreenManager.maximumAspect
        let ratio = min(max(w / h, 1 / limit), limit)   // width : height
        var copy = configuration
        let longSide = Double(max(configuration.width, configuration.height, VirtualScreenManager.minimumSide))
        if ratio >= 1 {
            copy.width = Int(longSide)
            copy.height = Int((longSide / ratio / 2).rounded()) * 2
        } else {
            copy.height = Int(longSide)
            copy.width = Int((longSide * ratio / 2).rounded()) * 2
        }
        apply(copy)
    }

    private func scale(_ configuration: VirtualScreenConfiguration, by factor: Double) {
        // A configuration saved by an earlier version can have a zero side;
        // dividing by it would give an infinite ratio.
        let current = VirtualScreenManager.fitted(configuration)
        var copy = current
        let ratio = Double(current.height) / Double(current.width)
        let width = max(640, (Double(current.width) * factor / 16).rounded() * 16)
        copy.width = Int(width)
        copy.height = Int((width * ratio / 2).rounded()) * 2
        // `apply` scales both sides down together at the pixel ceiling.
        apply(copy)
    }

    private func applyMirror(_ configuration: VirtualScreenConfiguration) {
        guard let displayID = manager.displayID(for: configuration) else { return }
        if let identity = configuration.mirrorTargetIdentity,
           let target = controller.displays.first(where: { $0.identity == identity }) {
            _ = DisplayManager.shared.setMirror(source: displayID, on: target.id)
        } else {
            _ = DisplayManager.shared.setMirror(source: displayID, on: nil)
        }
    }

    private func discard(_ configuration: VirtualScreenConfiguration) {
        let alert = NSAlert()
        alert.messageText = "Discard \(configuration.name)?"
        alert.informativeText = "The virtual screen is disconnected and its configuration is removed."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        manager.destroy(configuration.id)
        store.state.virtualScreens.removeAll { $0.id == configuration.id }
        SettingsNavigation.shared.selectDevice(.displays)
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

/// Mode picker for a connected virtual screen (its flexible resolution list).
private struct ResolutionCardForVirtual: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        SettingsSectionTitle(title: "Virtual Screen Mode")
        SettingsCard {
            SettingsRow(title: "Current resolution",
                        help: "Any size from the flexible list. The menu's resolution slider offers the same sizes.") {
                Picker("", selection: Binding(
                    get: { controller.effectiveMode(for: display)?.id ?? -1 },
                    set: { id in
                        if let mode = display.modes.first(where: { $0.id == id }) { controller.setMode(mode, for: display) }
                    })) {
                    ForEach(modes) { mode in
                        Text("\(mode.resolutionText)\(mode.isHiDPI ? " HiDPI" : "")").tag(mode.id)
                    }
                    if !modes.contains(where: { $0.id == controller.effectiveMode(for: display)?.id }) {
                        Text(display.resolutionSummary).tag(controller.effectiveMode(for: display)?.id ?? -1)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private var modes: [ModeInfo] {
        var seen = Set<String>()
        return display.modes
            .sorted { $0.width == $1.width ? $0.isHiDPI && !$1.isHiDPI : $0.width > $1.width }
            .filter { seen.insert("\($0.width)x\($0.height)-\($0.isHiDPI)").inserted }
    }
}

private struct VirtualDisplayInformation: View {
    let display: DisplayInfo
    let configuration: VirtualScreenConfiguration
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = VirtualScreenManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(configuration.name) — Display Information").font(.system(size: 16, weight: .bold))
            SettingsCard {
                SettingsRow(title: "Display ID", value: "\(display.id)")
                SettingsRowDivider()
                SettingsRow(title: "Identity", value: display.identity)
                SettingsRowDivider()
                SettingsRow(title: "Current mode", value: display.currentMode?.fullSummary ?? "—")
                SettingsRowDivider()
                SettingsRow(title: "Published modes", value: "\(display.modes.count)")
                SettingsRowDivider()
                let limits = manager.active.first { $0.id == configuration.id }?.maxPixels
                SettingsRow(title: "Framebuffer limit", value: limits.map { "\($0.wide) × \($0.high)" } ?? "—")
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - Associated displays

/// Association list: a switch per display (connected, and
/// optionally remembered ones that are disconnected), plus association settings.
private struct AssociatedDisplaysCard: View {
    let configuration: VirtualScreenConfiguration
    let virtualDisplayID: CGDirectDisplayID?
    let apply: (VirtualScreenConfiguration) -> Void

    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var showDisconnected = false
    @State private var showSettings = false

    private struct Candidate: Identifiable {
        let identity: String
        let name: String
        let symbol: String
        let connected: Bool
        var id: String { identity }
    }

    /// Connected displays (other than this virtual screen), then remembered or
    /// associated displays that are not connected.
    private var candidates: [Candidate] {
        var result: [Candidate] = []
        var seen = Set<String>()
        for display in controller.displays where display.id != virtualDisplayID {
            guard seen.insert(display.identity).inserted else { continue }
            result.append(Candidate(identity: display.identity, name: display.name,
                                    symbol: DisplayGlyph.symbol(for: display), connected: true))
        }
        let ownIdentities = Set(store.state.virtualScreens.map { "22136-4660-\($0.serialNumber)" })
        let remembered = store.state.knownDisplayNames
        let offline = Set(configuration.associatedDisplayIdentities)
            .union(showDisconnected ? Set(remembered.keys) : [])
            .subtracting(seen)
            .subtracting(ownIdentities)
        for identity in offline.sorted(by: { (remembered[$0] ?? $0) < (remembered[$1] ?? $1) }) {
            result.append(Candidate(identity: identity, name: remembered[identity] ?? "Display \(identity)",
                                    symbol: "display", connected: false))
        }
        return result
    }

    var body: some View {
        SettingsSectionTitle(title: "Associated Displays")
        SettingsCard {
            SettingsIconHeader(symbol: "link", title: "Associate this virtual screen with real display(s)", tint: .orange)
            SettingsHelpText(text: "The app can automatically connect and disconnect a virtual screen based on the availability of the display(s) it is associated with. It can also auto-start mirroring or streaming, or follow the associated display's aspect ratio and orientation.")
            ForEach(candidates) { candidate in
                SettingsRowDivider()
                HStack(spacing: 10) {
                    IconTile(symbol: candidate.symbol, tint: .orange, size: 24)
                        .opacity(candidate.connected ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.name).font(.system(size: 13))
                            .foregroundStyle(candidate.connected ? Color.primary : Color.secondary)
                        if !candidate.connected {
                            Text("Currently disconnected").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { configuration.associatedDisplayIdentities.contains(candidate.identity) },
                        set: { on in
                            var copy = configuration
                            copy.associatedDisplayIdentities.removeAll { $0 == candidate.identity }
                            if on { copy.associatedDisplayIdentities.append(candidate.identity) }
                            apply(copy)
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 7)
            }
            if configuration.isAssociated {
                SettingsRowDivider()
                SettingsRow(title: "Behaviour", value: summary)
            }
            SettingsRowDivider()
            SettingsButtonRow {
                Button(showDisconnected ? "Hide Currently Disconnected" : "Show Currently Disconnected") {
                    showDisconnected.toggle()
                }
                Button("Disassociate All") {
                    var copy = configuration
                    copy.associatedDisplayIdentities = []
                    apply(copy)
                }
                .disabled(!configuration.isAssociated)
            }
        }
        HStack {
            Spacer()
            Button("Association Settings…") { showSettings = true }
                .controlSize(.large)
        }
        .sheet(isPresented: $showSettings) {
            AssociationSettingsSheet(configuration: configuration, apply: apply)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if configuration.connectWithAssociated { parts.append("Connects while associated display is online") }
        if configuration.connectWhenAssociatedOffline { parts.append("Connects while all are offline") }
        if configuration.enforceMirroring { parts.append("mirrors") }
        if configuration.autoStream { parts.append("streams") }
        if configuration.followOrientation { parts.append("follows orientation") }
        return parts.isEmpty ? "Associated only" : parts.joined(separator: " · ")
    }
}

/// Association Settings: five switches, applied immediately.
private struct AssociationSettingsSheet: View {
    let configuration: VirtualScreenConfiguration
    let apply: (VirtualScreenConfiguration) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VirtualScreenConfiguration

    init(configuration: VirtualScreenConfiguration, apply: @escaping (VirtualScreenConfiguration) -> Void) {
        self.configuration = configuration
        self.apply = apply
        _draft = State(initialValue: configuration)
    }

    private func toggle(_ keyPath: WritableKeyPath<VirtualScreenConfiguration, Bool>,
                        excluding other: WritableKeyPath<VirtualScreenConfiguration, Bool>? = nil) -> Binding<Bool> {
        Binding(get: { draft[keyPath: keyPath] },
                set: { value in
                    draft[keyPath: keyPath] = value
                    // The two auto-connect modes are opposites.
                    if value, let other { draft[keyPath: other] = false }
                    // An earlier switch (follow orientation, match aspect) may
                    // have reshaped the screen since this sheet opened: keep
                    // that geometry instead of writing the old one back.
                    if let live = SettingsStore.shared.state.virtualScreens.first(where: { $0.id == draft.id }) {
                        draft.width = live.width
                        draft.height = live.height
                    }
                    apply(draft)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Association Settings").font(.system(size: 15, weight: .bold))
                SettingsCard {
                    SettingsToggleRow(title: "Auto-connect virtual screen",
                                      help: "Automatically connect the virtual screen when an associated display is online and disconnect when it is not.",
                                      isOn: toggle(\.connectWithAssociated, excluding: \.connectWhenAssociatedOffline))
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Auto-connect virtual screen when all associated screens are offline",
                                      help: "Automatically connect the virtual screen when all associated displays are offline and disconnect when not.",
                                      isOn: toggle(\.connectWhenAssociatedOffline, excluding: \.connectWithAssociated))
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Enforce virtual screen mirroring",
                                      help: "Automatically configure mirroring to show the virtual screen's content on the associated display. If multiple associated displays are connected, only one will be the mirror target.",
                                      isOn: toggle(\.enforceMirroring))
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Auto-start full screen streaming",
                                      help: "Automatically stream the virtual screen's content to the associated display. If multiple associated displays are connected, only one will be the stream target (the next one when mirroring uses the first).",
                                      isOn: toggle(\.autoStream))
                    SettingsRowDivider()
                    SettingsToggleRow(title: "Virtual screen follows display orientation",
                                      help: "Let the virtual screen follow the orientation of the associated display when it is rotated.",
                                      isOn: toggle(\.followOrientation))
                }
            }
            .padding(20)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
        }
        .frame(width: 620)
    }
}
