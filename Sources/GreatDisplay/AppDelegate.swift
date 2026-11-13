import AppKit
import SwiftUI
import GDCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private var settings: SettingsWindowController?
    private var previewWindow: NSWindow?
    private var volumeRoutingTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menuBar = MenuBarController()
        settings = SettingsWindowController.shared
        menuBar?.onOpenSettings = { [weak self] pane in
            self?.settings?.show(pane: pane)
        }

        DisplayController.shared.start()
        // Streams resume on connect and associated virtual screens follow their
        // display from launch on.
        _ = FullScreenStreamController.shared

        let general = SettingsStore.shared.state.general
        let keyboard = KeyboardController.shared
        keyboard.onTrustChanged = { trusted in
            // Granting (or revoking) Accessibility takes effect without a relaunch.
            if trusted && SettingsStore.shared.state.general.handleBrightnessKeys {
                _ = keyboard.start()
            } else if !trusted {
                keyboard.stop()
            }
        }
        // The tap runs on its own thread: act on the main actor asynchronously,
        // and keep the routing decision cached for the tap to read.
        keyboard.onVolumeKey = { key in
            DispatchQueue.main.async { DisplayController.shared.handleVolumeKey(key) }
        }
        volumeRoutingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                KeyboardController.shared.setVolumeKeyRouting(DisplayController.shared.volumeKeyTarget() != nil)
            }
        }
        keyboard.startMonitoringTrust()
        keyboardLog.notice("launch: trusted=\(AXIsProcessTrusted(), privacy: .public) handleBrightnessKeys=\(general.handleBrightnessKeys, privacy: .public) screenRecording=\(CGPreflightScreenCaptureAccess(), privacy: .public)")
        if general.handleBrightnessKeys {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                _ = keyboard.start()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            DisplayController.shared.restoreSavedConfigurations()
        }

        if general.preventSleep {
            SleepController.shared.setPreventSleep(true)
        }

        if CommandLine.arguments.contains("--preview-menu") {
            let hosting = NSHostingController(rootView: MenuView(onOpenSettings: { [weak self] pane in
                self?.settings?.show(pane: pane)
            }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Great Display"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--render-menu"),
           CommandLine.arguments.count > index + 1 {
            renderMenuSnapshot(to: CommandLine.arguments[index + 1],
                               options: Array(CommandLine.arguments.dropFirst(index + 2)))
        }

        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.settings?.show()
            }
        }
    }

    /// Creates a temporary virtual screen, self-streams it with options, checks
    /// frames arrive and options apply live, then removes everything. Runs in
    /// the app because capture needs the app's Screen Recording permission.
    private func runStreamSelfTest() {
        Task { @MainActor in
            func log(_ text: String) { keyboardLog.notice("stream-test: \(text, privacy: .public)") }
            var configuration = VirtualScreenConfiguration()
            configuration.name = "Great Display Stream Test"
            configuration.width = 1280
            configuration.height = 720
            let store = SettingsStore.shared
            let saved = store.state
            guard let id = VirtualScreenManager.shared.create(configuration) else { log("FAIL create"); return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            DisplayManager.shared.refresh()
            guard let display = DisplayManager.shared.display(id: id) else { log("FAIL display missing"); return }
            var options = FullScreenStreamController.shared.configuration(forSource: display)
            options.flipHorizontal = true
            options.rotation = 90
            options.filter = .monochrome
            options.zoom = 1.5
            FullScreenStreamController.shared.update(options)
            let started = await FullScreenStreamController.shared.start(source: id, on: id, activate: false)
            log(started ? "PASS self-stream started" : "FAIL start: \(FullScreenStreamController.shared.lastError ?? "?")")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let info = FullScreenStreamController.shared.diagnostics(source: id) {
                log("\(info.frames > 0 ? "PASS" : "FAIL") frames shown: \(info.frames)")
                log("PASS layer bounds \(Int(info.layerBounds.width))×\(Int(info.layerBounds.height)), transform m11=\(info.transform.m11) m12=\(info.transform.m12)")
                let menuLevel = NSWindow.Level.popUpMenu.rawValue
                log("\(info.level < menuLevel ? "PASS" : "FAIL") self-stream window level \(info.level) is below menus/popovers (\(menuLevel))")
                let streamLevel = FullScreenStreamController.streamLevel.rawValue
                log("\(streamLevel > NSWindow.Level.statusBar.rawValue && streamLevel < menuLevel ? "PASS" : "FAIL") display-stream level \(streamLevel) covers the menu bar (\(NSWindow.Level.statusBar.rawValue)) and stays below menus (\(menuLevel))")
                options.rotation = 0
                options.flipHorizontal = false
                options.zoom = 1
                options.alpha = 0.5
                options.targetFPS = 30
                FullScreenStreamController.shared.update(options)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let after = FullScreenStreamController.shared.diagnostics(source: id) {
                    log("\(after.frames > info.frames ? "PASS" : "FAIL") still streaming after live update (\(after.frames) frames), m11=\(after.transform.m11)")
                }
            }
            FullScreenStreamController.shared.stop(source: id)
            VirtualScreenManager.shared.destroy(configuration.id)
            store.state = saved
            store.saveNow()
            log("done")
        }
    }

    /// Association settings between two temporary virtual screens (nothing
    /// physical changes): connect while offline, disconnect when the associated
    /// display appears, then auto-connect + enforce mirroring + follow orientation.
    private func runAssociationTest() {
        Task { @MainActor in
            func log(_ text: String) { keyboardLog.notice("association-test: \(text, privacy: .public)") }
            func check(_ name: String, _ ok: Bool, _ detail: String = "") { log("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
            func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            let store = SettingsStore.shared
            let saved = store.state
            store.persistenceEnabled = false
            let manager = VirtualScreenManager.shared

            var portrait = VirtualScreenConfiguration()
            portrait.name = "GD Portrait"; portrait.width = 1080; portrait.height = 1920
            var follower = VirtualScreenConfiguration()
            follower.name = "GD Follower"; follower.width = 1920; follower.height = 1080
            follower.associatedDisplayIdentities = ["22136-4660-\(portrait.serialNumber)"]
            follower.connectWithAssociated = false
            follower.connectWhenAssociatedOffline = true
            store.state.virtualScreens.append(follower)
            for _ in 0..<20 where !manager.isActive(follower) { await wait(0.25) }
            check("connects while the associated display is offline", manager.isActive(follower))

            store.state.virtualScreens.append(portrait)
            _ = manager.create(portrait)
            for _ in 0..<24 where manager.isActive(follower) { await wait(0.25) }
            check("disconnects once the associated display is online", !manager.isActive(follower))

            if let index = store.state.virtualScreens.firstIndex(where: { $0.id == follower.id }) {
                store.state.virtualScreens[index].connectWhenAssociatedOffline = false
                store.state.virtualScreens[index].connectWithAssociated = true
                store.state.virtualScreens[index].enforceMirroring = true
                store.state.virtualScreens[index].followOrientation = true
            }
            var current: VirtualScreenConfiguration?
            for _ in 0..<40 {
                await wait(0.25)
                current = store.state.virtualScreens.first { $0.id == follower.id }
                if let current, let vid = manager.displayID(for: current),
                   DisplayManager.shared.mirrorTarget(for: vid) != nil, current.height > current.width { break }
            }
            check("auto-connects with the associated display", current.map(manager.isActive) ?? false)
            check("follows the associated display's orientation", (current?.height ?? 0) > (current?.width ?? 0),
                  current?.pixelDescription ?? "-")
            let mirrored = current.flatMap(manager.displayID(for:)).flatMap(DisplayManager.shared.mirrorTarget(for:))
            check("enforces mirroring onto the associated display",
                  mirrored != nil && mirrored == manager.displayID(for: portrait))

            for configuration in [follower, portrait] { manager.destroy(configuration.id) }
            store.state = saved
            store.persistenceEnabled = true
            log("done")
        }
    }

    /// Streams one temporary virtual screen onto another (both invisible) and
    /// checks the pointer mapping and routing of an interactive stream.
    private func runStreamRouteTest() {
        Task { @MainActor in
            func log(_ text: String) { keyboardLog.notice("route-test: \(text, privacy: .public)") }
            let store = SettingsStore.shared
            let saved = store.state
            store.persistenceEnabled = false
            defer {
                store.state = saved
                store.persistenceEnabled = true
            }
            var a = VirtualScreenConfiguration(); a.name = "GD Route Source"; a.width = 1280; a.height = 720
            var b = VirtualScreenConfiguration(); b.name = "GD Route Target"; b.width = 1920; b.height = 1080
            guard let sourceID = VirtualScreenManager.shared.create(a),
                  let targetID = VirtualScreenManager.shared.create(b) else { log("FAIL create"); return }
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            DisplayManager.shared.refresh()
            let streams = FullScreenStreamController.shared
            guard let sourceInfo = DisplayManager.shared.display(id: sourceID) else { log("FAIL source missing"); return }
            var options = streams.configuration(forSource: sourceInfo)
            options.interactive = true
            streams.update(options)
            let started = await streams.start(source: sourceID, on: targetID, activate: false)
            log(started ? "PASS interactive stream started" : "FAIL start \(streams.lastError ?? "")")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let stream = streams.stream(for: sourceID) else { return }
            let target = CGDisplayBounds(targetID), source = CGDisplayBounds(sourceID)

            for (rotation, flip) in [(0, false), (90, true), (270, false)] {
                options.rotation = rotation; options.flipHorizontal = flip
                streams.update(options)
                let probe = CGPoint(x: target.midX - 40, y: target.midY + 60)   // inside the picture at any rotation
                if let s = streams.mapToSource(stream, probe), let back = streams.mapToTarget(stream, s) {
                    let error = hypot(back.x - probe.x, back.y - probe.y)
                    log("\(error < 3 && source.contains(s) ? "PASS" : "FAIL") round trip rotation \(rotation)\(flip ? " flipped" : ""): error \(String(format: "%.2f", error)) pt")
                } else {
                    log("FAIL mapping unavailable")
                }
            }
            options.rotation = 0; options.flipHorizontal = false
            streams.update(options)

            let original = CGEvent(source: nil)?.location ?? .zero
            CGWarpMouseCursorPosition(CGPoint(x: target.midX, y: target.midY))
            streams.routePointerForTesting(dx: 0, dy: 0)
            let entered = CGEvent(source: nil)?.location ?? .zero
            log("\(source.contains(entered) ? "PASS" : "FAIL") pointer entering the stream moves onto the source (\(Int(entered.x)), \(Int(entered.y)))")
            CGWarpMouseCursorPosition(CGPoint(x: source.maxX - 1, y: source.midY))
            streams.routePointerForTesting(dx: 6, dy: 0)
            let left = CGEvent(source: nil)?.location ?? .zero
            log("\(!source.contains(left) ? "PASS" : "FAIL") pushing out of the source's edge leaves the stream (\(Int(left.x)), \(Int(left.y)))")
            CGWarpMouseCursorPosition(original)
            CGAssociateMouseAndMouseCursorPosition(1)

            streams.stop(source: sourceID)
            VirtualScreenManager.shared.destroy(a.id)
            VirtualScreenManager.shared.destroy(b.id)
            log("done")
        }
    }

    /// Development aid: renders the menu (optionally expanded) into a PNG.
    /// Options: `more` opens more options on the first display, `feature=<name>`
    /// opens a feature panel there, `tools` shows Tools, `settings=<pane>` renders Settings (`tab=<picture|color|monitor|options>` picks the display tab).
    private func renderMenuSnapshot(to path: String, options: [String]) {
        // Capabilities take ~2 s to read; wait for them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let state = MenuState.shared
            let displays = DisplayController.shared.displays
            state.prepare(with: displays)
            SettingsStore.shared.persistenceEnabled = false
            if options.contains("vpage") {
                var temp = VirtualScreenConfiguration()
                temp.name = "Virtual 21:9"
                temp.width = 3440
                temp.height = 1440
                temp.associatedDisplayIdentity = displays.first(where: { !$0.isVirtual })?.identity
                temp.autoStream = true
                temp.followOrientation = true
                SettingsStore.shared.state.virtualScreens.append(temp)
                SettingsNavigation.shared.selection = .virtualScreen(temp.id)
            }
            let requested = options.first(where: { $0.hasPrefix("display=") }).flatMap { UInt32($0.dropFirst(8)) }
            if let first = displays.first(where: { $0.id == requested }) ?? displays.first(where: { $0.isMain }) ?? displays.first {
                state.expandedDevices = [first.identityKey]
                let key = first.identityKey
                if options.contains("more") { state.moreOptionsDevice = key }
                if let feature = options.first(where: { $0.hasPrefix("feature=") })?.dropFirst(8),
                   let value = MenuState.Feature(rawValue: String(feature)) {
                    state.moreOptionsDevice = key
                    state.openFeature = (key, value)
                }
            }
            if options.contains("tools") { state.showTools = true }

            let view: NSView
            if let pane = options.first(where: { $0.hasPrefix("settings=") })?.dropFirst(9) {
                switch options.contains("vpage") ? "vpage" : String(pane) {
                case "vpage": break
                case "display": SettingsNavigation.shared.selection = (displays.first(where: { $0.id == requested }) ?? displays.first).map { .display($0.id) }
                case "keyboard": SettingsNavigation.shared.selection = .keyboard
                case "application": SettingsNavigation.shared.selection = .application
                case "menu": SettingsNavigation.shared.selection = .menu
                case "virtual": SettingsNavigation.shared.selection = .virtualScreens
                default: SettingsNavigation.shared.selection = .displays
                }
                if let tab = options.first(where: { $0.hasPrefix("tab=") }).flatMap({ DisplayTab(rawValue: String($0.dropFirst(4))) }) {
                    SettingsNavigation.shared.displayTab = tab
                }
                let hosting: NSView
                if options.contains("vpage"), case .virtualScreen(let id) = SettingsNavigation.shared.selection {
                    // The whole virtual screen page, unscrolled.
                    let page = NSHostingView(rootView: VStack(alignment: .leading, spacing: 10) {
                        VirtualScreenPage(configurationID: id)
                    }
                    .padding(28)
                    .frame(width: 900)
                    .background(SettingsStyle.contentBackground))
                    page.frame = NSRect(x: 0, y: 0, width: 900, height: 2400)
                    page.frame.size = page.fittingSize
                    hosting = page
                } else {
                    let full = NSHostingView(rootView: SettingsView().frame(width: 1000, height: 760))
                    full.frame = NSRect(x: 0, y: 0, width: 1000, height: 760)
                    hosting = full
                }
                view = hosting
            } else {
                let hosting = NSHostingView(rootView: MenuView(onOpenSettings: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor)))
                hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
                view = hosting
            }
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: options.contains("dark") ? .darkAqua : (options.contains("light") ? .aqua : .darkAqua))
            if options.contains(where: { $0.hasPrefix("settings=") }) && !options.contains("dark") {
                window.appearance = NSAppearance(named: .aqua)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                view.layoutSubtreeIfNeeded()
                if !(view is NSHostingView<AnyView>), view.fittingSize.height > 10, options.allSatisfy({ !$0.hasPrefix("settings=") }) {
                    view.setFrameSize(NSSize(width: 320, height: view.fittingSize.height))
                    window.setContentSize(view.frame.size)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    view.layoutSubtreeIfNeeded()
                    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    exit(0)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if SettingsStore.shared.state.general.reconnectDisplaysOnQuit {
            DisplayManager.shared.reconnectAll()
        }
        BrightnessEngine.shared.resetAllSoftwareDimming()
        VirtualScreenManager.shared.destroyAll()
        SettingsStore.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "greatdisplay" {
            switch url.host?.lowercased() {
            case "settings", nil:
                settings?.show()
            case "display":
                if let id = url.pathComponents.dropFirst().first.flatMap(UInt32.init) {
                    settings?.show(pane: .display(id))
                } else {
                    settings?.show(pane: .displays)
                }
            case "menu":
                NotificationCenter.default.post(name: .greatDisplayShowMenu, object: nil)
            case "association-test":
                runAssociationTest()
            case "stream-route-test":
                runStreamRouteTest()
            case "stream-self-test":
                runStreamSelfTest()
            case "key-test":
                // Brightness down, then up again: net zero, exercises the tap.
                KeyboardController.shared.postBrightnessKey(up: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    KeyboardController.shared.postBrightnessKey(up: true)
                }
            case "brighten":
                DisplayController.shared.brightenAll()
            case "probe":
                DisplayController.shared.start()
            default:
                settings?.show()
            }
        }
    }
}
