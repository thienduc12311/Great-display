import SwiftUI
import AppKit
import GDCore
import ServiceManagement

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var sleep = SleepController.shared
    @State private var launchAtLogin = Self.loginItemRegistered
    @State private var status: String?
    @State private var showDiagnostics = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "Startup, behaviour, brightness method and permissions",
                     symbol: "gearshape.fill", tint: .gray) {
            SettingsSectionTitle(title: "Startup", symbol: "power")
            SettingsCard {
                SettingsToggleRow(title: "Launch at login", help: "Starts Great Display when you log in.",
                                  isOn: Binding(get: { launchAtLogin }, set: { updateLoginItem($0) }))
                SettingsRowDivider()
                SettingsToggleRow(title: "Restore display configuration on launch",
                                  help: "Re-applies saved resolutions, arrangement and main display.",
                                  isOn: $store.state.general.restoreConfigurationOnLaunch)
                if let status {
                    Text(status).font(.caption).foregroundStyle(.red).padding(.horizontal, SettingsStyle.rowInset).padding(.bottom, 8)
                }
            }

            SettingsSectionTitle(title: "Behaviour", symbol: "switch.2")
            SettingsCard {
                SettingsToggleRow(title: "Prevent sleep", help: "Keeps the Mac and its displays awake while Great Display runs.",
                                  isOn: Binding(get: { sleep.isPreventingSleep }, set: { sleep.setPreventSleep($0) }))
                SettingsRowDivider()
                SettingsToggleRow(title: "Reconnect disconnected displays when quitting",
                                  isOn: $store.state.general.reconnectDisplaysOnQuit)
            }

            SettingsSectionTitle(title: "Brightness Method", symbol: "sun.max")
            SettingsCard {
                BrightnessMethodPicker()
                SettingsRowDivider()
                SettingsToggleRow(title: "Continue below the hardware minimum",
                                  help: "One brightness control that keeps dimming with software after the backlight reaches its lowest level.",
                                  isOn: $store.state.general.combinedBrightness,
                                  enabled: store.state.general.softwareDimmingEnabled)
            }

            SettingsSectionTitle(title: "Permissions", symbol: "lock.shield")
            SettingsCard {
                PermissionRow(title: "Screen Recording",
                              detail: "Needed to stream a screen into a window on another display. Relaunch after granting.",
                              granted: FullScreenStreamController.shared.hasScreenRecordingPermission,
                              settingsAnchor: "Privacy_ScreenCapture")
                SettingsRowDivider()
                PermissionRow(title: "Accessibility",
                              detail: "Needed for the brightness and volume keys.",
                              granted: KeyboardController.shared.trusted,
                              settingsAnchor: "Privacy_Accessibility")
            }

            SettingsSectionTitle(title: "This Window", symbol: "macwindow")
            SettingsCard {
                SettingsToggleRow(title: "Show explanations under settings",
                                  help: "When off, explanations move behind an ⓘ button next to each setting.",
                                  isOn: $store.state.general.showHelp)
            }

            SettingsSectionTitle(title: "Troubleshooting", symbol: "stethoscope")
            SettingsCard {
                DisclosureGroup(isExpanded: $showDiagnostics) {
                    VStack(spacing: 0) {
                        diagnostic("DDC/CI transport", DDCController.shared.isSupported)
                        diagnostic("DisplayServices client", BrightnessEngine.shared.hasDisplayServices)
                        diagnostic("Display connection control", DisplayManager.shared.canDisconnect)
                        diagnostic("Virtual displays", VirtualScreenManager.shared.isSupported)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("System capabilities").font(.system(size: 13))
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 10)
                SettingsRowDivider()
                SettingsRow(title: "Reset all saved settings",
                            help: "Removes saved configurations, color adjustments, per-display preferences and virtual screens.") {
                    Button("Reset…", role: .destructive) { confirmReset() }
                }
            }
        }
    }

    private func diagnostic(_ title: String, _ available: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            StatusChip(text: available ? "Available" : "Unavailable",
                       symbol: available ? "checkmark" : "xmark",
                       tint: available ? .green : .red)
        }
        .padding(.vertical, 5)
    }

    private static var loginItemRegistered: Bool {
        let state = SMAppService.mainApp.status
        return state == .enabled || state == .requiresApproval
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            // Pending approval still means registered, so switching off must
            // unregister it instead of treating it as already disabled.
            if enabled != Self.loginItemRegistered {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            }
            status = nil
        } catch {
            status = "Could not update the login item: \(error.localizedDescription)"
        }
        // Only the binding setter performs system actions. Updating these
        // values after an error cannot trigger another registration attempt.
        launchAtLogin = Self.loginItemRegistered
        store.state.general.launchAtLogin = launchAtLogin
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all saved settings?"
        alert.informativeText = "Everything returns to its defaults: application, menu and keyboard preferences, saved display configurations, image adjustments, per-display preferences, stream options and virtual screen definitions. Connected virtual screens are disconnected and running streams stop."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let controller = DisplayController.shared
            for display in controller.displays { controller.resetImageAdjustments(for: display) }
            // Their definitions are about to go: a screen or stream left
            // running would have no page to stop it from.
            FullScreenStreamController.shared.stopAll()
            VirtualScreenManager.shared.destroyAll()
            store.resetAll()
            // Brightness key handling is on by default again; the tap only
            // starts here when Accessibility access is already granted.
            if store.state.general.handleBrightnessKeys { _ = KeyboardController.shared.start() }
        }
    }
}

/// Two big choices instead of a cryptic toggle: hardware only, or hardware + software.
private struct BrightnessMethodPicker: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        HStack(spacing: 10) {
            option(title: "Hardware + software", detail: "Works on every display. Can clip HDR content.",
                   symbol: "sun.max.trianglebadge.exclamationmark", value: true)
            option(title: "Hardware only", detail: "Backlight and DDC only. No color adjustments.",
                   symbol: "lightbulb", value: false)
        }
        .padding(12)
    }

    private func option(title: String, detail: String, symbol: String, value: Bool) -> some View {
        let selected = store.state.general.softwareDimmingEnabled == value
        return Button { store.state.general.softwareDimmingEnabled = value } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let settingsAnchor: String

    var body: some View {
        SettingsRow(title: title, help: detail) {
            HStack(spacing: 8) {
                StatusChip(text: granted ? "Granted" : "Not granted",
                           symbol: granted ? "checkmark" : "exclamationmark",
                           tint: granted ? .green : .orange)
                if !granted {
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Menu Bar

struct MenuSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        SettingsPage(title: "Menu Bar", subtitle: "Choose what the menu shows. The preview updates as you go.",
                     symbol: "menubar.rectangle", tint: .teal) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(title: "Sliders", symbol: "slider.horizontal.3")
                    SettingsCard {
                        SettingsToggleRow(title: "Resolution", help: "Shown under brightness.",
                                          isOn: $store.state.general.showResolutionSlider)
                        SettingsRowDivider()
                        SettingsToggleRow(title: "Contrast", help: "Hardware contrast over DDC, software contrast otherwise.",
                                          isOn: $store.state.general.showContrastSlider)
                        SettingsRowDivider()
                        SettingsToggleRow(title: "Volume", help: "For monitors with speakers controlled over DDC.",
                                          isOn: $store.state.general.showVolumeSlider)
                    }
                    SettingsSectionTitle(title: "Layout", symbol: "rectangle.grid.1x2")
                    SettingsCard {
                        SettingsToggleRow(title: "Open one display at a time", isOn: $store.state.general.singleExpandedSection)
                        SettingsRowDivider()
                        SettingsToggleRow(title: "Show the display header with one display", isOn: $store.state.general.alwaysShowDeviceHeader)
                        SettingsRowDivider()
                        SettingsToggleRow(title: "Quit button", isOn: $store.state.general.showQuitButton)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(title: "Preview", symbol: "eye")
                    MenuPreviewMock()
                }
                .frame(width: 250)
            }

            SettingsSectionTitle(title: "Menu Bar Icon", symbol: "menubar.dock.rectangle")
            SettingsCard {
                SettingsToggleRow(title: "Show brightness percentage next to the icon", isOn: $store.state.general.menuBarShowsPercentage)
                SettingsRowDivider()
                HStack(spacing: 18) {
                    shortcut("cursorarrow.click", "Click", "Open the menu")
                    shortcut("option", "⌥ Click", "Open Settings")
                    shortcut("cursorarrow.click.2", "Right-click", "Quick menu")
                }
                .padding(.horizontal, SettingsStyle.rowInset)
                .padding(.vertical, 10)
            }

            SettingsSectionTitle(title: "Resolution Changes", symbol: "aspectratio")
            SettingsCard {
                SettingsToggleRow(title: "Hide resolutions below 720 pixels high", isOn: $store.state.general.hideLowResolutions)
                SettingsRowDivider()
                SettingsToggleRow(title: "Fade the display while changing resolution",
                                  help: "Only the display being changed fades out and back in.",
                                  isOn: $store.state.general.fadeOnModeChange,
                                  enabled: store.state.general.softwareDimmingEnabled)
            }
        }
    }

    private func shortcut(_ symbol: String, _ gesture: String, _ result: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1)))
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture).font(.system(size: 12, weight: .semibold))
                Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Schematic of the app menu reflecting the toggles beside it.
private struct MenuPreviewMock: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let general = store.state.general
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "sun.max.fill").font(.system(size: 10))
                    if general.menuBarShowsPercentage { Text("72%").font(.system(size: 10, weight: .medium)) }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "display").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    Text("Studio Display").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                bar("sun.max.fill", 0.72)
                if general.showResolutionSlider { bar("aspectratio", 0.5) }
                if general.showContrastSlider { bar("circle.lefthalf.filled", 0.6) }
                if general.showVolumeSlider { bar("speaker.wave.2.fill", 0.35) }
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "display").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("MacBook Pro").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .opacity(general.singleExpandedSection ? 1 : 0.7)
                Divider()
                HStack {
                    Text("Settings…").font(.system(size: 11))
                    Spacer()
                    if general.showQuitButton {
                        Text("Quit").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color.blue.opacity(0.25), Color.purple.opacity(0.2)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .animation(.easeOut(duration: 0.18), value: general)
    }

    private func bar(_ symbol: String, _ value: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 12)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * value)
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Keyboard & OSD

struct KeyboardSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var keyboard = KeyboardController.shared
    @State private var resetNote: String?

    private static let steps: [(label: String, value: Double)] = [
        ("Fine", 1.0 / 32), ("Standard", 1.0 / 16), ("Coarse", 1.0 / 10), ("Large", 1.0 / 8),
    ]

    var body: some View {
        SettingsPage(title: "Keyboard & OSD", subtitle: "Brightness and volume keys, step size and on-screen feedback",
                     symbol: "keyboard.fill", tint: .indigo) {
            accessStatus

            if !keyboard.conflictingApps.isEmpty {
                let names = keyboard.conflictingApps.compactMap(\.localizedName).joined(separator: " and ")
                Callout(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: "\(names) also controls the brightness keys",
                        message: "Only one app can handle them; the other never sees the key press. Quit \(names), or turn off its keyboard control.") {
                    ForEach(keyboard.conflictingApps, id: \.processIdentifier) { app in
                        Button("Quit \(app.localizedName ?? "App")") {
                            app.terminate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { keyboard.refreshConflicts() }
                        }
                    }
                }
            }

            SettingsSectionTitle(title: "Keys", symbol: "sun.max")
            SettingsCard {
                SettingsToggleRow(title: "Control displays with the brightness keys",
                                  help: "Also handles F14/F15 on PC keyboards. Volume keys control the monitor's DDC volume when audio plays through it.",
                                  isOn: $store.state.general.handleBrightnessKeys)
                    .onChange(of: store.state.general.handleBrightnessKeys) { _, enabled in
                        if enabled { _ = keyboard.start() } else { keyboard.stop() }
                    }
                SettingsRowDivider()
                SettingsRow(title: "Step size", help: "How much one key press changes brightness.") {
                    Picker("", selection: stepBinding) {
                        ForEach(Self.steps, id: \.value) { step in
                            Text(step.label).tag(step.value)
                        }
                        if !Self.steps.contains(where: { abs($0.value - store.state.general.brightnessStep) < 0.0005 }) {
                            Text("Custom").tag(store.state.general.brightnessStep)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 280)
                }
                SettingsRowDivider()
                SettingsSliderRow(title: "Fine-tune step", value: $store.state.general.brightnessStep, range: 0.01...0.25,
                                  text: "\(Int((store.state.general.brightnessStep * 100).rounded()))%")
            }

            SettingsSectionTitle(title: "On-Screen Display", symbol: "rectangle.inset.filled")
            SettingsCard {
                SettingsToggleRow(title: "Show on-screen feedback", isOn: $store.state.general.showOSD)
                SettingsRowDivider()
                SettingsSliderRow(title: "Visible for", value: $store.state.general.osdDuration, range: 0.5...4,
                                  text: String(format: "%.1f s", store.state.general.osdDuration))
                    .disabled(!store.state.general.showOSD)
                    .opacity(store.state.general.showOSD ? 1 : 0.55)
                SettingsRowDivider()
                SettingsButtonRow {
                    Button {
                        OSDController.shared.show(symbol: "sun.max.fill", title: "Brightness", value: 0.65)
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .disabled(!store.state.general.showOSD)
                }
            }
        }
        .onAppear { keyboard.checkTrust() }
    }

    private var stepBinding: Binding<Double> {
        Binding(get: {
            let current = store.state.general.brightnessStep
            return Self.steps.first(where: { abs($0.value - current) < 0.0005 })?.value ?? current
        }, set: { store.state.general.brightnessStep = $0 })
    }

    @ViewBuilder
    private var accessStatus: some View {
        if keyboard.trusted {
            Callout(symbol: "checkmark.shield.fill", tint: .green,
                    title: "Accessibility access granted",
                    message: keyboard.isTapRunning ? "The brightness and volume keys are active." : "Switch on the brightness keys below to use them.") {
                EmptyView()
            }
        } else {
            Callout(symbol: "exclamationmark.shield.fill", tint: .orange,
                    title: "Allow Accessibility access to use the keys",
                    message: "1. Click Open Privacy Settings.  2. Switch on Great Display.  Already on? That entry belongs to an earlier build: click Reset, then allow it again." + (resetNote.map { "\n\($0)" } ?? "")) {
                Button("Reset") {
                    keyboard.resetAccessibilityPermission(bundleIdentifier: Bundle.main.bundleIdentifier ?? "app.greatdisplay.GreatDisplay")
                    _ = keyboard.requestAccess()
                    resetNote = "Permission reset. Enable Great Display in the dialog or in System Settings."
                }
                Button("Open Privacy Settings") {
                    _ = keyboard.requestAccess()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        DetailScroll {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                Text("Great Display").font(.system(size: 26, weight: .bold))
                StatusChip(text: "Version \(version)", tint: .secondary)
                Text("A menu bar display manager for macOS: resolution, HiDPI, brightness, DDC/CI, color adjustments and virtual screens.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 10) {
                    link("Website", "globe", "https://thienduc12311.github.io/Great-display/")
                    link("Release Notes", "doc.text", "https://thienduc12311.github.io/Great-display/release-notes.html")
                    link("Source Code", "chevron.left.forwardslash.chevron.right", "https://github.com/thienduc12311/Great-display")
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            Text("Independent, open-source implementation. Uses public display APIs plus system-private display services resolved at runtime; those can change between macOS releases.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func link(_ title: String, _ symbol: String, _ url: String) -> some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            Label(title, systemImage: symbol)
        }
        .controlSize(.large)
    }
}
