import SwiftUI
import AppKit
import GDCore

/// One display's section in the app menu: header with connection switch,
/// first-level brightness and resolution sliders, and the "more options" level
/// with feature panels.
struct DeviceSection: View {
    let display: DisplayInfo
    let showHeader: Bool
    let onOpenSettings: (SettingsPane?) -> Void

    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var state = MenuState.shared
    @ObservedObject private var virtualScreens = VirtualScreenManager.shared
    @ObservedObject private var streams = FullScreenStreamController.shared

    @State private var resolutionPreview: ModeInfo?

    private var key: String { display.identityKey }
    private var general: GeneralSettings { settings.state.general }
    private var isExpanded: Bool { !showHeader || state.expandedDevices.contains(key) }
    private var moreOpen: Bool { state.moreOptionsDevice == key }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                DeviceHeader(symbol: symbol,
                             name: display.name,
                             subtitle: subtitle,
                             badges: badges,
                             isExpanded: isExpanded,
                             isConnected: true,
                             switchEnabled: display.isVirtual || controllerCanDisconnect,
                             onToggleExpand: { state.toggleDevice(key) },
                             onSwitch: { on in if !on { disconnect() } },
                             onOptionClick: { controller.identify(display) })
            }
            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    brightnessSlider
                    if general.showResolutionSlider { resolutionSlider }
                }
                .padding(.top, showHeader ? 0 : 4)
                MoreOptionsChevron(isOpen: moreOpen) { state.toggleMoreOptions(key) }
                    .padding(.vertical, 1)
                if moreOpen {
                    moreOptions
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Header

    private var symbol: String {
        if display.isBuiltIn { return "laptopcomputer" }
        if display.isVirtual { return "rectangle.dashed" }
        if display.name.localizedCaseInsensitiveContains("displaylink") { return "cable.connector.horizontal" }
        return "display"
    }

    private var badges: [String] {
        var result: [String] = []
        if display.isMain { result.append("M") }
        if controller.hdrEnabled.contains(display.id) { result.append("HDR") }
        if display.isVirtual { result.append("VIRTUAL") }
        return result
    }

    private var subtitle: String? {
        if let target = controller.mirrorTarget(of: display), let other = controller.display(target) {
            return "Mirroring onto \(other.name)"
        }
        if display.isMirrored { return "Mirrored · \(display.resolutionSummary)" }
        guard let mode = controller.effectiveMode(for: display) else { return nil }
        let rotation = Int(display.rotation.rounded())
        return "\(mode.resolutionText)\(mode.isHiDPI ? " HiDPI" : "") · \(mode.refreshText)\(rotation != 0 ? " · \(rotation)°" : "")"
    }

    private var controllerCanDisconnect: Bool {
        DisplayManager.shared.canDisconnect && controller.displays.filter { !$0.isVirtual }.count > 1
    }

    private func disconnect() {
        if display.isVirtual {
            if let active = virtualScreens.active.first(where: { $0.displayID == display.id }) {
                virtualScreens.destroy(active.id)
            }
            return
        }
        if display.isMain {
            let alert = NSAlert()
            alert.messageText = "Disconnect \(display.name)?"
            alert.informativeText = "This is the main display. The menu bar and Dock move to another display. It can be reconnected from this menu."
            alert.addButton(withTitle: "Disconnect")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        controller.disconnect(display)
    }

    // MARK: First level

    private var brightnessSlider: some View {
        let combined = controller.usesCombinedBrightness(display)
        let binding = Binding<Double>(
            get: { controller.combinedBrightness(for: display) },
            set: { controller.setCombinedBrightness($0, for: display) })
        let value = binding.wrappedValue
        return SliderRow(value: binding,
                         symbol: value < 0.35 ? "sun.min.fill" : "sun.max.fill",
                         markers: combined ? [SliderMarker(position: DisplayController.combinedHardwareFloor, label: "Min HW")] : [],
                         trailingText: "\(Int((value * 100).rounded()))%")
            .help(combined ? "Brightness (Combined): hardware above the Min HW mark, software dimming below it"
                           : (display.hasHardwareBrightness || controller.ddcAvailable(display) ? "Brightness (Hardware)" : "Brightness (Software)"))
    }

    @ViewBuilder
    private var resolutionSlider: some View {
        let modes = controller.sliderModes(for: display)
        if modes.count >= 2, controller.mirrorTarget(of: display) == nil || !display.isMirrored,
           let currentIndex = modes.firstIndex(where: { $0.matches(controller.effectiveMode(for: display)) })
            ?? modes.firstIndex(where: { $0.width == controller.effectiveMode(for: display)?.width
                                         && $0.height == controller.effectiveMode(for: display)?.height }) {
            let count = modes.count - 1
            let shown = resolutionPreview ?? modes[currentIndex]
            CapsuleSlider(value: .constant(Double(currentIndex) / Double(count)),
                          symbol: "arrow.up.left.and.arrow.down.right",
                          markers: resolutionMarkers(modes),
                          steps: count,
                          trailingText: "\(shown.resolutionText)\(shown.isHiDPI ? " HiDPI" : "")",
                          commitOnRelease: true,
                          onCommit: { position in
                              let index = Int((position * Double(count)).rounded())
                              resolutionPreview = nil
                              guard modes.indices.contains(index), index != currentIndex else { return }
                              controller.setMode(modes[index], for: display)
                          },
                          onDragChange: { position in
                              if let position {
                                  let index = Int((position * Double(count)).rounded())
                                  resolutionPreview = modes.indices.contains(index) ? modes[index] : nil
                              }
                          })
                .padding(.horizontal, MenuMetrics.contentInset)
                .padding(.vertical, 3)
                .help("Resolution: drag and release to apply")
        }
    }

    private func resolutionMarkers(_ modes: [ModeInfo]) -> [SliderMarker] {
        guard modes.count > 1 else { return [] }
        var markers: [SliderMarker] = []
        for (index, mode) in modes.enumerated() {
            let isDefault = display.modes.contains { $0.isDefault && $0.width == mode.width && $0.height == mode.height }
            let isNative = display.modes.contains { $0.isNative && $0.width == mode.width && $0.height == mode.height }
            if isDefault || isNative {
                markers.append(SliderMarker(position: Double(index) / Double(modes.count - 1),
                                            label: isDefault ? "Default" : "Native"))
            }
        }
        return markers
    }

    // MARK: More options

    @ViewBuilder
    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if general.showVolumeSlider, controller.ddcAvailable(display), let volume = controller.volume(for: display.id) {
                let muted = controller.mute[display.id] == true
                SliderRow(value: Binding(get: { controller.volume(for: display.id) ?? volume },
                                         set: { controller.setVolume($0, for: display) }),
                          symbol: muted ? "speaker.slash.fill" : (volume < 0.33 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"),
                          trailingText: muted ? "Muted" : "\(Int((volume * 100).rounded()))%",
                          onSymbolTap: { controller.toggleMute(for: display) })
                    .help("Volume (DDC) — click the speaker to mute")
            }
            if general.showContrastSlider {
                contrastSlider
            }

            featureRows
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var contrastSlider: some View {
        if controller.ddcAvailable(display), let contrast = controller.contrast(for: display.id) {
            SliderRow(value: Binding(get: { controller.contrast(for: display.id) ?? contrast },
                                     set: { controller.setContrast($0, for: display) }),
                      symbol: "circle.righthalf.filled",
                      trailingText: "\(Int((contrast * 100).rounded()))%")
                .help("Contrast (Hardware)")
        } else if general.softwareDimmingEnabled {
            let value = controller.softwareContrast(for: display.id)
            SliderRow(value: Binding(get: { controller.softwareContrast(for: display.id) },
                                     set: { controller.setSoftwareContrast($0, for: display) }),
                      symbol: "circle.righthalf.filled",
                      markers: [SliderMarker(position: 0.5, label: "Neutral")],
                      trailingText: "\(Int((value * 100).rounded()))%")
                .help("Contrast (Software)")
        }
    }

    @ViewBuilder
    private var featureRows: some View {
        let current = controller.effectiveMode(for: display)

        FeatureRow(symbol: "rectangle.3.group", title: display.isVirtual ? "Virtual Screen Mode" : "Display Mode",
                   value: current.map { "\($0.resolutionText)\($0.isHiDPI ? " ✦" : "")" },
                   isExpanded: state.isOpen(key, .displayMode)) { state.toggle(key, .displayMode) }
        if state.isOpen(key, .displayMode) {
            FeaturePanel { DisplayModePanel(display: display) }
        }

        let rates = controller.refreshRates(for: display)
        if rates.count > 1 {
            FeatureRow(symbol: "waveform.path", title: "Refresh Rate", value: current?.refreshText,
                       isExpanded: state.isOpen(key, .refreshRate)) { state.toggle(key, .refreshRate) }
            if state.isOpen(key, .refreshRate) {
                FeaturePanel {
                    ForEach(rates) { mode in
                        MenuRow(symbol: nil, title: mode.refreshText, checked: mode.matches(current)) {
                            controller.setMode(mode, for: display)
                        }
                    }
                }
            }
        }

        if controller.canRotate.contains(display.id) {
            FeatureRow(symbol: "rotate.right", title: "Screen Rotation", value: "\(controller.rotation(for: display))°",
                       isExpanded: state.isOpen(key, .rotation)) { state.toggle(key, .rotation) }
            if state.isOpen(key, .rotation) {
                FeaturePanel {
                    ForEach([0, 90, 180, 270], id: \.self) { degrees in
                        MenuRow(symbol: nil, title: degrees == 0 ? "Standard" : "\(degrees)°",
                                checked: controller.rotation(for: display) == degrees) {
                            controller.setRotation(degrees, for: display)
                        }
                    }
                }
            }
        }

        let others = controller.displays.filter { $0.id != display.id }
        if !others.isEmpty {
            let target = controller.mirrorTarget(of: display).flatMap { controller.display($0) }
            FeatureRow(symbol: "rectangle.on.rectangle", title: display.isVirtual ? "Mirror Virtual Screen" : "Mirror Display",
                       value: target?.name ?? "Off",
                       isExpanded: state.isOpen(key, .mirror)) { state.toggle(key, .mirror) }
            if state.isOpen(key, .mirror) {
                FeaturePanel {
                    MenuCaption(text: "Show this display's content on")
                    ForEach(others) { other in
                        MenuRow(symbol: "display", title: other.name, checked: target?.id == other.id) {
                            controller.setMirror(display, to: target?.id == other.id ? nil : other)
                        }
                    }
                    MenuRow(symbol: "xmark.rectangle", title: "Stop Mirroring", enabled: target != nil) {
                        controller.setMirror(display, to: nil)
                    }
                }
            }
        }

        do {
            // Streaming is available even with one display (self-stream).
            let stream = streams.stream(for: display.id)
            FeatureRow(symbol: "play.rectangle.on.rectangle",
                       title: display.isVirtual ? "Stream Virtual Screen" : "Stream Display",
                       value: stream.map { $0.isSelfStream ? "Self-Stream" : $0.targetName } ?? "Off",
                       isExpanded: state.isOpen(key, .stream)) { state.toggle(key, .stream) }
            if state.isOpen(key, .stream) {
                FeaturePanel { StreamPanel(display: display) }
            }
        }

        if controller.ddcAvailable(display) && !display.isVirtual {
            let currentInput = controller.inputSource[display.id]
            let sources = controller.inputSources(for: display)
            FeatureRow(symbol: "cable.connector", title: "Input Source",
                       value: currentInput.map { InputSource.named($0).name },
                       isExpanded: state.isOpen(key, .input)) { state.toggle(key, .input) }
            if state.isOpen(key, .input) {
                FeaturePanel {
                    ForEach(sources) { source in
                        MenuRow(symbol: source.symbol, title: source.name, checked: currentInput == source.value) {
                            controller.setInputSource(source, for: display)
                        }
                    }
                    Text("Switching away from the Mac's input shows another source on the monitor.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 3)
                }
            }

            FeatureRow(symbol: "slider.horizontal.2.square", title: "Device Control",
                       value: controller.ddcInfo[display.id]?.capabilities?.model ?? "DDC/CI",
                       isExpanded: state.isOpen(key, .deviceControl)) { state.toggle(key, .deviceControl) }
            if state.isOpen(key, .deviceControl) {
                FeaturePanel { DeviceControlPanel(display: display) }
            }
        }

        if general.softwareDimmingEnabled {
            let adjusted = !controller.adjustments(for: display.id).isNeutral
            FeatureRow(symbol: "camera.filters", title: "Image Adjustments", value: adjusted ? "Modified" : nil,
                       isExpanded: state.isOpen(key, .adjustments)) { state.toggle(key, .adjustments) }
            if state.isOpen(key, .adjustments) {
                FeaturePanel { ImageAdjustmentsPanel(display: display) }
            }
        }

        FeatureRow(symbol: "gearshape.2", title: display.isVirtual ? "Manage Virtual Screen" : "Manage Display", value: nil,
                   isExpanded: state.isOpen(key, .manage)) { state.toggle(key, .manage) }
        if state.isOpen(key, .manage) {
            FeaturePanel { managePanel }
        }

        MenuDivider()

        let hasCounterpart = current.map { mode in
            display.modes.contains { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI != mode.isHiDPI }
        } ?? false
        MenuRow(symbol: "sparkles", title: "High Resolution (HiDPI)", checked: current?.isHiDPI == true,
                enabled: hasCounterpart) {
            controller.toggleHiDPI(for: display)
        }
        if controller.hdrCapable.contains(display.id) {
            let on = controller.hdrEnabled.contains(display.id)
            MenuRow(symbol: "sun.max.trianglebadge.exclamationmark", title: "Enable HDR Mode", checked: on) {
                controller.setHDR(!on, for: display)
            }
        }
        MenuRow(symbol: "menubar.rectangle", title: "Set as Main Display", checked: display.isMain,
                enabled: !display.isMain) {
            controller.setMain(display)
        }
    }

    @ViewBuilder
    private var managePanel: some View {
        MenuRow(symbol: "slider.horizontal.3", title: display.isVirtual ? "Configure Virtual Screen…" : "Configure Display…") {
            if let screen = virtualScreens.active.first(where: { $0.displayID == display.id }) {
                onOpenSettings(.virtualScreen(screen.id))
            } else {
                onOpenSettings(.display(display.id))
            }
        }
        MenuRow(symbol: "eye", title: "Identify Visually") { controller.identify(display) }
        if !display.isMain {
            MenuCaption(text: "Move Display")
            ForEach(DisplayManager.Placement.allCases) { placement in
                MenuRow(symbol: placement.symbol, title: placement.rawValue) {
                    controller.place(display, placement)
                }
            }
        }
        MenuDivider()
        MenuRow(symbol: "arrow.uturn.backward", title: "Reset Brightness and Dimming") {
            controller.resetAdjustments(for: display)
        }
        if display.isVirtual {
            if let active = virtualScreens.active.first(where: { $0.displayID == display.id }) {
                MenuRow(symbol: "arrow.triangle.2.circlepath", title: "Reconnect Virtual Screen") {
                    let configuration = active.configuration
                    virtualScreens.destroy(active.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { _ = virtualScreens.create(configuration) }
                }
                // A screen connected by its association rule would come
                // straight back; the rule is changed in Settings.
                let saved = settings.state.virtualScreens.first { $0.id == active.id } ?? active.configuration
                MenuRow(symbol: "eject", title: "Disconnect Virtual Screen",
                        enabled: !saved.connectionFollowsAssociation) { virtualScreens.destroy(active.id) }
                MenuRow(symbol: "trash", title: "Discard Virtual Screen") {
                    // Same question as Settings asks: this removes the saved
                    // definition and its associations, not just the connection.
                    let alert = NSAlert()
                    alert.messageText = "Discard \(saved.name)?"
                    alert.informativeText = "The virtual screen is disconnected and its configuration is removed."
                    alert.addButton(withTitle: "Discard")
                    alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    virtualScreens.destroy(active.id)
                    settings.state.virtualScreens.removeAll { $0.id == active.id }
                }
            }
        } else {
            MenuRow(symbol: "eject", title: "Disconnect Display", enabled: controllerCanDisconnect) { disconnect() }
        }
    }
}

// MARK: - Display mode list

struct DisplayModePanel: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared
    @ObservedObject private var settings = SettingsStore.shared

    enum Density: String, CaseIterable { case hiDPI = "HiDPI", loDPI = "LoDPI" }

    @State private var densities: Set<Density> = []
    @State private var matchRefresh = true
    @State private var matchAspect = true
    @State private var showAll = false
    @State private var initialised = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let shortcuts = defaultAndNative
            if !shortcuts.isEmpty {
                MenuCaption(text: "Default and native modes")
                ForEach(shortcuts, id: \.0.id) { mode, label in
                    modeRow(mode, note: label)
                }
            }
            filterBar
            ScrollView {
                VStack(spacing: 0) {
                    let modes = filteredModes
                    if modes.isEmpty {
                        Text("No modes match the filter.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                    ForEach(modes) { mode in modeRow(mode, note: nil) }
                }
            }
            .frame(maxHeight: 230)
        }
        .onAppear(perform: resetFilter)
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(Density.allCases, id: \.self) { density in
                ChipToggle(title: density.rawValue, isOn: densities.contains(density)) {
                    if densities.contains(density) { densities.remove(density) } else { densities.insert(density) }
                }
            }
            ChipToggle(title: display.currentMode?.refreshText ?? "Hz", isOn: matchRefresh) { matchRefresh.toggle() }
            ChipToggle(title: display.currentMode?.aspectRatio ?? "Aspect", isOn: matchAspect) { matchAspect.toggle() }
            Spacer(minLength: 0)
            Menu {
                Toggle("Show All (including unsafe)", isOn: $showAll)
                Button("Reset Default", action: resetFilter)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Filter…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func resetFilter() {
        densities = display.currentMode?.isHiDPI == false ? [.loDPI] : [.hiDPI]
        matchRefresh = true
        matchAspect = true
        showAll = false
    }

    private var defaultAndNative: [(ModeInfo, String)] {
        var result: [(ModeInfo, String)] = []
        let rate = display.currentMode?.refreshRate ?? 0
        func best(_ list: [ModeInfo]) -> ModeInfo? {
            list.min { abs($0.refreshRate - rate) < abs($1.refreshRate - rate) }
        }
        let defaults = display.modes.filter(\.isDefault)
        let natives = display.modes.filter(\.isNative)
        if let mode = best(defaults) {
            let alsoNative = natives.contains { $0.width == mode.width && $0.height == mode.height && $0.isHiDPI == mode.isHiDPI }
            result.append((mode, alsoNative ? "Default · Native" : "Default"))
        }
        if let mode = best(natives), !result.contains(where: { $0.0.width == mode.width && $0.0.height == mode.height && $0.0.isHiDPI == mode.isHiDPI }) {
            result.append((mode, "Native"))
        }
        return result
    }

    private var filteredModes: [ModeInfo] {
        let current = display.currentMode
        let hideLow = settings.state.general.hideLowResolutions && !showAll
        var seen = Set<String>()
        return display.modes
            .filter { mode in
                if !showAll && !mode.isUsable { return false }
                if hideLow && mode.height < 720 && !mode.matches(current) { return false }
                if !densities.isEmpty {
                    let density: Density = mode.isHiDPI ? .hiDPI : .loDPI
                    if !densities.contains(density) { return false }
                }
                if matchRefresh, let current, Int(mode.refreshRate.rounded()) != Int(current.refreshRate.rounded()) { return false }
                if matchAspect, let current, mode.aspectRatio != current.aspectRatio { return false }
                return true
            }
            .sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.height != $1.height { return $0.height > $1.height }
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
            .filter { mode in
                let key = "\(mode.width)x\(mode.height)-\(mode.isHiDPI)-\(Int(mode.refreshRate.rounded()))-\(mode.pixelWidth)"
                return seen.insert(key).inserted
            }
    }

    private func modeRow(_ mode: ModeInfo, note: String?) -> some View {
        MenuRow(symbol: mode.isHiDPI ? "sparkles" : nil,
                title: mode.resolutionText,
                checked: mode.matches(controller.effectiveMode(for: display))) {
            controller.setMode(mode, for: display)
        } trailing: {
            HStack(spacing: 3) {
                if let note { TagView(text: note, color: .accentColor) }
                TagView(text: mode.aspectRatio, color: .purple)
                TagView(text: mode.refreshText, color: .teal)
                if !mode.isUsable { TagView(text: "Unsafe", color: .red) }
            }
        }
        .help("\(mode.resolutionText) on a \(mode.pixelWidth) × \(mode.pixelHeight) framebuffer\(mode.isHiDPI ? " (HiDPI)" : "")")
    }
}

// MARK: - Image adjustments

struct ImageAdjustmentsPanel: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    private var value: ImageAdjustments { controller.adjustments(for: display.id) }

    private func binding(_ get: @escaping (ImageAdjustments) -> Double,
                         _ set: @escaping (inout ImageAdjustments, Double) -> Void) -> Binding<Double> {
        Binding(get: { get(controller.adjustments(for: display.id)) },
                set: { newValue in
                    var copy = controller.adjustments(for: display.id)
                    set(&copy, newValue)
                    controller.setAdjustments(copy, for: display)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            adjustment("Gamma", "slider.horizontal.below.sun.max", neutral: (1 - 0.4) / 1.8,
                       text: String(format: "%.2f", value.gamma),
                       binding(\.gamma.gammaSlider, { $0.gamma = 0.4 + $1 * 1.8 }))
            adjustment("Color Temperature", "thermometer.medium", neutral: 0.5,
                       text: value.temperature == 0 ? "Neutral" : (value.temperature > 0 ? "Warm \(Int(value.temperature * 100))" : "Cool \(Int(-value.temperature * 100))"),
                       binding({ ($0.temperature + 1) / 2 }, { $0.temperature = $1 * 2 - 1 }))
            adjustment("Contrast", "circle.righthalf.filled", neutral: 0.5,
                       text: "\(Int(((value.contrast - 0.5)) * 100))%",
                       binding({ $0.contrast - 0.5 }, { $0.contrast = 0.5 + $1 }))
            adjustment("Gain (Red)", "r.circle", neutral: 1, text: "\(Int(value.redGain * 100))%",
                       binding(\.redGain, { $0.redGain = $1 }))
            adjustment("Gain (Green)", "g.circle", neutral: 1, text: "\(Int(value.greenGain * 100))%",
                       binding(\.greenGain, { $0.greenGain = $1 }))
            adjustment("Gain (Blue)", "b.circle", neutral: 1, text: "\(Int(value.blueGain * 100))%",
                       binding(\.blueGain, { $0.blueGain = $1 }))
            MenuDivider()
            MenuRow(symbol: "circle.lefthalf.filled.inverse", title: "Invert Colors", checked: value.invert) {
                var copy = value; copy.invert.toggle(); controller.setAdjustments(copy, for: display)
            }
            MenuRow(symbol: "pause.circle", title: "Suspend Image Adjustments", checked: value.suspended) {
                var copy = value; copy.suspended.toggle(); controller.setAdjustments(copy, for: display)
            }
            MenuRow(symbol: "arrow.uturn.backward.circle", title: "Reset Image Adjustments",
                    enabled: value != .neutral) {
                controller.resetImageAdjustments(for: display)
            }
        }
    }

    private func adjustment(_ title: String, _ symbol: String, neutral: Double, text: String,
                            _ binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 3)
            CapsuleSlider(value: binding, symbol: symbol,
                          markers: neutral < 1 ? [SliderMarker(position: neutral, label: "Neutral")] : [],
                          height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }
}

private extension Double {
    var gammaSlider: Double { (self - 0.4) / 1.8 }
}

// MARK: - DDC device control

struct DeviceControlPanel: View {
    let display: DisplayInfo
    @ObservedObject private var controller = DisplayController.shared

    private var info: DisplayController.DDCInfo? { controller.ddcInfo[display.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let caps = info?.capabilities
            if let modes = caps?.codes[DisplayController.pictureModeCode], !modes.isEmpty {
                MenuCaption(text: "Picture Mode")
                let current = controller.ddcValue(DisplayController.pictureModeCode, for: display.id)?.current
                ForEach(modes, id: \.self) { value in
                    MenuRow(symbol: nil, title: DDCValueNames.pictureMode(value), checked: current == value) {
                        controller.setDDC(code: DisplayController.pictureModeCode, raw: value, for: display)
                    }
                }
            }
            if let presets = caps?.codes[DDCController.VCP.colorPreset.rawValue], !presets.isEmpty {
                MenuCaption(text: "Color Preset")
                let current = controller.ddcValue(DDCController.VCP.colorPreset.rawValue, for: display.id)?.current
                ForEach(presets, id: \.self) { value in
                    MenuRow(symbol: nil, title: DDCValueNames.colorPreset(value), checked: current == value) {
                        controller.setDDC(code: DDCController.VCP.colorPreset.rawValue, raw: value, for: display)
                    }
                }
            }

            let sliders: [(DDCController.VCP, String, String)] = [
                (.redGain, "Gain (Red, Hardware)", "r.circle"),
                (.greenGain, "Gain (Green, Hardware)", "g.circle"),
                (.blueGain, "Gain (Blue, Hardware)", "b.circle"),
                (.sharpness, "Sharpness", "triangle.lefthalf.filled"),
            ]
            let available = sliders.filter { controller.ddcValue($0.0.rawValue, for: display.id) != nil }
            if !available.isEmpty {
                MenuCaption(text: "Hardware Adjustments")
                ForEach(available, id: \.0) { vcp, title, symbol in
                    ddcSlider(vcp.rawValue, title: title, symbol: symbol)
                }
                if !(info?.values.isEmpty ?? true), caps == nil {
                    Text("Reading the monitor's capabilities…")
                        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14)
                }
            } else if caps == nil {
                Text("Reading the monitor's capabilities…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }

            MenuDivider()
            if caps == nil || caps?.supports(.powerMode) == true {
                MenuRow(symbol: "powersleep", title: "Put Display in Standby") {
                    confirm("Put \(display.name) in standby?",
                            "The monitor turns off its panel. It wakes on signal or from its power button.",
                            "Standby") {
                        controller.sendDDCCommand(code: DDCController.VCP.powerMode.rawValue, value: 0x04, for: display)
                    }
                }
            }
            if caps == nil || caps?.supports(.restoreColor) == true {
                MenuRow(symbol: "paintpalette", title: "Restore Color Defaults") {
                    confirm("Restore \(display.name)'s color defaults?", "The monitor resets its color settings.", "Restore") {
                        controller.sendDDCCommand(code: DDCController.VCP.restoreColor.rawValue, value: 1, for: display)
                    }
                }
            }
            if caps == nil || caps?.supports(.restoreBrightnessContrast) == true {
                MenuRow(symbol: "sun.max", title: "Restore Brightness and Contrast") {
                    confirm("Restore brightness and contrast on \(display.name)?", "The monitor resets both to its defaults.", "Restore") {
                        controller.sendDDCCommand(code: DDCController.VCP.restoreBrightnessContrast.rawValue, value: 1, for: display)
                    }
                }
            }
            if caps == nil || caps?.supports(.restoreFactoryDefaults) == true {
                MenuRow(symbol: "arrow.counterclockwise", title: "Restore Factory Defaults") {
                    confirm("Restore factory defaults on \(display.name)?",
                            "All monitor settings return to factory values. This cannot be undone from the Mac.",
                            "Restore Defaults") {
                        controller.sendDDCCommand(code: DDCController.VCP.restoreFactoryDefaults.rawValue, value: 1, for: display)
                    }
                }
            }
            if let caps {
                Text("\(caps.model ?? "Monitor") · MCCS \(caps.mccsVersion ?? "?") · \(caps.codes.count) VCP codes")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
            }
        }
    }

    private func ddcSlider(_ code: UInt8, title: String, symbol: String) -> some View {
        let value = controller.ddcValue(code, for: display.id)
        let maximum = max(1, value?.maximum ?? 100)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(value?.current ?? 0)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 3)
            CapsuleSlider(value: Binding(get: { controller.ddcValue(code, for: display.id)?.fraction ?? 0 },
                                         set: { controller.setDDC(code: code, raw: Int(($0 * Double(maximum)).rounded()), for: display) }),
                          symbol: symbol, height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private func confirm(_ title: String, _ message: String, _ button: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}
