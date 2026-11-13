import AppKit
import GDCore
import GDCBridge

private func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// A VCP code written in hex, with or without a `0x` prefix.
private func parseHexByte(_ text: String) -> UInt8? {
    let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
    return UInt8(digits, radix: 16)
}

/// Connection commands persist a settings snapshot. A running GUI owns a
/// separate snapshot, so it must be closed before the CLI changes this state.
private func connectionCommandCanRun() -> Bool {
    let bundleID = Bundle.main.bundleIdentifier ?? "app.greatdisplay.GreatDisplay"
    let otherApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
    guard !otherApp else {
        printError("Quit Great Display before using --disconnect or --reconnect, or use its display controls while it is running.")
        return false
    }
    return true
}

/// Command line helpers make the app testable without the menu bar UI.
@MainActor
func runCommandLine(_ arguments: [String]) -> Int32 {
    let command = arguments[1]

    switch command {
    case "--probe":
        let manager = DisplayManager.shared
        manager.refresh()
        var payload: [[String: Any]] = []
        for display in manager.displays {
            var entry: [String: Any] = [
                "id": display.id,
                "name": display.name,
                "vendor": String(format: "%04X", display.vendorID),
                "model": String(format: "%04X", display.modelID),
                "serial": display.serialNumber,
                "builtIn": display.isBuiltIn,
                "virtual": display.isVirtual,
                "main": display.isMain,
                "mirrored": display.isMirrored,
                "resolution": display.resolutionSummary,
                "scale": display.scaleSummary,
                "modeCount": display.modes.count,
                "nativeBrightness": display.hasHardwareBrightness,
                "ddc": display.hasDDC,
                "bounds": [display.bounds.origin.x, display.bounds.origin.y, display.bounds.width, display.bounds.height],
            ]
            if let value = BrightnessEngine.shared.hardwareBrightness(display.id) {
                entry["brightness"] = Double(value)
            }
            entry["softwareDimming"] = BrightnessEngine.shared.currentSoftwareDimming(display.id)
            entry["canRotate"] = gd_display_can_rotate(display.id) == 1
            entry["hdr"] = gd_display_has_hdr(display.id) == 1
            entry["modes"] = display.modes.map { mode in
                ["width": mode.width, "height": mode.height, "pixelWidth": mode.pixelWidth,
                 "pixelHeight": mode.pixelHeight, "hiDPI": mode.isHiDPI, "hz": mode.refreshRate]
            }
            payload.append(entry)
        }
        let root: [String: Any] = [
            "app": "Great Display",
            "displayCount": payload.count,
            "displayServices": BrightnessEngine.shared.hasDisplayServices,
            "ddcSupported": DDCController.shared.isSupported,
            "virtualDisplayAvailable": VirtualScreenManager.shared.isSupported,
            "displays": payload,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return 0

    case "--set-brightness":
        guard arguments.count >= 4,
              let id = UInt32(arguments[2]),
              let value = Double(arguments[3]), value.isFinite else {
            FileHandle.standardError.write(Data("usage: --set-brightness <displayID> <0..1>\n".utf8))
            return 2
        }
        DisplayManager.shared.refresh()
        guard let display = DisplayManager.shared.display(id: id) else {
            FileHandle.standardError.write(Data("unknown display \(id)\n".utf8))
            return 3
        }
        // Written synchronously and directly. The menu's controller only
        // learns on a later run-loop turn whether a monitor answers DDC, and
        // its gamma-table fallback would not outlive this process anyway.
        let level = max(0, min(1, value))
        guard BrightnessEngine.shared.setHardwareBrightness(Float(level), display: id) else {
            printError("\(display.name) has no hardware brightness control (native or DDC/CI)")
            return 4
        }
        print("brightness \(level) applied to \(display.name)")
        return 0

    case "--ddc-read":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --ddc-read <displayID>\n".utf8))
            return 2
        }
        guard DDCController.shared.hasService(for: id) else {
            print("no DDC service matched for display \(id)")
            return 3
        }
        // Optional extra hex codes: --ddc-read <id> 14 87
        let requested = arguments.dropFirst(3)
        let extra = requested.compactMap(parseHexByte)
        guard extra.count == requested.count else {
            printError("usage: --ddc-read <displayID> [vcpHex…]  (codes in hex, e.g. 14 or 0x14)")
            return 2
        }
        let codes: [UInt8] = extra.isEmpty
            ? DDCController.VCP.allCases.filter { ![.restoreFactoryDefaults, .restoreBrightnessContrast, .restoreColor].contains($0) }.map(\.rawValue)
            : extra
        for code in codes {
            let name = DDCController.VCP(rawValue: code)?.name ?? "VCP"
            let label = String(format: "%@ (0x%02X)", name, code).padding(toLength: 26, withPad: " ", startingAt: 0)
            switch DDCController.shared.reading(code: code, display: id) {
            case let .value(current, maximum): print("\(label) \(current)/\(maximum)")
            case .unsupported: print("\(label) unsupported")
            case .noReply: print("\(label) no reply")
            }
        }
        return 0

    case "--ddc-caps":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --ddc-caps <displayID>\n".utf8))
            return 2
        }
        let started = Date()
        guard let caps = DDCController.shared.capabilities(display: id) else {
            print("no capabilities reply")
            return 4
        }
        print(String(format: "read in %.2fs", Date().timeIntervalSince(started)))
        print("model: \(caps.model ?? "?")  type: \(caps.type ?? "?")  mccs: \(caps.mccsVersion ?? "?")")
        for code in caps.codes.keys.sorted() {
            let values = caps.codes[code] ?? []
            let name = DDCController.VCP(rawValue: code)?.name ?? ""
            print(String(format: "  0x%02X %@", code, name) + (values.isEmpty ? "" : "  values: " + values.map { String(format: "%02X", $0) }.joined(separator: " ")))
        }
        print("raw: \(caps.raw)")
        return 0

    case "--ddc-diag":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            printError("usage: --ddc-diag <displayID>")
            return 2
        }
        let results = DDCController.shared.probeAll(display: id)
        print("unit=\(CGDisplayUnitNumber(id)) services=\(results.count)")
        for result in results {
            let hex = result.bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            print("port=\(result.portIndex.map(String.init) ?? "?") write=\(result.writeResult) read=\(result.readResult) bytes=[\(hex)]")
        }
        return 0

    case "--ddc-write":
        guard arguments.count >= 5,
              let id = UInt32(arguments[2]),
              let code = parseHexByte(arguments[3]),
              let value = Int(arguments[4]), (0...0xFFFF).contains(value) else {
            FileHandle.standardError.write(Data("usage: --ddc-write <displayID> <vcpHex> <rawValue>\n".utf8))
            return 2
        }
        let ok = DDCController.shared.write(code: code, value: value, display: id)
        print(ok ? "write sent" : "write failed")
        return ok ? 0 : 4

    case "--stream-check":
        print("screenRecordingPermission=\(CGPreflightScreenCaptureAccess())")
        print("streaming=\(FullScreenStreamController.shared.active.count)")
        return 0

    case "--stream-test":
        guard arguments.count >= 4,
              let parsedWidth = Int(arguments[2]), (320...16384).contains(parsedWidth),
              let target = UInt32(arguments[3]) else {
            FileHandle.standardError.write(Data("usage: --stream-test <virtualWidth> <targetID> [holdSeconds]\n".utf8))
            return 2
        }
        let width = parsedWidth
        let hold = arguments.count > 4 ? (Double(arguments[4]) ?? 8.0) : 8.0
        guard CGPreflightScreenCaptureAccess() else {
            FileHandle.standardError.write(Data("""
            Screen Recording permission is not granted for this app.
            Enable it in System Settings > Privacy & Security > Screen Recording, then relaunch.
            """.utf8))
            return 6
        }
        var configuration = VirtualScreenConfiguration()
        configuration.name = "Great Display Stream Test"
        configuration.width = width
        configuration.height = width * 9 / 16
        guard let virtualID = VirtualScreenManager.shared.create(configuration) else {
            FileHandle.standardError.write(Data("could not create virtual display\n".utf8))
            return 5
        }
        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            DisplayManager.shared.refresh()
            if DisplayManager.shared.display(id: virtualID) != nil { break }
        }
        var finished = false
        var started = false
        Task { @MainActor in
            started = await FullScreenStreamController.shared.start(source: virtualID, on: target)
            print("stream start: \(started) \(FullScreenStreamController.shared.lastError ?? "")")
            finished = true
        }
        while !finished {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if started {
            RunLoop.main.run(until: Date().addingTimeInterval(hold))
            print("active streams: \(FullScreenStreamController.shared.active.count)")
            FullScreenStreamController.shared.stopAll()
        }
        VirtualScreenManager.shared.destroyAll()
        return started ? 0 : 7

    case "--mirror-demo":
        guard arguments.count >= 3, let targetID = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --mirror-demo <targetID> [holdSeconds]\n".utf8))
            return 2
        }
        let hold = arguments.count > 3 ? (Double(arguments[3]) ?? 6.0) : 6.0
        var configuration = VirtualScreenConfiguration()
        configuration.name = "Great Display Mirror Test"
        configuration.width = 1920
        configuration.height = 1080
        guard let virtualID = VirtualScreenManager.shared.create(configuration) else {
            FileHandle.standardError.write(Data("could not create virtual display\n".utf8))
            return 5
        }
        // Wait for the new display to appear in the inventory.
        for _ in 0..<20 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            DisplayManager.shared.refresh()
            if DisplayManager.shared.display(id: virtualID) != nil { break }
        }
        func describe(_ id: CGDirectDisplayID) -> String {
            guard let display = DisplayManager.shared.display(id: id) else { return "missing" }
            return "\(display.resolutionSummary) mirrored=\(display.isMirrored)"
        }
        print("virtual \(virtualID): \(describe(virtualID))")
        print("target before: \(describe(targetID))")
        let mirrored = DisplayManager.shared.setMirror(source: virtualID, on: targetID)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        DisplayManager.shared.refresh()
        print("mirror start: \(mirrored)  target now: \(describe(targetID))")
        RunLoop.main.run(until: Date().addingTimeInterval(hold))
        let stopped = DisplayManager.shared.setMirror(source: virtualID, on: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        DisplayManager.shared.refresh()
        print("mirror stop: \(stopped)  target restored: \(describe(targetID))")
        VirtualScreenManager.shared.destroyAll()
        return (mirrored && stopped) ? 0 : 4

    case "--rotate":
        guard arguments.count >= 4, let id = UInt32(arguments[2]), let degrees = Int(arguments[3]) else {
            FileHandle.standardError.write(Data("usage: --rotate <displayID> <0|90|180|270>\n".utf8))
            return 2
        }
        let ok = DisplayManager.shared.setRotation(degrees, for: id)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print(ok ? "rotation now \(gd_display_rotation(id))°" : (DisplayManager.shared.lastError ?? "rotation failed"))
        return ok ? 0 : 4

    case "--hdr":
        guard arguments.count >= 4, let id = UInt32(arguments[2]),
              ["on", "off"].contains(arguments[3].lowercased()) else {
            FileHandle.standardError.write(Data("usage: --hdr <displayID> on|off\n".utf8))
            return 2
        }
        let ok = DisplayManager.shared.setHDR(arguments[3].lowercased() == "on", for: id)
        print(ok ? "hdr \(DisplayManager.shared.isHDREnabled(id) ? "on" : "off")" : (DisplayManager.shared.lastError ?? "failed"))
        return ok ? 0 : 4

    case "--disconnect":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --disconnect <displayID> [reconnectAfterSeconds]\n".utf8))
            return 2
        }
        guard connectionCommandCanRun() else { return 4 }
        DisplayManager.shared.refresh()
        guard DisplayManager.shared.disconnect(id) else {
            print(DisplayManager.shared.lastError ?? "disconnect failed")
            return 4
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        DisplayManager.shared.refresh()
        print("disconnected; online displays: \(DisplayManager.shared.displays.map(\.id))")
        if arguments.count > 3, let seconds = Double(arguments[3]) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            let ok = DisplayManager.shared.reconnect(id)
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            DisplayManager.shared.refresh()
            print("reconnect \(ok ? "sent" : "failed"); online displays: \(DisplayManager.shared.displays.map(\.id))")
            return ok ? 0 : 4
        }
        // Record it where the app keeps its own disconnects, so the next
        // launch lists the display and can reconnect it.
        let store = SettingsStore.shared
        store.state.disconnectedDisplays.removeAll { $0.id == id }
        store.state.disconnectedDisplays.append(contentsOf: DisplayManager.shared.disconnected.filter { $0.id == id })
        store.saveNow()
        return 0

    case "--reconnect":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --reconnect <displayID>\n".utf8))
            return 2
        }
        guard connectionCommandCanRun() else { return 4 }
        let ok = DisplayManager.shared.reconnect(id)
        if ok {
            SettingsStore.shared.state.disconnectedDisplays.removeAll { $0.id == id }
            SettingsStore.shared.saveNow()
        }
        print(ok ? "reconnect sent" : (DisplayManager.shared.lastError ?? "failed"))
        return ok ? 0 : 4

    case "--system-colors":
        var changeResult: Int32 = 0
        if arguments.count >= 3 {
            let usage = "usage: --system-colors [dark|nightshift|truetone on|off]"
            guard arguments.count >= 4, ["on", "off"].contains(arguments[3].lowercased()) else {
                printError(usage)
                return 2
            }
            let on = arguments[3].lowercased() == "on"
            switch arguments[2].lowercased() {
            case "dark": changeResult = gd_set_dark_mode(on ? 1 : 0)
            case "nightshift": changeResult = gd_set_night_shift(on ? 1 : 0)
            case "truetone": changeResult = gd_set_true_tone(on ? 1 : 0)
            default:
                printError(usage)
                return 2
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        func describe(_ value: Int32) -> String { value < 0 ? "unavailable" : (value == 1 ? "on" : "off") }
        print("dark mode: \(describe(gd_dark_mode()))  night shift: \(describe(gd_night_shift()))  true tone: \(describe(gd_true_tone()))")
        if changeResult != 0 {
            printError("could not change \(arguments[2].lowercased()) (\(changeResult))")
            return 4
        }
        return 0

    case "--adjust":
        // --adjust <displayID> gamma=1.2 temperature=0.3 contrast=1.1 red=1 green=1 blue=0.9 invert=0 [hold]
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --adjust <displayID> key=value… [holdSeconds]\n".utf8))
            return 2
        }
        var adjustments = ImageAdjustments()
        var hold = 3.0
        for argument in arguments.dropFirst(3) {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { hold = Double(argument) ?? hold; continue }
            guard let value = Double(parts[1]), value.isFinite else {
                printError("invalid value in \"\(argument)\"")
                return 2
            }
            switch parts[0] {
            case "gamma": adjustments.gamma = value
            case "temperature": adjustments.temperature = value
            case "contrast": adjustments.contrast = value
            case "red": adjustments.redGain = value
            case "green": adjustments.greenGain = value
            case "blue": adjustments.blueGain = value
            case "invert": adjustments.invert = value > 0
            default: break
            }
        }
        hold = hold.isFinite ? max(0, min(3600, hold)) : 3.0
        BrightnessEngine.shared.setImageAdjustments(adjustments, display: id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
        var count: UInt32 = 0
        CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count)
        let mid = Int(count) / 2
        print(String(format: "applied; mid-grey now r=%.3f g=%.3f b=%.3f (holding %.0fs)", red[mid], green[mid], blue[mid], hold))
        RunLoop.main.run(until: Date().addingTimeInterval(hold))
        BrightnessEngine.shared.resetAllSoftwareDimming()
        CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count)
        print(String(format: "restored; mid-grey r=%.3f g=%.3f b=%.3f", red[mid], green[mid], blue[mid]))
        return 0

    case "--self-test":
        // Exercises the display features on a temporary virtual screen so no
        // physical display is rotated, disconnected or tinted.
        // The test drives the real controller, which saves per-display state;
        // put the user's saved settings back afterwards.
        // Nothing the test does is written to the user's settings.
        SettingsStore.shared.persistenceEnabled = false
        var configuration = VirtualScreenConfiguration()
        configuration.name = "Great Display Self Test"
        configuration.width = 1280
        configuration.height = 720
        guard let id = VirtualScreenManager.shared.create(configuration) else {
            print("FAIL virtual screen: \(VirtualScreenManager.shared.lastError ?? "?")")
            return 5
        }
        func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func online(_ id: CGDirectDisplayID) -> Bool {
            DisplayManager.shared.refresh()
            return DisplayManager.shared.display(id: id) != nil
        }
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        for _ in 0..<20 where !online(id) { wait(0.25) }
        wait(1.0)
        check("virtual screen online", online(id), "id \(id)")

        if let display = DisplayManager.shared.display(id: id) {
            let slider = DisplayManager.shared.sliderModes(for: display)
            check("resolution slider modes", slider.count >= 2, slider.map(\.resolutionText).joined(separator: ", "))
            let rates = DisplayManager.shared.refreshRates(for: display)
            check("refresh rates", !rates.isEmpty, rates.map(\.refreshText).joined(separator: ", "))
            let defaults = display.modes.filter(\.isDefault).map(\.resolutionText)
            check("default mode flag", !defaults.isEmpty, defaults.joined(separator: ", "))
        }

        // Smooth mode change: UI shows the target at once, the main thread keeps
        // running during the transaction, and dimming survives the change.
        DisplayController.shared.start()
        wait(0.5)
        if let display = DisplayController.shared.display(id),
           let target = DisplayManager.shared.sliderModes(for: display).first(where: { !$0.matches(display.currentMode) }) {
            BrightnessEngine.shared.applySoftwareDimming(0.6, display: id)
            wait(0.3)
            let started = Date()
            DisplayController.shared.setMode(target, for: display)
            let pending = DisplayController.shared.effectiveMode(for: display)
            check("menu shows target immediately", pending?.matches(target) == true, target.resolutionText)
            var ticks = 0
            var minimumMid: CGGammaValue = 1
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                ticks += 1
                var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
                var n: UInt32 = 0
                CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n)
                if n > 0 { minimumMid = min(minimumMid, r[Int(n) / 2]) }
            }
            for _ in 0..<40 where DisplayController.shared.pendingMode[id] != nil { wait(0.1) }
            timer.invalidate()
            let elapsed = Date().timeIntervalSince(started)
            let current = DisplayManager.shared.display(id: id)?.currentMode
            check("mode applied", current?.matches(target) == true,
                  "now \(current?.fullSummary ?? "none") target \(target.fullSummary) \(DisplayManager.shared.lastError ?? "")")
            check("main thread responsive during change", Double(ticks) > elapsed * 20,
                  String(format: "%d frames in %.2fs", ticks, elapsed))
            check("display faded during change", minimumMid < 0.1, String(format: "darkest mid-grey %.3f", minimumMid))
            wait(0.7)
            var r = [CGGammaValue](repeating: 0, count: 256), g = r, b = r
            var n: UInt32 = 0
            CGGetDisplayTransferByTable(id, 256, &r, &g, &b, &n)
            let mid = n > 0 ? r[Int(n) / 2] : 0
            check("dimming kept after mode change", abs(mid - 0.6 * 0.502) < 0.04, String(format: "mid-grey %.3f", mid))
            BrightnessEngine.shared.resetAllSoftwareDimming()
            wait(0.3)
        }

        // Flexible virtual resolutions and a live resize (same display ID).
        if let screen = VirtualScreenManager.shared.active.first(where: { $0.displayID == id }) {
            let sizes = DisplayManager.shared.display(id: id).map { Set($0.modes.map { "\($0.width)x\($0.height)" }).count } ?? 0
            check("flexible virtual modes", sizes >= 8, "\(sizes) sizes published")
            print("info virtual screen max framebuffer \(screen.maxPixels.wide) × \(screen.maxPixels.high)")
            var wider = screen.configuration
            wider.width = 2560
            wider.height = 1080
            VirtualScreenManager.shared.update(wider)
            wait(2.0)
            // This process's CoreGraphics cache does not see the new mode table
            // (no window-server notifications without an app run loop), so read
            // it the way any other app would: from a fresh process.
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            probe.arguments = ["--probe"]
            let pipe = Pipe()
            probe.standardOutput = pipe
            try? probe.run()
            // Read before waiting: the JSON is larger than the pipe buffer.
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
            let entry = (json?["displays"] as? [[String: Any]])?.first { ($0["id"] as? Int) == Int(id) }
            let modes = entry?["modes"] as? [[String: Any]] ?? []
            let wide = modes.contains {
                guard let w = $0["width"] as? Int, let h = $0["height"] as? Int, h > 0 else { return false }
                return ModeInfo.aspectLabel(width: w, height: h) == "21:9" || abs(Double(w) / Double(h) - 2.37) < 0.03
            }
            check("live resize keeps the display", entry != nil, "display \(id)")
            check("live resize publishes 21:9 modes", wide, "\(modes.count) modes, current \(entry?["resolution"] as? String ?? "-")")
        }

        // Associated display: a virtual screen tied to a physical display
        // connects on its own and takes that display's aspect ratio.
        if let physical = DisplayManager.shared.displays.first(where: { !$0.isVirtual }),
           let physicalMode = physical.currentMode {
            var associated = VirtualScreenConfiguration()
            associated.name = "Great Display Association Test"
            associated.width = 1920
            associated.height = 1080
            associated.associatedDisplayIdentity = physical.identity
            associated.connectWithAssociated = true
            associated.matchAssociatedAspect = true
            SettingsStore.shared.state.virtualScreens.append(associated)
            for _ in 0..<16 where !VirtualScreenManager.shared.isActive(associated) { wait(0.25) }
            check("associated virtual screen connects", VirtualScreenManager.shared.isActive(associated), "with \(physical.name)")
            let stored = SettingsStore.shared.state.virtualScreens.first { $0.id == associated.id }
            let expected = ModeInfo.aspectLabel(width: physicalMode.width, height: physicalMode.height)
            check("associated aspect matched", stored.map { ModeInfo.aspectLabel(width: $0.width, height: $0.height) } == expected,
                  "\(stored?.pixelDescription ?? "-") vs \(physical.name) \(expected)")
            VirtualScreenManager.shared.destroy(associated.id)
            SettingsStore.shared.state.virtualScreens.removeAll { $0.id == associated.id }
            wait(0.6)
        }

        let canRotate = DisplayManager.shared.canRotate(id)
        print("info rotation supported: \(canRotate)")
        if canRotate {
            _ = DisplayManager.shared.setRotation(90, for: id)
            wait(2.0)
            let rotated = Int(CGDisplayRotation(id))
            check("rotate to 90°", rotated == 90, "CGDisplayRotation \(rotated), bounds \(CGDisplayBounds(id).size)")
            _ = DisplayManager.shared.setRotation(0, for: id)
            wait(2.0)
            check("rotate back to 0°", Int(CGDisplayRotation(id)) == 0)
        }

        var adjustments = ImageAdjustments()
        adjustments.temperature = 1
        BrightnessEngine.shared.setImageAdjustments(adjustments, display: id)
        wait(0.4)
        var red = [CGGammaValue](repeating: 0, count: 256), green = red, blue = red
        var count: UInt32 = 0
        CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count)
        let mid = Int(count) / 2
        check("image adjustments (warm)", count > 0 && blue[mid] < red[mid] * 0.8,
              String(format: "mid-grey r=%.3f b=%.3f", red[mid], blue[mid]))
        BrightnessEngine.shared.resetAllSoftwareDimming()
        wait(0.3)
        CGGetDisplayTransferByTable(id, 256, &red, &green, &blue, &count)
        check("image adjustments reset", abs(red[mid] - blue[mid]) < 0.01)

        if arguments.contains("skip-disconnect") {
            print("info disconnect test skipped")
        } else if gd_display_enable_available() != 0 {
            let off = gd_display_set_enabled(id, 0)
            wait(2.0)
            check("logical disconnect", off == 0 && !online(id), "result \(off)")
            let on = gd_display_set_enabled(id, 1)
            for _ in 0..<12 where !online(id) { wait(0.25) }
            check("logical reconnect", on == 0 && online(id), "result \(on)")
        } else {
            check("display connection control available", false)
        }

        autoreleasepool { VirtualScreenManager.shared.destroyAll() }
        for _ in 0..<20 where online(id) { wait(0.25) }
        // Ask a fresh process: this one's CoreGraphics cache can lag.
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        verify.arguments = ["--probe"]
        let verifyPipe = Pipe()
        verify.standardOutput = verifyPipe
        try? verify.run()
        let verifyOutput = verifyPipe.fileHandleForReading.readDataToEndOfFile()
        verify.waitUntilExit()
        let remaining = ((try? JSONSerialization.jsonObject(with: verifyOutput)) as? [String: Any])?["displays"] as? [[String: Any]] ?? []
        check("virtual screen removed on disconnect",
              !remaining.contains { ($0["name"] as? String)?.hasPrefix("Great Display Self Test") == true })
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        return failures == 0 ? 0 : 1

    case "--audio-output":
        guard let device = AudioOutput.defaultDevice() else { print("no default output"); return 4 }
        print("default output: \(device.name)  displayAudio=\(device.isDisplayAudio)  softwareVolume=\(device.hasSoftwareVolume)")
        // A diagnostic: it must not save anything or connect the user's
        // virtual screens.
        SettingsStore.shared.persistenceEnabled = false
        let controller = DisplayController.shared
        controller.start(autoStartVirtualScreens: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print("volume keys → \(controller.volumeKeyTarget()?.name ?? "macOS (not routed to DDC)")")
        return 0

    case "--ddc-burst":
        // Simulates a fast slider drag on a DDC monitor and checks the writes
        // keep up: 30 changes in 0.6 s, then the monitor must hold the last one.
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --ddc-burst <displayID>\n".utf8))
            return 2
        }
        // A diagnostic: the brightness steps below must not be saved as the
        // display's setting, and the user's virtual screens stay as they are.
        SettingsStore.shared.persistenceEnabled = false
        let controller = DisplayController.shared
        controller.start(autoStartVirtualScreens: false)
        for _ in 0..<30 where !(controller.display(id).map(controller.ddcAvailable) ?? false) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard let display = controller.display(id), controller.ddcAvailable(display),
              let original = DDCController.shared.read(.brightness, display: id) else {
            print("display \(id) does not answer DDC")
            return 4
        }
        let start = Double(original.current) / Double(original.maximum)
        let target = max(0.05, start - 0.10)
        let began = Date()
        for step in 1...30 {
            controller.setBrightness(start + (target - start) * Double(step) / 30, for: display)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let issued = Date()
        controller.flushHardwareWrites()
        for _ in 0..<40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            controller.flushHardwareWrites()
            if DDCController.shared.read(.brightness, display: id).map({ abs(Double($0.current) / Double($0.maximum) - target) < 0.011 }) == true { break }
        }
        let settled = Date()
        let final = DDCController.shared.read(.brightness, display: id)
        print(String(format: "30 changes issued in %.2fs; monitor settled %.2fs after the last one at %d/%d (target %.0f)",
                     issued.timeIntervalSince(began), settled.timeIntervalSince(issued),
                     final?.current ?? -1, final?.maximum ?? -1, target * 100))
        _ = DDCController.shared.write(.brightness, value: original.current, display: id)
        print("restored brightness to \(original.current)")
        return 0

    case "--mirror":
        guard arguments.count >= 4, let source = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --mirror <sourceID> <targetID|off>\n".utf8))
            return 2
        }
        let target: CGDirectDisplayID? = arguments[3].lowercased() == "off" ? nil : UInt32(arguments[3])
        guard arguments[3].lowercased() == "off" || target != nil else {
            printError("usage: --mirror <sourceID> <targetID|off>")
            return 2
        }
        DisplayManager.shared.refresh()
        if target == nil && DisplayManager.shared.liveMirrorTargets(of: source).isEmpty {
            print("display \(source) is not being mirrored")
            return 0
        }
        let ok = DisplayManager.shared.setMirror(source: source, on: target)
        print(ok ? (target == nil ? "mirroring stopped" : "mirroring started")
                 : (DisplayManager.shared.lastError ?? "mirroring failed"))
        return ok ? 0 : 4

    case "--set-resolution":
        guard arguments.count >= 5,
              let id = UInt32(arguments[2]),
              let width = Int(arguments[3]),
              let height = Int(arguments[4]) else {
            FileHandle.standardError.write(Data("usage: --set-resolution <displayID> <width> <height> [hidpi|lodpi] [hz]\n".utf8))
            return 2
        }
        let hiDPI = arguments.count > 5 ? arguments[5] == "hidpi" : false
        DisplayManager.shared.refresh()
        let hz = arguments.count > 6 ? Double(arguments[6]) : nil
        let ok = DisplayManager.shared.setResolution(width: width, height: height, hiDPI: hiDPI, refreshRate: hz, for: id)
        print(ok ? "resolution applied" : (DisplayManager.shared.lastError ?? "resolution not available"))
        return ok ? 0 : 4

    case "--toggle-hidpi":
        guard arguments.count >= 3, let id = UInt32(arguments[2]) else {
            FileHandle.standardError.write(Data("usage: --toggle-hidpi <displayID>\n".utf8))
            return 2
        }
        DisplayManager.shared.refresh()
        let ok = DisplayManager.shared.toggleHiDPI(for: id)
        print(ok ? "HiDPI toggled" : (DisplayManager.shared.lastError ?? "no complementary mode available"))
        return ok ? 0 : 4

    case "--create-virtual":
        guard arguments.count >= 4,
              let width = UInt32(arguments[2]),
              let height = UInt32(arguments[3]) else {
            FileHandle.standardError.write(Data("usage: --create-virtual <width> <height> [holdSeconds]\n".utf8))
            return 2
        }
        guard let holdSeconds = arguments.count > 4 ? Double(arguments[4]) : 2.0,
              holdSeconds.isFinite else {
            printError("holdSeconds must be a finite number")
            return 2
        }
        var configuration = VirtualScreenConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.name = "Great Display Virtual"
        guard let displayID = VirtualScreenManager.shared.create(configuration) else {
            let reason = String(cString: gd_virtual_display_error())
            FileHandle.standardError.write(Data("virtual display creation failed: \(reason)\n".utf8))
            return 5
        }
        print("created virtual display \(displayID)")
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.5, holdSeconds)))
        VirtualScreenManager.shared.destroyAll()
        return 0

    default:
        FileHandle.standardError.write(Data("unknown command \(command)\n".utf8))
        return 2
    }
}

let applicationArguments = CommandLine.arguments
let commands: Set<String> = ["--probe", "--set-brightness", "--set-resolution", "--toggle-hidpi",
                             "--create-virtual", "--ddc-read", "--ddc-write", "--ddc-diag", "--ddc-caps", "--mirror",
                             "--rotate", "--hdr", "--disconnect", "--reconnect", "--system-colors", "--adjust", "--self-test", "--audio-output", "--ddc-burst",
                             "--mirror-demo", "--stream-check", "--stream-test"]
/// Flags handled by the app itself after launch (development aids).
let applicationFlags: Set<String> = ["--preview-menu", "--render-menu", "--show-settings"]
if applicationArguments.count > 1 {
    let first = applicationArguments[1]
    if commands.contains(first) {
        let code = MainActor.assumeIsolated { runCommandLine(applicationArguments) }
        exit(code)
    }
    let usage = "commands:\n  " + commands.sorted().joined(separator: "\n  ")
    if first == "--help" || first == "-h" {
        print(usage)
        exit(0)
    }
    // Anything else starting with "--" is a mistyped command. Falling through
    // would start a second copy of the app next to the running one.
    if first.hasPrefix("--") && !applicationFlags.contains(first) {
        printError("unknown command \(first)\n\(usage)")
        exit(2)
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
    withExtendedLifetime(appDelegate) {}
}
