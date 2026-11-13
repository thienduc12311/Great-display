import SwiftUI
import AppKit
import GDCore

// MARK: - All Displays (overview)

struct DisplaysOverviewPage: View {
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var keyboard = KeyboardController.shared

    var body: some View {
        DetailScroll {
            PageHeader(title: "Displays",
                       subtitle: "\(controller.displays.count) connected · click a screen to configure it") {
                IconTile(symbol: "rectangle.3.group", tint: .blue, size: 44)
            } actions: {
                Button { controller.displays.forEach { controller.identify($0) } } label: {
                    Label("Identify", systemImage: "eye")
                }
                Button { controller.redetect() } label: {
                    Label("Redetect", systemImage: "arrow.clockwise")
                }
            }

            attention

            ArrangementCanvas()

            SettingsSectionTitle(title: "Quick Controls", symbol: "sun.max")
            let rows = stride(from: 0, to: controller.displays.count, by: 2).map {
                Array(controller.displays[$0..<min($0 + 2, controller.displays.count)])
            }
            VStack(spacing: 12) {
                ForEach(rows, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(row) { DisplayQuickCard(display: $0) }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }

            if !controller.disconnected.isEmpty {
                SettingsSectionTitle(title: "Disconnected", symbol: "powerplug")
                SettingsCard {
                    ForEach(Array(controller.disconnected.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { SettingsRowDivider() }
                        SettingsRow(title: entry.name, help: "Removed from the desktop by Great Display; the display still has power.") {
                            Button("Connect") { controller.reconnect(entry.id) }
                        }
                    }
                    if controller.disconnected.count > 1 {
                        SettingsRowDivider()
                        SettingsButtonRow {
                            Button("Connect All") { controller.reconnectAll() }
                        }
                    }
                }
            }

            SettingsSectionTitle(title: "Saved Settings", symbol: "externaldrive")
            SettingsCard {
                SettingsToggleRow(title: "Restore display configuration on launch",
                                  help: "Re-applies each display's saved resolution, arrangement and main-display choice. Settings follow a display between ports.",
                                  isOn: $store.state.general.restoreConfigurationOnLaunch)
            }
        }
    }

    @ViewBuilder
    private var attention: some View {
        if store.state.general.handleBrightnessKeys && !keyboard.trusted {
            Callout(symbol: "keyboard", tint: .orange,
                    title: "Brightness keys are not active",
                    message: "Great Display needs Accessibility access to handle the brightness and volume keys.") {
                Button("Fix…") { SettingsNavigation.shared.select(.keyboard) }
            }
            .padding(.bottom, 6)
        }
        if !keyboard.conflictingApps.isEmpty {
            let names = keyboard.conflictingApps.compactMap(\.localizedName).joined(separator: " and ")
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                    title: "\(names) also controls the brightness keys",
                    message: "Only one app can handle them at a time.") {
                Button("Resolve…") { SettingsNavigation.shared.select(.keyboard) }
            }
            .padding(.bottom, 6)
        }
    }
}

/// Bird's-eye view of the desktop arrangement. Click a screen to open it.
private struct ArrangementCanvas: View {
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        SettingsCard {
            GeometryReader { geometry in
                let layout = layout(in: geometry.size)
                ZStack(alignment: .topLeading) {
                    ForEach(layout, id: \.display.id) { item in
                        ArrangementTile(display: item.display,
                                        mode: controller.effectiveMode(for: item.display),
                                        size: item.rect.size) {
                            navigation.select(.display(item.display.id))
                        }
                        .position(x: item.rect.midX, y: item.rect.midY)
                    }
                }
            }
            .frame(height: 230)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                    .padding(6)
            )
            HStack(spacing: 14) {
                legend(color: .white.opacity(0.7), text: "Menu bar = main display")
                Spacer()
                Text("Arrange precisely in System Settings › Displays")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .padding(.vertical, 6)
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.7))
                .frame(width: 18, height: 12)
                .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 2.5) }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private struct Item { let display: DisplayInfo; let rect: CGRect }

    private func layout(in size: CGSize) -> [Item] {
        let displays = controller.displays.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }
        guard let first = displays.first else { return [] }
        let union = displays.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        let padding: CGFloat = 24
        let scale = min((size.width - padding * 2) / union.width, (size.height - padding * 2) / union.height)
        let offsetX = (size.width - union.width * scale) / 2
        let offsetY = (size.height - union.height * scale) / 2
        return displays.map { display in
            let rect = CGRect(x: offsetX + (display.bounds.minX - union.minX) * scale,
                              y: offsetY + (display.bounds.minY - union.minY) * scale,
                              width: display.bounds.width * scale,
                              height: display.bounds.height * scale)
            return Item(display: display, rect: rect.insetBy(dx: 2, dy: 2))
        }
    }
}

private struct ArrangementTile: View {
    let display: DisplayInfo
    let mode: ModeInfo?
    let size: CGSize
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Button(action: action) {
            ZStack(alignment: .top) {
                shape.fill(LinearGradient(colors: hovering
                                              ? [Color.accentColor.opacity(0.8), Color.accentColor]
                                              : [Color(red: 0.36, green: 0.47, blue: 0.68), Color(red: 0.24, green: 0.32, blue: 0.5)],
                                          startPoint: .top, endPoint: .bottom))
                if display.isMain {
                    Rectangle().fill(Color.white.opacity(0.65)).frame(height: max(3, size.height * 0.06))
                }
                VStack(spacing: 2) {
                    Image(systemName: DisplayGlyph.symbol(for: display))
                        .font(.system(size: min(22, size.height * 0.22)))
                    if size.height > 56 {
                        Text(display.name)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    if size.height > 80, let mode {
                        Text(verbatim: "\(mode.width) × \(mode.height)")
                            .font(.system(size: 10).monospacedDigit())
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.25)))
            .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 6 : 3, y: 2)
            .frame(width: size.width, height: size.height)
            .scaleEffect(hovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Configure \(display.name)")
    }
}

/// One card per display on the overview: name, mode and a brightness slider.
private struct DisplayQuickCard: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        let value = controller.combinedBrightness(for: display)
        SettingsCard {
            Button { SettingsNavigation.shared.select(.display(display.id)) } label: {
                HStack(spacing: 12) {
                    ScreenThumbnail(aspect: display.aspect, selected: true, isMain: display.isMain,
                                    box: CGSize(width: 38, height: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(controller.effectiveMode(for: display)?.summary ?? "No active mode")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SettingsRowDivider()
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.combinedBrightness(for: display) },
                                      set: { controller.setCombinedBrightness($0, for: display, showOSD: false) }))
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Disconnected display

struct DisconnectedDisplayPage: View {
    let entry: DisconnectedDisplay
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        DetailScroll {
            PageHeader(title: entry.name, subtitle: "Disconnected",
                       chips: [StatusChip(text: "Off", symbol: "power", tint: .secondary)]) {
                ScreenThumbnail(aspect: 16.0 / 9, dimmed: true, box: CGSize(width: 56, height: 42))
            }
            Callout(symbol: "powerplug", tint: .blue,
                    title: "This display is disconnected",
                    message: "Great Display removed it from the desktop. It keeps its power and comes back with one click.") {
                Button("Connect") { controller.reconnect(entry.id) }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Display page

struct DisplayDetailPage: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var showInformation = false
    @State private var showDDCAdvanced = false

    private var tabs: [PillTabs<DisplayTab>.Item] {
        DisplayTab.allCases.map { .init(value: $0, title: $0.title, symbol: $0.symbol) }
    }

    var body: some View {
        DetailScroll {
            PageHeader(title: display.name, subtitle: displayType, chips: chips) {
                ScreenThumbnail(aspect: display.aspect, selected: true, isMain: display.isMain,
                                box: CGSize(width: 56, height: 42))
            } actions: {
                Button { controller.identify(display) } label: { Label("Identify", systemImage: "eye") }
                Button { showInformation = true } label: { Image(systemName: "info.circle") }
                    .help("Display information")
            }

            PillTabs(items: tabs, selection: $navigation.displayTab)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)

            switch navigation.displayTab {
            case .picture:
                BrightnessCard(display: display)
                ResolutionCard(display: display)
            case .color:
                ColorAdjustmentsView(display: display)
            case .monitor:
                DeviceControlCard(display: display, showAdvanced: $showDDCAdvanced)
            case .options:
                DisplayOptionsView(display: display, showInformation: $showInformation)
            }
        }
        .sheet(isPresented: $showInformation) { DisplayInformationSheet(display: display) }
        .sheet(isPresented: $showDDCAdvanced) { DDCAdvancedSheet(display: display) }
    }

    private var chips: [StatusChip] {
        var chips: [StatusChip] = []
        if display.isMain { chips.append(StatusChip(text: "Main", symbol: "menubar.rectangle", tint: .accentColor)) }
        if let mode = controller.effectiveMode(for: display) {
            chips.append(StatusChip(text: mode.refreshText))
            if mode.isHiDPI { chips.append(StatusChip(text: "HiDPI", tint: .purple)) }
        }
        if controller.hdrEnabled.contains(display.id) { chips.append(StatusChip(text: "HDR", tint: .orange)) }
        if controller.ddcAvailable(display) { chips.append(StatusChip(text: "DDC", symbol: "cable.connector", tint: .green)) }
        if display.isMirrored { chips.append(StatusChip(text: "Mirrored", tint: .teal)) }
        return chips
    }

    private var displayType: String {
        if display.isBuiltIn { return "Built-in display" }
        if display.isVirtual { return "Virtual screen" }
        if display.name.localizedCaseInsensitiveContains("displaylink") { return "DisplayLink display" }
        if display.vendorID == 0x0610 { return "Apple external display" }
        return "External display"
    }
}

// MARK: Picture tab

private struct BrightnessCard: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared
    @State private var showExtra = false

    var body: some View {
        let value = controller.combinedBrightness(for: display)
        SettingsSectionTitle(title: "Brightness", symbol: "sun.max")
        SettingsCard {
            HStack(spacing: 14) {
                Image(systemName: "sun.min.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { controller.combinedBrightness(for: display) },
                                      set: { controller.setCombinedBrightness($0, for: display, showOSD: false) }))
                    .controlSize(.large)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .padding(.top, 12)
            .padding(.bottom, 6)
            HStack(spacing: 6) {
                StatusChip(text: brightnessKind, symbol: "bolt.fill", tint: .secondary)
                if controller.usesCombinedBrightness(display) {
                    HelpButton(text: "One control: the display's own backlight first, then color-table dimming below its minimum.")
                }
                Spacer()
                if !controller.usesCombinedBrightness(display) {
                    Button(showExtra ? "Hide Extra Dimming" : "Extra Dimming…") {
                        withAnimation(.easeOut(duration: 0.15)) { showExtra.toggle() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, SettingsStyle.rowInset)
            .padding(.bottom, 10)
            // Combined brightness already drives dimming; exposing a second
            // control for the same value makes brightness jump unexpectedly.
            if !controller.usesCombinedBrightness(display) && (showExtra || controller.dimming(for: display.id) < 0.999) {
                SettingsRowDivider()
                let dimming = controller.dimming(for: display.id)
                SettingsSliderRow(title: "Extra dimming",
                                  help: "Darkens through the color table, below what the backlight can do.",
                                  value: Binding(get: { controller.dimming(for: display.id) },
                                                 set: { controller.setDimming($0, for: display) }),
                                  range: 0.1...1,
                                  text: "\(Int((dimming * 100).rounded()))%")
            }
            SettingsButtonRow {
                Button("Reset Brightness and Dimming") { controller.resetAdjustments(for: display) }
                    .controlSize(.small)
            }
        }
    }

    private var brightnessKind: String {
        if controller.usesCombinedBrightness(display) {
            return controller.ddcAvailable(display) && !display.hasHardwareBrightness ? "DDC + software" : "Native + software"
        }
        if display.hasHardwareBrightness { return "Native backlight" }
        if controller.ddcAvailable(display) { return "DDC/CI backlight" }
        return "Software dimming"
    }
}

private struct ResolutionCard: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        SettingsSectionTitle(title: "Resolution", symbol: "aspectratio")
        SettingsCard {
            let tiles = tileModes
            if tiles.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Looks like").font(.system(size: 13))
                        Spacer()
                        if let mode = controller.effectiveMode(for: display) {
                            Text(verbatim: "\(mode.width) × \(mode.height)\(mode.isHiDPI ? " HiDPI" : "")")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(tiles.enumerated()), id: \.element.id) { index, mode in
                            ResolutionTile(mode: mode,
                                           label: tileLabel(mode, index: index, count: tiles.count),
                                           relativeSize: relativeSize(mode, in: tiles),
                                           selected: mode.width == currentMode?.width && mode.height == currentMode?.height) {
                                controller.setMode(mode, for: display)
                            }
                        }
                    }
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 12)
                SettingsRowDivider()
            }
            SettingsRow(title: "All display modes", help: "Every mode the display offers, including low-density and other refresh rates.") {
                Picker("", selection: modeBinding) {
                    ForEach(allModes) { mode in
                        Text("\(mode.resolutionText)\(mode.isHiDPI ? " HiDPI" : "") · \(mode.refreshText)").tag(mode.id)
                    }
                    if !allModes.contains(where: { $0.id == currentID }) {
                        Text(display.resolutionSummary).tag(currentID)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            let rates = controller.refreshRates(for: display)
            if rates.count > 1 {
                SettingsRowDivider()
                SettingsRow(title: "Refresh rate") {
                    Picker("", selection: modeBinding) {
                        ForEach(rates) { Text($0.refreshText).tag($0.id) }
                        if !rates.contains(where: { $0.id == currentID }) {
                            Text(currentMode?.refreshText ?? "—").tag(currentID)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }
            SettingsRowDivider()
            SettingsToggleRow(title: "HiDPI (sharp text)",
                              help: "Renders at twice the size for crisp text. Switch off for the low-density version of this size.",
                              isOn: Binding(get: { currentMode?.isHiDPI == true },
                                            set: { _ in controller.toggleHiDPI(for: display) }),
                              enabled: hasDensityCounterpart)
            if controller.canRotate.contains(display.id) {
                SettingsRowDivider()
                SettingsRow(title: "Rotation") {
                    Picker("", selection: Binding(get: { controller.rotation(for: display) },
                                                  set: { controller.setRotation($0, for: display) })) {
                        Text("0°").tag(0)
                        Text("90°").tag(90)
                        Text("180°").tag(180)
                        Text("270°").tag(270)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            if controller.hdrCapable.contains(display.id) {
                SettingsRowDivider()
                SettingsToggleRow(title: "High Dynamic Range",
                                  isOn: Binding(get: { controller.hdrEnabled.contains(display.id) },
                                                set: { controller.setHDR($0, for: display) }))
            }
        }
    }

    private var currentMode: ModeInfo? { controller.effectiveMode(for: display) }
    private var currentID: Int { currentMode?.id ?? -1 }

    /// Up to six sizes from "larger text" to "more space", always including the current one.
    private var tileModes: [ModeInfo] {
        let modes = controller.sliderModes(for: display)
        guard modes.count > 6 else { return modes }
        var picked = Set<Int>()
        for step in 0..<6 { picked.insert(Int((Double(step) * Double(modes.count - 1) / 5).rounded())) }
        if let current = modes.firstIndex(where: { $0.width == currentMode?.width && $0.height == currentMode?.height }),
           !picked.contains(current) {
            let nearest = picked.min { abs($0 - current) < abs($1 - current) } ?? 0
            if nearest != 0 && nearest != modes.count - 1 { picked.remove(nearest) }
            picked.insert(current)
        }
        return picked.sorted().map { modes[$0] }
    }

    /// 0 for the smallest size offered, 1 for the largest.
    private func relativeSize(_ mode: ModeInfo, in tiles: [ModeInfo]) -> CGFloat {
        guard let low = tiles.first?.width, let high = tiles.last?.width, high > low else { return 1 }
        return CGFloat(mode.width - low) / CGFloat(high - low)
    }

    private func tileLabel(_ mode: ModeInfo, index: Int, count: Int) -> String {
        if mode.isNative { return "Native" }
        if mode.isDefault { return "Default" }
        if index == 0 { return "Larger Text" }
        if index == count - 1 { return "More Space" }
        return ""
    }

    private var allModes: [ModeInfo] {
        display.modes.filter(\.isUsable)
            .sorted { $0.width == $1.width ? ($0.isHiDPI == $1.isHiDPI ? $0.refreshRate > $1.refreshRate : $0.isHiDPI) : $0.width > $1.width }
    }

    private var modeBinding: Binding<Int> {
        Binding(get: { currentID },
                set: { id in if let mode = display.modes.first(where: { $0.id == id }) { controller.setMode(mode, for: display) } })
    }

    private var hasDensityCounterpart: Bool {
        guard let mode = currentMode else { return false }
        return display.modes.contains { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI != mode.isHiDPI }
    }
}

/// "Looks like" choice: a screen drawn bigger for sizes with more space.
private struct ResolutionTile: View {
    let mode: ModeInfo
    let label: String
    let relativeSize: CGFloat
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                // Bigger screen = more space; bigger letters = larger text.
                let width = 30 + 26 * relativeSize
                let aspect = max(0.5, CGFloat(mode.width) / CGFloat(max(1, mode.height)))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: width, height: width / aspect)
                    .overlay {
                        Text(verbatim: "Aa")
                            .font(.system(size: 15 - 6 * relativeSize, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : Color.secondary)
                    }
                    .frame(height: 40)
                Text(verbatim: "\(mode.width)×\(mode.height)")
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? .primary : .secondary)
                Text(label.isEmpty ? " " : label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.1) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(mode.resolutionText)\(mode.isHiDPI ? " HiDPI" : "") · \(mode.refreshText)")
    }
}

// MARK: Color tab

private struct ColorPreset: Identifiable {
    let name: String
    let colors: [Color]
    let apply: (inout ImageAdjustments) -> Void
    var id: String { name }

    static let all: [ColorPreset] = [
        ColorPreset(name: "Neutral", colors: [.white, Color(white: 0.85)]) { $0 = .neutral },
        ColorPreset(name: "Cool", colors: [Color(red: 0.8, green: 0.9, blue: 1), Color(red: 0.55, green: 0.75, blue: 1)]) {
            $0 = .neutral; $0.temperature = -0.35
        },
        ColorPreset(name: "Warm", colors: [Color(red: 1, green: 0.93, blue: 0.8), Color(red: 1, green: 0.78, blue: 0.5)]) {
            $0 = .neutral; $0.temperature = 0.35
        },
        ColorPreset(name: "Evening", colors: [Color(red: 1, green: 0.8, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.25)]) {
            $0 = .neutral; $0.temperature = 0.75; $0.gamma = 1.1
        },
        ColorPreset(name: "Reading", colors: [Color(red: 0.98, green: 0.95, blue: 0.85), Color(red: 0.85, green: 0.8, blue: 0.65)]) {
            $0 = .neutral; $0.temperature = 0.2; $0.contrast = 0.9; $0.gamma = 1.15
        },
    ]
}

private struct ColorAdjustmentsView: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    private func binding(_ keyPath: WritableKeyPath<ImageAdjustments, Double>) -> Binding<Double> {
        Binding(get: { controller.adjustments(for: display.id)[keyPath: keyPath] },
                set: { value in
                    var copy = controller.adjustments(for: display.id)
                    copy[keyPath: keyPath] = value
                    controller.setAdjustments(copy, for: display)
                })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ImageAdjustments, Bool>) -> Binding<Bool> {
        Binding(get: { controller.adjustments(for: display.id)[keyPath: keyPath] },
                set: { value in
                    var copy = controller.adjustments(for: display.id)
                    copy[keyPath: keyPath] = value
                    controller.setAdjustments(copy, for: display)
                })
    }

    var body: some View {
        let value = controller.adjustments(for: display.id)
        SettingsSectionTitle(title: "Presets", symbol: "swatchpalette")
        SettingsCard {
            HStack(spacing: 10) {
                ForEach(ColorPreset.all) { preset in
                    PresetButton(preset: preset, selected: matches(preset, value)) {
                        var copy = value
                        preset.apply(&copy)
                        copy.suspended = false
                        controller.setAdjustments(copy, for: display)
                    }
                }
            }
            .padding(12)
            SettingsHelpText(text: "Adjustments use the display's color table, so they work on every display. They are saved per display and can clip HDR content.")
        }

        SettingsSectionTitle(title: "Tone", symbol: "circle.lefthalf.filled")
        SettingsCard {
            SettingsSliderRow(title: "Color temperature", value: binding(\.temperature), range: -1...1,
                              text: value.temperature == 0 ? "Neutral" : (value.temperature > 0 ? "Warm \(Int(value.temperature * 100))" : "Cool \(Int(-value.temperature * 100))"),
                              tint: value.temperature >= 0 ? .orange : .blue)
            SettingsRowDivider()
            SettingsSliderRow(title: "Gamma", value: binding(\.gamma), range: 0.4...2.2, text: String(format: "%.2f", value.gamma))
            SettingsRowDivider()
            SettingsSliderRow(title: "Contrast", value: binding(\.contrast), range: 0.5...1.5,
                              text: String(format: "%.0f%%", (value.contrast - 0.5) * 100))
        }

        SettingsSectionTitle(title: "Color Balance", symbol: "slider.vertical.3")
        SettingsCard {
            SettingsSliderRow(title: "Red", value: binding(\.redGain), text: String(format: "%.0f%%", value.redGain * 100), tint: .red)
            SettingsRowDivider()
            SettingsSliderRow(title: "Green", value: binding(\.greenGain), text: String(format: "%.0f%%", value.greenGain * 100), tint: .green)
            SettingsRowDivider()
            SettingsSliderRow(title: "Blue", value: binding(\.blueGain), text: String(format: "%.0f%%", value.blueGain * 100), tint: .blue)
        }

        SettingsSectionTitle(title: "Effects", symbol: "wand.and.stars")
        SettingsCard {
            SettingsToggleRow(title: "Invert colors", isOn: boolBinding(\.invert))
            SettingsRowDivider()
            SettingsToggleRow(title: "Pause adjustments",
                              help: "Shows the original picture without losing your values. Handy for before/after comparison.",
                              isOn: boolBinding(\.suspended))
            SettingsRowDivider()
            SettingsButtonRow {
                Button("Reset Color") { controller.resetImageAdjustments(for: display) }
                    .disabled(value == .neutral)
            }
        }
    }

    private func matches(_ preset: ColorPreset, _ value: ImageAdjustments) -> Bool {
        var target = ImageAdjustments.neutral
        preset.apply(&target)
        var current = value
        current.suspended = false
        return current == target
    }
}

private struct PresetButton: View {
    let preset: ColorPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(LinearGradient(colors: preset.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
                    .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2).padding(-4))
                Text(preset.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Options tab

private struct DisplayOptionsView: View {
    let display: DisplayInfo
    @Binding var showInformation: Bool
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared

    private var preferences: Binding<DisplayPreferences> {
        Binding(get: { store.preferences(for: display.identity) },
                set: { store.setPreferences($0, for: display.identity) })
    }

    var body: some View {
        SettingsSectionTitle(title: "Great Display", symbol: "menubar.rectangle")
        SettingsCard {
            SettingsToggleRow(title: "Show in the app menu",
                              help: "Lists this display in the menu bar menu.",
                              isOn: preferences.showInMenu)
            SettingsRowDivider()
            SettingsToggleRow(title: "Brightness keys control this display",
                              help: "The brightness keys (and, for monitor speakers, the volume keys) adjust this display.",
                              isOn: preferences.keyboardControl)
        }

        SettingsSectionTitle(title: "Arrangement", symbol: "rectangle.3.group")
        SettingsCard {
            SettingsRow(title: "Main display", help: "The main display holds the menu bar and the Dock.") {
                if display.isMain {
                    StatusChip(text: "This is the main display", symbol: "checkmark", tint: .green)
                } else {
                    Button("Make Main Display") { controller.setMain(display) }
                }
            }
            if !display.isMain {
                SettingsRowDivider()
                SettingsRow(title: "Place next to the main display") {
                    HStack(spacing: 4) {
                        ForEach(DisplayManager.Placement.allCases) { placement in
                            Button { controller.place(display, placement) } label: {
                                Image(systemName: placement.symbol).frame(width: 20)
                            }
                            .help(placement.rawValue)
                        }
                    }
                }
            }
        }

        SettingsSectionTitle(title: "Connection", symbol: "powerplug")
        SettingsCard {
            SettingsToggleRow(title: "Connected",
                              help: display.isVirtual
                                ? "Switching off disconnects the virtual screen; its definition is kept."
                                : "Switching off removes the display from the desktop without cutting its power. Bring it back from All Displays or the menu.",
                              isOn: Binding(get: { true }, set: { if !$0 { disconnect() } }),
                              enabled: display.isVirtual ? !connectionFollowsAssociation : canDisconnect)
            SettingsRowDivider()
            SettingsButtonRow {
                Button("Identify") { controller.identify(display) }
                Button("Display Information…") { showInformation = true }
            }
        }
    }

    private var canDisconnect: Bool {
        DisplayManager.shared.canDisconnect && controller.displays.filter { !$0.isVirtual }.count > 1
    }

    /// A virtual screen whose association rule decides when it is connected:
    /// switching it off by hand would be undone by the rule.
    private var connectionFollowsAssociation: Bool {
        guard let active = virtualScreens.active.first(where: { $0.displayID == display.id }) else { return false }
        let saved = store.state.virtualScreens.first { $0.id == active.id } ?? active.configuration
        return saved.connectionFollowsAssociation
    }

    private func disconnect() {
        if display.isVirtual {
            if let active = virtualScreens.active.first(where: { $0.displayID == display.id }) {
                virtualScreens.destroy(active.id)
            }
        } else {
            if display.isMain {
                let alert = NSAlert()
                alert.messageText = "Disconnect \(display.name)?"
                alert.informativeText = "This is the main display. The menu bar and Dock move to another display. It can be reconnected from the app menu or from Settings."
                alert.addButton(withTitle: "Disconnect")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            // Stay on this page when the display could not be disconnected.
            guard controller.disconnect(display) else { return }
        }
        SettingsNavigation.shared.select(.displays)
    }
}

// MARK: Monitor tab (DDC)

private struct DeviceControlCard: View {
    let display: DisplayInfo
    @Binding var showAdvanced: Bool
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        if controller.ddcAvailable(display) {
            available
        } else if display.hasDDC && controller.ddcInfo[display.id]?.responsive == false {
            Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                    title: "The monitor is not responding to DDC/CI",
                    message: "Brightness falls back to software dimming. Enable DDC/CI in the monitor's on-screen menu, or connect it directly instead of through a dock or adapter.") {
                Button("Try Again") {
                    let id = display.id
                    // Invalidation can wait on a slow DDC transaction.
                    DispatchQueue.global(qos: .userInitiated).async {
                        DDCController.shared.invalidate(display: id)
                        DispatchQueue.main.async { controller.redetect() }
                    }
                }
            }
        } else if display.hasDDC {
            Callout(symbol: "hourglass", tint: .blue, title: "Checking the monitor…",
                    message: "Reading which hardware controls this monitor supports.") { EmptyView() }
        } else {
            Callout(symbol: "slider.horizontal.below.rectangle", tint: .gray,
                    title: display.isVirtual ? "Not available for virtual screens" : "No hardware control for this display",
                    message: "Hardware controls (backlight, volume, input switching) need a monitor that speaks DDC/CI. Brightness and color still work through the color table.") { EmptyView() }
        }
    }

    @ViewBuilder
    private var available: some View {
        let info = controller.ddcInfo[display.id]
        let caps = info?.capabilities
        SettingsCard {
            SettingsIconHeader(symbol: "cable.connector", title: "Connected over DDC/CI", tint: .green,
                               subtitle: caps.map { "\($0.model ?? "Monitor") · MCCS \($0.mccsVersion ?? "?") · \($0.codes.count) controls" }
                                   ?? "Responding · reading capabilities…") {
                Button("Advanced…") { showAdvanced = true }
            }
        }

        SettingsSectionTitle(title: "Input", symbol: "arrow.left.arrow.right")
        SettingsCard {
            SettingsRow(title: "Input source", help: "Switching away from the Mac's input shows another source on the monitor.") {
                Picker("", selection: Binding(
                    get: { controller.inputSource[display.id] ?? -1 },
                    set: { value in
                        if let source = controller.inputSources(for: display).first(where: { $0.value == value }) {
                            controller.setInputSource(source, for: display)
                        }
                    })) {
                    if controller.inputSource[display.id] == nil { Text("Unknown").tag(-1) }
                    ForEach(controller.inputSources(for: display)) { Text($0.name).tag($0.value) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
        }

        if let volume = controller.volume(for: display.id) {
            SettingsSectionTitle(title: "Sound", symbol: "speaker.wave.2")
            SettingsCard {
                SettingsSliderRow(title: "Volume",
                                  help: "The volume keys control this when macOS plays audio through the monitor.",
                                  value: Binding(get: { controller.volume(for: display.id) ?? volume },
                                                 set: { controller.setVolume($0, for: display) }),
                                  text: controller.mute[display.id] == true ? "Muted" : "\(Int((volume * 100).rounded()))%")
                SettingsRowDivider()
                SettingsToggleRow(title: "Mute",
                                  isOn: Binding(get: { controller.mute[display.id] == true },
                                                set: { _ in controller.toggleMute(for: display) }))
            }
        }

        SettingsSectionTitle(title: "Picture (hardware)", symbol: "tv")
        SettingsCard {
            if let contrast = controller.contrast(for: display.id) {
                SettingsSliderRow(title: "Contrast",
                                  value: Binding(get: { controller.contrast(for: display.id) ?? contrast },
                                                 set: { controller.setContrast($0, for: display) }),
                                  text: "\(Int((contrast * 100).rounded()))%")
                SettingsRowDivider()
            }
            if let modes = caps?.codes[DisplayController.pictureModeCode], !modes.isEmpty {
                ddcPicker("Picture mode", code: DisplayController.pictureModeCode, values: modes, name: DDCValueNames.pictureMode)
                SettingsRowDivider()
            }
            if let presets = caps?.codes[DDCController.VCP.colorPreset.rawValue], !presets.isEmpty {
                ddcPicker("Color preset", code: DDCController.VCP.colorPreset.rawValue, values: presets, name: DDCValueNames.colorPreset)
                SettingsRowDivider()
            }
            ForEach([DDCController.VCP.redGain, .greenGain, .blueGain, .sharpness], id: \.self) { vcp in
                if let value = controller.ddcValue(vcp.rawValue, for: display.id) {
                    SettingsSliderRow(title: vcp == .sharpness ? "Sharpness" : vcp.name,
                                      value: Binding(get: { controller.ddcValue(vcp.rawValue, for: display.id)?.fraction ?? 0 },
                                                     set: { controller.setDDC(code: vcp.rawValue,
                                                                              raw: Int(($0 * Double(max(1, value.maximum))).rounded()),
                                                                              for: display) }),
                                      text: "\(value.current)",
                                      tint: tint(for: vcp))
                    SettingsRowDivider()
                }
            }
            SettingsButtonRow {
                Button("Restore Monitor Color Defaults…") {
                    confirm("Restore \(display.name)'s color defaults?", "The monitor resets its color settings.") {
                        controller.sendDDCCommand(code: DDCController.VCP.restoreColor.rawValue, value: 1, for: display)
                    }
                }
                .disabled(caps.map { !$0.supports(.restoreColor) } ?? false)
            }
        }
    }

    private func tint(for vcp: DDCController.VCP) -> Color? {
        switch vcp {
        case .redGain: return .red
        case .greenGain: return .green
        case .blueGain: return .blue
        default: return nil
        }
    }

    private func ddcPicker(_ title: String, code: UInt8, values: [Int], name: @escaping (Int) -> String) -> some View {
        SettingsRow(title: title) {
            Picker("", selection: Binding(
                get: { controller.ddcValue(code, for: display.id)?.current ?? -1 },
                set: { controller.setDDC(code: code, raw: $0, for: display) })) {
                if controller.ddcValue(code, for: display.id) == nil { Text("Unknown").tag(-1) }
                ForEach(values, id: \.self) { Text(name($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
        }
    }

    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}

// MARK: - Virtual screen pages

struct VirtualScreensPage: View {
    @ObservedObject private var manager = VirtualScreenManager.shared
    @State private var creating = false

    var body: some View {
        DetailScroll {
            PageHeader(title: "Virtual Screens", subtitle: "Displays that exist only in memory") {
                IconTile(symbol: "rectangle.dashed", tint: .purple, size: 44)
            } actions: {
                Button { creating = true } label: { Label("New Virtual Screen", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(!manager.isSupported)
            }
            VirtualScreensOverview()
        }
        .sheet(isPresented: $creating) { NewVirtualScreenSheet() }
    }
}

struct VirtualScreenDetailPage: View {
    let configurationID: UUID
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var manager = VirtualScreenManager.shared

    var body: some View {
        if let configuration = store.state.virtualScreens.first(where: { $0.id == configurationID }) {
            let active = manager.isActive(configuration)
            DetailScroll {
                PageHeader(title: configuration.name,
                           subtitle: "Virtual screen · \(configuration.aspectDescription) · \(configuration.pixelDescription)",
                           chips: [active ? StatusChip(text: "On", symbol: "circle.fill", tint: .green)
                                          : StatusChip(text: "Off", symbol: "circle", tint: .secondary)]) {
                    ScreenThumbnail(aspect: CGFloat(configuration.width) / CGFloat(max(1, configuration.height)),
                                    selected: true, dashed: true, box: CGSize(width: 56, height: 42))
                }
                VirtualScreenPage(configurationID: configurationID)
            }
        } else {
            VirtualScreensPage()
        }
    }
}

// MARK: - Sheets

struct SheetScaffold<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .bold))
            ScrollView { VStack(alignment: .leading, spacing: 10) { content() } }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600, height: 520)
        .background(SettingsStyle.contentBackground)
    }
}

private struct DisplayInformationSheet: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    var body: some View {
        SheetScaffold(title: "\(display.name) — Display Information") {
            SettingsCard {
                SettingsRow(title: "Display ID", value: "\(display.id)")
                SettingsRowDivider()
                SettingsRow(title: "Vendor / model", value: String(format: "%04X / %04X", display.vendorID, display.modelID))
                SettingsRowDivider()
                SettingsRow(title: "Serial number", value: "\(display.serialNumber)")
                SettingsRowDivider()
                SettingsRow(title: "Current mode", value: display.currentMode.map {
                    "\($0.fullSummary) · \($0.refreshText) · \($0.aspectRatio)"
                } ?? "—")
                SettingsRowDivider()
                SettingsRow(title: "Scale", value: display.scaleSummary)
                SettingsRowDivider()
                SettingsRow(title: "Bounds", value: "\(Int(display.bounds.origin.x)), \(Int(display.bounds.origin.y)) · \(Int(display.bounds.width)) × \(Int(display.bounds.height))")
                SettingsRowDivider()
                SettingsRow(title: "Rotation", value: "\(controller.rotation(for: display))°")
                SettingsRowDivider()
                SettingsRow(title: "Modes", value: "\(display.modes.count) (\(display.modes.filter(\.isHiDPI).count) HiDPI)")
                SettingsRowDivider()
                SettingsRow(title: "Brightness path", value: display.hasHardwareBrightness ? "Native"
                            : (controller.ddcAvailable(display) ? "DDC/CI" : "Software"))
            }
        }
    }
}

private struct DDCAdvancedSheet: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared
    @State private var report: String?
    @State private var rawCode = "10"
    @State private var rawValue = ""
    @State private var rawResult: String?

    var body: some View {
        SheetScaffold(title: "\(display.name) — DDC Advanced") {
            if let caps = controller.ddcInfo[display.id]?.capabilities {
                SettingsCard {
                    SettingsRow(title: "Monitor", value: "\(caps.model ?? "—") · \(caps.type ?? "—") · MCCS \(caps.mccsVersion ?? "—")")
                    SettingsRowDivider()
                    SettingsRow(title: "Supported VCP codes") {
                        Text(caps.codes.keys.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .frame(maxWidth: 320, alignment: .trailing)
                    }
                }
            }
            SettingsCard {
                SettingsRow(title: "Raw VCP", help: "Reads or writes any VCP code. The code is hexadecimal (10, 0x60), the value decimal (0–65535). Writing unknown codes can change monitor settings.") {
                    HStack {
                        TextField("Code", text: $rawCode).frame(width: 54)
                        TextField("Value", text: $rawValue).frame(width: 64)
                        Button("Read") { rawRead() }
                        Button("Write") { rawWrite() }
                            .disabled(parsedRawValue == nil || parsedRawCode == nil)
                    }
                }
                if let rawResult {
                    SettingsRowDivider()
                    SettingsRow(title: "Result", value: rawResult)
                }
            }
            SettingsCard {
                SettingsButtonRow {
                    Button("Put Display in Standby…") { standby() }
                    Button("Read All Values") { readAll() }
                }
                if let report {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, SettingsStyle.rowInset)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    private func standby() {
        let alert = NSAlert()
        alert.messageText = "Put \(display.name) in standby?"
        alert.informativeText = "The monitor turns off its panel. It wakes on signal or from its power button."
        alert.addButton(withTitle: "Standby")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            controller.sendDDCCommand(code: DDCController.VCP.powerMode.rawValue, value: 0x04, for: display)
        }
    }

    /// The code field as a VCP code: hex, with or without a `0x` prefix.
    private var parsedRawCode: UInt8? {
        let text = rawCode.trimmingCharacters(in: .whitespaces).lowercased()
        return UInt8(text.hasPrefix("0x") ? String(text.dropFirst(2)) : text, radix: 16)
    }

    /// The value field, when it is a value a VCP write can carry.
    private var parsedRawValue: Int? {
        guard let value = Int(rawValue.trimmingCharacters(in: .whitespaces)), (0...0xFFFF).contains(value) else {
            return nil
        }
        return value
    }

    /// Codes that reset the monitor, switch its input or power it down. Their
    /// dedicated controls ask first, so the raw path does too.
    private static let disruptiveCodes: [UInt8: String] = [
        0x04: "restores the monitor's factory defaults",
        0x05: "restores the factory brightness and contrast",
        0x06: "restores the factory geometry",
        0x08: "restores the factory color settings",
        0x0A: "restores the factory TV defaults",
        0x60: "switches the monitor's input, which can leave this Mac without a picture on it",
        0xD6: "changes the monitor's power mode and can turn the panel off",
    ]

    private func rawRead() {
        guard let code = parsedRawCode else { rawResult = "invalid code"; return }
        let id = display.id
        rawResult = "…"
        DispatchQueue.global(qos: .userInitiated).async {
            let reading = DDCController.shared.reading(code: code, display: id)
            DispatchQueue.main.async {
                switch reading {
                case let .value(current, maximum): rawResult = "\(current) / \(maximum)"; rawValue = "\(current)"
                case .unsupported: rawResult = "unsupported"
                case .noReply: rawResult = "no reply"
                }
            }
        }
    }

    private func rawWrite() {
        guard let code = parsedRawCode, let value = parsedRawValue else {
            rawResult = "invalid code or value"
            return
        }
        if let effect = Self.disruptiveCodes[code] {
            let alert = NSAlert()
            alert.messageText = String(format: "Write %d to VCP code %02X on %@?", value, code, display.name)
            alert.informativeText = "This code \(effect)."
            alert.addButton(withTitle: "Write")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let id = display.id
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = DDCController.shared.write(code: code, value: value, display: id)
            DispatchQueue.main.async {
                rawResult = ok ? "sent" : "write failed"
                // The write went around the controller: read the values again
                // so the sliders show what the monitor has now.
                if ok { controller.redetect() }
            }
        }
    }

    private func readAll() {
        let id = display.id
        report = "Reading…"
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for vcp in DDCController.VCP.allCases where vcp.rawValue >= 0x10 {
                let name = vcp.name.padding(toLength: 14, withPad: " ", startingAt: 0)
                switch DDCController.shared.reading(code: vcp.rawValue, display: id) {
                case let .value(current, maximum):
                    lines.append(String(format: "0x%02X  %@ %d / %d", vcp.rawValue, name, current, maximum))
                case .unsupported:
                    lines.append(String(format: "0x%02X  %@ unsupported", vcp.rawValue, name))
                case .noReply:
                    lines.append(String(format: "0x%02X  %@ no reply", vcp.rawValue, name))
                }
            }
            DispatchQueue.main.async { report = lines.joined(separator: "\n") }
        }
    }
}
