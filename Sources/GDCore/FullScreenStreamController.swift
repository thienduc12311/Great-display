import Foundation
import AppKit
import AVFoundation
import CoreMedia
import CoreImage
import ScreenCaptureKit
import Combine

/// Streams one display into a borderless window on another display (or onto
/// itself, for flipping/rotating/filtering the picture in place).
///
/// Mirroring is a window-server operation and forces the target to adopt the
/// source timing. Streaming keeps the target at its native mode and composites
/// the captured source into a window instead. Every option of a stream lives in
/// a saved `StreamConfiguration` (one per source display) and is applied live.
@MainActor
public final class FullScreenStreamController: ObservableObject {
    public static let shared = FullScreenStreamController()

    public struct ActiveStream: Identifiable {
        public let id: UUID
        public let source: CGDirectDisplayID
        public let target: CGDirectDisplayID
        public let sourceName: String
        public let targetName: String
        public var isSelfStream: Bool { source == target }
    }

    @Published public private(set) var active: [ActiveStream] = []
    @Published public private(set) var lastError: String?

    private var sessions: [UUID: StreamSession] = [:]
    private var windows: [UUID: StreamWindow] = [:]
    private var starting: Set<CGDirectDisplayID> = []
    /// Sources whose start was cancelled by a stop while it was still awaiting
    /// the capture system.
    private var cancelledStarts: Set<CGDirectDisplayID> = []
    /// Source identities whose stream the user stopped. "Resume on Connect"
    /// and auto-streaming leave these alone until one end reconnects.
    private var stoppedByUser: Set<String> = []
    private var escapeMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // "Resume Stream on Connect": restart saved streams when both ends appear.
        DisplayManager.shared.$displays
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] displays in
                self?.reconcile(with: displays)
            }
            .store(in: &cancellables)
    }

    public var isSupported: Bool { true }

    public var hasScreenRecordingPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public func requestScreenRecordingPermission() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    public func isStreaming(source: CGDirectDisplayID) -> Bool {
        active.contains { $0.source == source }
    }

    public func stream(for source: CGDirectDisplayID) -> ActiveStream? {
        active.first { $0.source == source }
    }

    /// True after the user stopped the stream from this source, until either
    /// of its displays reconnects or the stream is started again.
    public func wasStoppedByUser(sourceIdentity: String) -> Bool {
        stoppedByUser.contains(sourceIdentity)
    }

    // MARK: Configuration

    /// The saved options for a source display (created with defaults on demand).
    public func configuration(forSource display: DisplayInfo) -> StreamConfiguration {
        SettingsStore.shared.state.streams.first { $0.sourceIdentity == display.identity }
            ?? StreamConfiguration(sourceIdentity: display.identity, targetIdentity: display.identity)
    }

    /// Saves options and applies them to a running stream from that source.
    public func update(_ configuration: StreamConfiguration) {
        var streams = SettingsStore.shared.state.streams
        let previous = streams.first { $0.sourceIdentity == configuration.sourceIdentity }
        streams.removeAll { $0.sourceIdentity == configuration.sourceIdentity }
        streams.append(configuration)
        SettingsStore.shared.state.streams = streams

        guard let stream = active.first(where: { identity(of: $0.source) == configuration.sourceIdentity }),
              let session = sessions[stream.id], let window = windows[stream.id] else { return }
        session.configuration = configuration
        window.allowsKey = !stream.isSelfStream && !configuration.interactive
        window.alphaValue = configuration.alpha
        layout(stream: stream)
        session.applyFilter()
        if previous?.showCursor != configuration.showCursor || previous?.targetFPS != configuration.targetFPS
            || previous?.cropEnabled != configuration.cropEnabled || previous?.cropTop != configuration.cropTop
            || previous?.cropBottom != configuration.cropBottom || previous?.cropLeft != configuration.cropLeft
            || previous?.cropRight != configuration.cropRight {
            if let captureConfig = makeCaptureConfiguration(source: stream.source, configuration: configuration) {
                session.stream?.updateConfiguration(captureConfig) { _ in }
                session.captureSize = captureConfig.pixelSize
                layout(stream: stream)
            }
        }
    }

    // MARK: Start / stop

    /// Starts streaming `source` onto `target` (the same display for a self-stream).
    @discardableResult
    public func start(source: CGDirectDisplayID, on target: CGDirectDisplayID, activate: Bool = true) async -> Bool {
        guard !starting.contains(source) else { return false }
        if let existing = stream(for: source), existing.target == target { return true }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            lastError = "Screen Recording permission is required. Enable it for Great Display in System Settings, then relaunch the app."
            return false
        }
        guard let sourceInfo = DisplayManager.shared.display(id: source),
              let targetInfo = DisplayManager.shared.display(id: target),
              let targetScreen = screen(for: target) else {
            lastError = "One of the displays is no longer available."
            return false
        }
        // Only now that the new target is known to be usable.
        if let existing = stream(for: source) { stop(existing.id, byUser: false) }
        stoppedByUser.remove(sourceInfo.identity)
        starting.insert(source)
        cancelledStarts.remove(source)
        defer {
            starting.remove(source)
            cancelledStarts.remove(source)
        }

        var configuration = configuration(forSource: sourceInfo)
        configuration.targetIdentity = targetInfo.identity
        let selfStream = source == target
        // Kept outside `do` so a failure after the session exists can break
        // the session/stream reference cycle.
        var pendingSession: StreamSession?

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == source }) else {
                lastError = "The capture system does not expose display \(source)."
                return false
            }
            // A self-stream must not capture its own window (or it would film
            // itself); a stream onto another display keeps our menus and OSDs in
            // the picture, since they are part of the source screen.
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = selfStream
                ? SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
                : SCContentFilter(display: display, excludingWindows: [])
            guard let captureConfig = makeCaptureConfiguration(source: source, configuration: configuration) else {
                lastError = "Display \(source) has no active mode."
                return false
            }

            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resize
            let session = StreamSession(layer: layer, configuration: configuration)
            session.captureSize = captureConfig.pixelSize
            session.sourceGeometry = Self.geometryKey(of: source)
            let stream = SCStream(filter: filter, configuration: captureConfig, delegate: session)
            session.stream = stream
            pendingSession = session
            try stream.addStreamOutput(session, type: .screen, sampleHandlerQueue: session.queue)
            try await stream.startCapture()
            // Stopped (or its display removed) while the capture was starting.
            if cancelledStarts.contains(source) {
                session.stop()
                return false
            }

            let window = makeWindow(on: targetScreen, layer: layer, selfStream: selfStream)
            window.allowsKey = !selfStream && !configuration.interactive
            window.alphaValue = configuration.alpha
            let id = UUID()
            // The capture system can end a stream on its own (sleep, the
            // system's stop-sharing control). Without this the window would
            // stay over the display showing its last frame.
            session.onStopped = { [weak self, weak session] message in
                MainActor.assumeIsolated {
                    guard let self, let session, self.sessions[id] === session else { return }
                    self.stop(id, byUser: false)
                    self.lastError = "The stream ended: \(message)"
                }
            }
            let entry = ActiveStream(id: id, source: source, target: target,
                                     sourceName: sourceInfo.name, targetName: targetInfo.name)
            sessions[id] = session
            windows[id] = window
            active.append(entry)
            layout(stream: entry)
            session.applyFilter()
            if selfStream || configuration.interactive {
                // Interactive streams leave keyboard focus with the apps on the
                // source screen.
                window.orderFrontRegardless()
                if !selfStream { installEscapeMonitor() }
            } else {
                installEscapeMonitor()
                if activate {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                } else {
                    window.orderFrontRegardless()
                }
            }
            update(configuration)
            lastError = nil
            return true
        } catch {
            pendingSession?.stop()
            lastError = "Screen capture failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Stops a stream. `byUser` is false when the stream ends for another
    /// reason (its display went away, the capture ended, it is being moved),
    /// which leaves "Resume on Connect" free to bring it back.
    public func stop(_ id: UUID, byUser: Bool = true) {
        if byUser, let stream = active.first(where: { $0.id == id }),
           let sourceIdentity = sessions[id]?.configuration.sourceIdentity ?? identity(of: stream.source) {
            stoppedByUser.insert(sourceIdentity)
        }
        if let session = sessions.removeValue(forKey: id) {
            session.stop()
        }
        if let window = windows.removeValue(forKey: id) {
            window.orderOut(nil)
            window.close()
        }
        active.removeAll { $0.id == id }
        pictureRects.removeValue(forKey: id)
        if redirecting == id { redirecting = nil }
        if !active.contains(where: { !$0.isSelfStream }) {
            removeEscapeMonitor()
        }
        updatePointerRouting()
    }

    public func stop(source: CGDirectDisplayID, byUser: Bool = true) {
        // A start still waiting for the capture system has no entry in
        // `active` yet: flag it so it does not appear after this stop.
        if starting.contains(source) { cancelledStarts.insert(source) }
        for stream in active where stream.source == source {
            stop(stream.id, byUser: byUser)
        }
    }

    public func stopAll() {
        cancelledStarts.formUnion(starting)
        for stream in active {
            stop(stream.id)
        }
    }

    /// Restarts saved streams marked "Resume on Connect" whose source and
    /// target are both present, and drops streams whose displays went away.
    private func reconcile(with displays: [DisplayInfo]) {
        let ids = Set(displays.map(\.id))
        for stream in active where !ids.contains(stream.source) || !ids.contains(stream.target) {
            stop(stream.id, byUser: false)
        }
        // Follow source mode changes (size, density, rotation), then re-lay
        // out for any target resolution change.
        for stream in active {
            refreshCaptureGeometry(of: stream)
            layout(stream: stream)
        }

        // A manual stop holds until one end of the stream goes away: the
        // next connect is then a real "connect" again.
        let identities = Set(displays.map(\.identity))
        let configurations = SettingsStore.shared.state.streams
        stoppedByUser = stoppedByUser.filter { identity in
            guard identities.contains(identity) else { return false }
            guard let target = configurations.first(where: { $0.sourceIdentity == identity })?.targetIdentity else {
                return true
            }
            return identities.contains(target)
        }

        guard CGPreflightScreenCaptureAccess() else { return }
        for configuration in configurations where configuration.resumeOnConnect
            && !stoppedByUser.contains(configuration.sourceIdentity) {
            guard let source = displays.first(where: { $0.identity == configuration.sourceIdentity }),
                  let target = displays.first(where: { $0.identity == configuration.targetIdentity }),
                  !isStreaming(source: source.id) else { continue }
            Task { @MainActor in _ = await self.start(source: source.id, on: target.id, activate: false) }
        }
    }

    /// Points and pixels of a display's current mode, to notice when a
    /// stream's capture configuration no longer fits its source.
    private static func geometryKey(of display: CGDirectDisplayID) -> String {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return "" }
        return "\(mode.width)x\(mode.height)@\(mode.pixelWidth)x\(mode.pixelHeight)"
    }

    /// Rebuilds the capture size and crop rectangle after the source changed
    /// mode in place (a virtual screen following its display's orientation,
    /// a HiDPI toggle). They are otherwise fixed when the stream starts.
    private func refreshCaptureGeometry(of stream: ActiveStream) {
        guard let session = sessions[stream.id] else { return }
        let key = Self.geometryKey(of: stream.source)
        guard !key.isEmpty, key != session.sourceGeometry,
              let captureConfig = makeCaptureConfiguration(source: stream.source,
                                                           configuration: session.configuration) else { return }
        session.sourceGeometry = key
        session.stream?.updateConfiguration(captureConfig) { _ in }
        session.captureSize = captureConfig.pixelSize
    }

    /// Diagnostics: frames shown so far and the layer geometry of a stream.
    public func diagnostics(source: CGDirectDisplayID) -> (frames: Int, layerBounds: CGRect, transform: CATransform3D, level: Int)? {
        guard let stream = stream(for: source), let session = sessions[stream.id] else { return nil }
        return (session.framesShown, session.layer.bounds, session.layer.transform, windows[stream.id]?.level.rawValue ?? -1)
    }

    // MARK: Interactive pointer routing

    private var pictureRects: [UUID: CGRect] = [:]
    private var pointerMonitors: [Any] = []
    /// Stream whose source display currently holds the pointer.
    private var redirecting: UUID?

    private var interactiveStreams: [ActiveStream] {
        active.filter { !$0.isSelfStream && (sessions[$0.id]?.configuration.interactive ?? false) }
    }

    private func updatePointerRouting() {
        let needed = !interactiveStreams.isEmpty
        if needed && pointerMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                let delta = (event.cgEvent?.getIntegerValueField(.mouseEventDeltaX) ?? 0,
                             event.cgEvent?.getIntegerValueField(.mouseEventDeltaY) ?? 0)
                MainActor.assumeIsolated { self?.routePointer(dx: delta.0, dy: delta.1) }
            }) { pointerMonitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                let delta = (event.cgEvent?.getIntegerValueField(.mouseEventDeltaX) ?? 0,
                             event.cgEvent?.getIntegerValueField(.mouseEventDeltaY) ?? 0)
                MainActor.assumeIsolated { self?.routePointer(dx: delta.0, dy: delta.1) }
                return event
            }) { pointerMonitors.append(local) }
        } else if !needed && !pointerMonitors.isEmpty {
            pointerMonitors.forEach(NSEvent.removeMonitor)
            pointerMonitors.removeAll()
            redirecting = nil
        }
    }

    /// Moves the pointer between a stream's picture and its source display, so
    /// the stream behaves like the screen it shows. Coordinates are global
    /// CoreGraphics points (top-left origin).
    /// Runs one routing step as if the pointer had just moved (diagnostics).
    public func routePointerForTesting(dx: Int64, dy: Int64) { routePointer(dx: dx, dy: dy) }

    private func routePointer(dx: Int64, dy: Int64) {
        guard let location = CGEvent(source: nil)?.location else { return }

        if let id = redirecting, let stream = active.first(where: { $0.id == id }) {
            let source = CGDisplayBounds(stream.source)
            enum Edge { case left, right, top, bottom }
            var edge: Edge?
            if location.x < source.minX { edge = .left }
            else if location.x >= source.maxX { edge = .right }
            else if location.y < source.minY { edge = .top }
            else if location.y >= source.maxY { edge = .bottom }
            // At an edge with no neighbouring display the pointer is held back;
            // keep moving outwards and it leaves through the stream's edge.
            else if location.x <= source.minX + 0.5 && dx < 0 { edge = .left }
            else if location.x >= source.maxX - 1.5 && dx > 0 { edge = .right }
            else if location.y <= source.minY + 0.5 && dy < 0 { edge = .top }
            else if location.y >= source.maxY - 1.5 && dy > 0 { edge = .bottom }
            guard let edge else { return }

            let inside = CGPoint(x: min(max(location.x, source.minX), source.maxX - 1),
                                 y: min(max(location.y, source.minY), source.maxY - 1))
            let target = CGDisplayBounds(stream.target)
            var point = mapToTarget(stream, inside) ?? CGPoint(x: target.midX, y: target.midY)
            switch edge {
            case .left: point.x = target.minX - 2
            case .right: point.x = target.maxX + 1
            case .top: point.y = target.minY - 2
            case .bottom: point.y = target.maxY + 1
            }
            redirecting = nil
            warp(to: point)
            return
        }

        for stream in interactiveStreams where CGDisplayBounds(stream.target).contains(location) {
            guard let point = mapToSource(stream, location) else { continue }
            redirecting = stream.id
            warp(to: point)
            return
        }
    }

    private func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-associate at once so the pointer does not stall after the jump.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// A point on the stream's target display → the matching source point,
    /// undoing alignment, zoom, rotation, flip and crop.
    public func mapToSource(_ stream: ActiveStream, _ point: CGPoint) -> CGPoint? {
        guard let rect = pictureRects[stream.id], rect.width > 0, rect.height > 0,
              let configuration = sessions[stream.id]?.configuration else { return nil }
        let target = CGDisplayBounds(stream.target)
        let u = min(max((point.x - target.minX - rect.minX) / rect.width, 0), 0.9999)
        let w = min(max((point.y - target.minY - rect.minY) / rect.height, 0), 0.9999)
        var (s, t): (CGFloat, CGFloat)
        switch configuration.rotation {
        case 90: (s, t) = (w, 1 - u)
        case 180: (s, t) = (1 - u, 1 - w)
        case 270: (s, t) = (1 - w, u)
        default: (s, t) = (u, w)
        }
        if configuration.flipHorizontal { s = 1 - s }
        if configuration.flipVertical { t = 1 - t }
        return sourcePoint(stream, configuration, s, t)
    }

    /// A point on the source display → where it appears on the target display.
    public func mapToTarget(_ stream: ActiveStream, _ point: CGPoint) -> CGPoint? {
        guard let rect = pictureRects[stream.id], let configuration = sessions[stream.id]?.configuration else { return nil }
        let source = CGDisplayBounds(stream.source)
        // A source that just went away reports empty bounds.
        guard source.width > 0, source.height > 0 else { return nil }
        let crop = cropFractions(configuration)
        var s = ((point.x - source.minX) / source.width - crop.left) / max(0.01, 1 - crop.left - crop.right)
        var t = ((point.y - source.minY) / source.height - crop.top) / max(0.01, 1 - crop.top - crop.bottom)
        if configuration.flipHorizontal { s = 1 - s }
        if configuration.flipVertical { t = 1 - t }
        let (u, w): (CGFloat, CGFloat)
        switch configuration.rotation {
        case 90: (u, w) = (1 - t, s)
        case 180: (u, w) = (1 - s, 1 - t)
        case 270: (u, w) = (t, 1 - s)
        default: (u, w) = (s, t)
        }
        let target = CGDisplayBounds(stream.target)
        return CGPoint(x: target.minX + rect.minX + u * rect.width, y: target.minY + rect.minY + w * rect.height)
    }

    private func cropFractions(_ c: StreamConfiguration) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        guard c.cropEnabled else { return (0, 0, 0, 0) }
        return (CGFloat(min(0.45, c.cropLeft)), CGFloat(min(0.45, c.cropRight)),
                CGFloat(min(0.45, c.cropTop)), CGFloat(min(0.45, c.cropBottom)))
    }

    private func sourcePoint(_ stream: ActiveStream, _ c: StreamConfiguration, _ s: CGFloat, _ t: CGFloat) -> CGPoint {
        let source = CGDisplayBounds(stream.source)
        let crop = cropFractions(c)
        let x = source.width * (crop.left + s * (1 - crop.left - crop.right))
        let y = source.height * (crop.top + t * (1 - crop.top - crop.bottom))
        return CGPoint(x: min(source.minX + x, source.maxX - 1), y: min(source.minY + y, source.maxY - 1))
    }

    // MARK: Geometry

    private func makeCaptureConfiguration(source: CGDirectDisplayID, configuration: StreamConfiguration) -> SCStreamConfiguration? {
        guard let mode = CGDisplayCopyDisplayMode(source) else { return nil }
        let points = CGSize(width: mode.width, height: mode.height)
        let pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        let crop = configuration.cropEnabled ? configuration : StreamConfiguration(sourceIdentity: "", targetIdentity: "")
        let left = min(0.45, crop.cropLeft), right = min(0.45, crop.cropRight)
        let top = min(0.45, crop.cropTop), bottom = min(0.45, crop.cropBottom)
        let widthFraction = max(0.1, 1 - left - right), heightFraction = max(0.1, 1 - top - bottom)

        let capture = SCStreamConfiguration()
        // Capture at the source's pixel resolution so HiDPI sources stay sharp.
        capture.width = max(2, Int((pixels.width * widthFraction).rounded()))
        capture.height = max(2, Int((pixels.height * heightFraction).rounded()))
        if configuration.cropEnabled {
            capture.sourceRect = CGRect(x: points.width * left, y: points.height * top,
                                        width: points.width * widthFraction, height: points.height * heightFraction)
        }
        capture.minimumFrameInterval = configuration.targetFPS > 0
            ? CMTime(value: 1, timescale: CMTimeScale(configuration.targetFPS))
            : CMTime(value: 1, timescale: 240)
        capture.queueDepth = 5
        capture.showsCursor = configuration.showCursor
        capture.pixelFormat = kCVPixelFormatType_32BGRA
        capture.scalesToFit = true
        capture.preservesAspectRatio = true
        capture.colorSpaceName = CGColorSpace.sRGB
        return capture
    }

    /// Places the picture inside the target window according to the stream's
    /// scaling, underscan, zoom, alignment, rotation and flip options.
    private func layout(stream: ActiveStream) {
        guard let session = sessions[stream.id], let window = windows[stream.id],
              let screen = screen(for: stream.target) else { return }
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        let configuration = session.configuration
        let target = screen.frame.size
        let backing = screen.backingScaleFactor
        let source = session.captureSize
        guard source.width > 0, source.height > 0 else { return }

        let rotated = configuration.rotation % 180 != 0
        let content = rotated ? CGSize(width: source.height, height: source.width) : source

        var scaleX: CGFloat
        var scaleY: CGFloat
        let fit = min(target.width / content.width, target.height / content.height)
        switch configuration.scaling {
        case .fit:
            scaleX = fit; scaleY = fit
        case .fill:
            scaleX = target.width / content.width; scaleY = target.height / content.height
        case .pixelPerfect:
            scaleX = 1 / backing; scaleY = 1 / backing
        case .integer:
            let factor = floor(min(target.width * backing / content.width, target.height * backing / content.height))
            let scale = factor >= 1 ? factor / backing : fit
            scaleX = scale; scaleY = scale
        }
        let extra = CGFloat(configuration.underscan * configuration.zoom)
        scaleX *= extra
        scaleY *= extra

        let shown = CGSize(width: content.width * scaleX, height: content.height * scaleY)
        let x: CGFloat
        switch configuration.horizontal {
        case .left: x = 0
        case .center: x = (target.width - shown.width) / 2
        case .right: x = target.width - shown.width
        }
        let y: CGFloat   // layer coordinates grow upwards
        switch configuration.vertical {
        case .bottom: y = 0
        case .center: y = (target.height - shown.height) / 2
        case .top: y = target.height - shown.height
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = session.layer
        layer.bounds = CGRect(origin: .zero,
                              size: rotated ? CGSize(width: shown.height, height: shown.width) : shown)
        layer.position = CGPoint(x: x + shown.width / 2, y: y + shown.height / 2)
        let flip = CATransform3DMakeScale(configuration.flipHorizontal ? -1 : 1,
                                          configuration.flipVertical ? -1 : 1, 1)
        let angle = -CGFloat(configuration.rotation) * .pi / 180   // clockwise
        layer.transform = CATransform3DConcat(flip, CATransform3DMakeRotation(angle, 0, 0, 1))
        CATransaction.commit()
        // Picture rectangle in target-local, top-down points (pointer mapping).
        pictureRects[stream.id] = CGRect(x: x, y: target.height - (y + shown.height),
                                         width: shown.width, height: shown.height)
        updatePointerRouting()
    }

    // MARK: Windows

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func identity(of id: CGDirectDisplayID) -> String? {
        DisplayManager.shared.display(id: id)?.identity
    }

    /// Full screen: above the menu bar and status items, below menus and
    /// popovers (so menus, including the app menu, open on top).
    public static let streamLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    public static let selfStreamLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    private func makeWindow(on screen: NSScreen, layer: AVSampleBufferDisplayLayer, selfStream: Bool) -> StreamWindow {
        let window = StreamWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        // Both kinds cover the menu bar and stay below menus and popovers, so
        // the app menu still opens on top; a self-stream sits higher, just
        // under the menus, because it transforms everything beneath it.
        window.level = selfStream ? Self.selfStreamLevel : Self.streamLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hasShadow = false
        window.isMovable = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        // A self-stream sits on top of the real desktop: clicks go through to it.
        window.ignoresMouseEvents = selfStream
        window.acceptsMouseMovedEvents = true

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.masksToBounds = true
        view.layer?.addSublayer(layer)

        if !selfStream {
            let hint = NSTextField(labelWithString: "Press Esc to stop streaming")
            hint.font = .systemFont(ofSize: 12, weight: .medium)
            hint.textColor = .white
            hint.alphaValue = 0
            hint.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hint.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            ])
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; hint.animator().alphaValue = 0.85 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.6; hint.animator().alphaValue = 0 }
            }
        }
        window.contentView = view
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }  // Escape
            // Only when a stream window itself has focus: Esc in our menu or
            // settings must not end a stream.
            let streamWindow = MainActor.assumeIsolated { () -> UUID? in
                guard let self, let key = NSApp.keyWindow else { return nil }
                return self.windows.first { $0.value === key }?.key
            }
            guard let streamWindow else { return event }
            Task { @MainActor in self?.stop(streamWindow) }
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

private extension SCStreamConfiguration {
    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

/// A borderless window cannot become key by default, so it never receives
/// key presses: the Esc-to-stop shortcut needs the stream window to be key.
/// Self-streams and interactive streams keep the default, since they leave
/// keyboard focus with the apps they show.
private final class StreamWindow: NSWindow {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Owns one capture stream, its display layer and the optional video filter.
private final class StreamSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    let queue = DispatchQueue(label: "greatdisplay.stream.samples", qos: .userInteractive)
    var stream: SCStream?
    /// Read on the main thread for layout; written on the main thread.
    var configuration: StreamConfiguration
    var captureSize: CGSize = .zero
    /// The source's mode when the capture configuration was last built.
    var sourceGeometry = ""
    /// Called on the main thread when the capture system ends the stream
    /// without being asked to.
    var onStopped: ((String) -> Void)?
    /// Frames delivered to the layer (diagnostics).
    private(set) var framesShown = 0

    private let filterLock = NSLock()
    private var ciFilter: CIFilter?
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    init(layer: AVSampleBufferDisplayLayer, configuration: StreamConfiguration) {
        self.layer = layer
        self.configuration = configuration
        super.init()
        layer.flush()
    }

    /// Builds the Core Image filter for the configured effect (main thread).
    func applyFilter() {
        let filter: CIFilter?
        switch configuration.filter {
        case .none: filter = nil
        case .monochrome:
            filter = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .invert: filter = CIFilter(name: "CIColorInvert")
        case .sepia: filter = CIFilter(name: "CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .thermal: filter = CIFilter(name: "CIThermal")
        case .xray: filter = CIFilter(name: "CIXRay")
        case .comic: filter = CIFilter(name: "CIComicEffect")
        }
        filterLock.lock()
        ciFilter = filter
        filterLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let rawStatus = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus), status != .complete {
            return
        }
        if layer.status == .failed { layer.flush() }

        filterLock.lock()
        let filter = ciFilter
        filterLock.unlock()
        if let filter, let filtered = apply(filter, to: sampleBuffer) {
            layer.enqueue(filtered)
        } else {
            layer.enqueue(sampleBuffer)
        }
        framesShown += 1
    }

    /// Runs the frame through Core Image into a pooled pixel buffer.
    private func apply(_ filter: CIFilter, to sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        if pool == nil || poolSize != CGSize(width: width, height: height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = CGSize(width: width, height: height)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output else { return nil }

        filter.setValue(CIImage(cvPixelBuffer: source), forKey: kCIInputImageKey)
        guard let image = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        ciContext.render(image, to: output)

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: output, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing)
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: output, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &result)
        if let result, let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true) {
            // Show immediately rather than waiting for the presentation time.
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return result
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        NSLog("Great Display: stream stopped with error %@", message)
        DispatchQueue.main.async { [weak self] in self?.onStopped?(message) }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        onStopped = nil
        stream?.stopCapture(completionHandler: { _ in })
        layer.flushAndRemoveImage()
    }
}
