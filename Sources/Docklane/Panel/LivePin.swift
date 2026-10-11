import AppKit
import CoreMedia
import DocklaneCore
@preconcurrency import ScreenCaptureKit

/// Live previews pinned on top of everything: a small always-on-top copy of a window (a video,
/// a build log, a meeting) that follows it live. Drag to move, drag an edge to resize, click to
/// switch to the window, × to unpin. ScreenCaptureKit streams 10 frames a second; a window on
/// another desktop, which it cannot stream, is refreshed once a second instead.
@MainActor
final class LivePins {
    static let shared = LivePins()

    private var pins: [WindowNumber: LivePinPanel] = [:]
    static let maximum = 4

    private init() {}

    func isPinned(_ window: DockWindow) -> Bool { pins[window.id] != nil }

    func toggle(_ window: DockWindow) {
        if let pin = pins[window.id] {
            pin.close()
            return
        }
        guard pins.count < Self.maximum else { return NSSound.beep() }
        let pin = LivePinPanel(window: window, offset: pins.count) { [weak self] in
            self?.pins[window.id] = nil
        }
        pins[window.id] = pin
        pin.orderFrontRegardless()
        pin.startStreaming()
    }

    /// Drops pins whose window is gone.
    func windowsChanged(_ windows: [DockWindow]) {
        let live = Set(windows.map(\.id))
        for (id, pin) in pins where !live.contains(id) { pin.close() }
    }
}

/// The floating panel of one pin.
@MainActor
final class LivePinPanel: NSPanel {
    private let window: DockWindow
    private let onClose: () -> Void
    private let imageLayer = CALayer()
    private let closeButton = NSButton()
    private var stream: SCStream?
    private var receiver: FrameReceiver?
    private var fallback: Timer?
    private var dragStart: NSPoint?

    private static let width: CGFloat = 320
    private static let margin: CGFloat = 16

    init(window: DockWindow, offset: Int, onClose: @escaping () -> Void) {
        self.window = window
        self.onClose = onClose
        let aspect = max(window.bounds.height, 1) / max(window.bounds.width, 1)
        let size = CGSize(width: Self.width, height: (Self.width * min(max(aspect, 0.3), 1.6)).rounded())
        let area = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: area.maxX - size.width - Self.margin,
                             y: area.minY + Self.margin + CGFloat(offset) * (size.height + Self.margin))
        super.init(contentRect: CGRect(origin: origin, size: size),
                   styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        contentAspectRatio = size
        minSize = CGSize(width: 160, height: 90)
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityLabel(window.displayTitle)

        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 12
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        content.layer?.borderWidth = 0.5
        imageLayer.frame = content.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.contentsGravity = .resizeAspectFill
        content.layer?.addSublayer(imageLayer)

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Unpin Live Preview"))
        closeButton.contentTintColor = .white
        closeButton.frame = CGRect(x: 8, y: size.height - 30, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.target = self
        closeButton.action = #selector(unpin)
        closeButton.isHidden = true
        content.addSubview(closeButton)
        content.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                               owner: self, userInfo: nil))
        contentView = content
    }

    override var canBecomeKey: Bool { false }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    // A click switches to the window; a drag moves the pin.
    override func mouseDown(with event: NSEvent) { dragStart = NSEvent.mouseLocation }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        setFrameOrigin(CGPoint(x: frame.minX + now.x - start.x, y: frame.minY + now.y - start.y))
        dragStart = now
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard event.clickCount >= 1, let start = dragStart, hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) < 3 else { return }
        if let current = WindowEngine.shared.windows.first(where: { $0.id == window.id }) {
            WindowFocuser.focus(current)
        }
    }

    @objc private func unpin() { close() }

    override func close() {
        stopStreaming()
        super.close()
        onClose()
    }

    // MARK: - Frames

    func startStreaming() {
        Task { @MainActor in
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content?.windows.first(where: { $0.windowID == window.id }) else {
                return startFallback()
            }
            let configuration = SCStreamConfiguration()
            let scale = screen?.backingScaleFactor ?? 2
            configuration.width = Int(frame.width * scale * 1.5)
            configuration.height = Int(frame.height * scale * 1.5)
            configuration.scalesToFit = true
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: configuration, delegate: nil)
            let receiver = FrameReceiver { [weak self] surface in
                Task { @MainActor in self?.show(surface) }
            }
            do {
                try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
                try await stream.startCapture()
                self.stream = stream
                self.receiver = receiver
            } catch {
                startFallback()
            }
        }
    }

    /// Windows on another desktop or in full screen elsewhere can't be streamed: refresh them
    /// with a still image once a second.
    private func startFallback() {
        fallback?.invalidate()
        let capturer = WindowCapturer(maxPixelSize: CGSize(width: 960, height: 960))
        let id = window.id
        let tick: @MainActor () -> Void = { [weak self] in
            guard let current = WindowEngine.shared.windows.first(where: { $0.id == id }) else { return }
            Task { @MainActor in
                if let image = await capturer.capture(current) { self?.imageLayer.contents = image.cgImage }
            }
        }
        tick()
        fallback = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private func show(_ surface: SurfaceBox) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = surface.surface
        CATransaction.commit()
    }

    private func stopStreaming() {
        fallback?.invalidate()
        fallback = nil
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        receiver = nil
    }
}

/// An IOSurface handed from the capture queue to the main thread (read-only there).
struct SurfaceBox: @unchecked Sendable {
    let surface: IOSurface
}

/// Receives stream frames on the capture queue.
private final class FrameReceiver: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (SurfaceBox) -> Void

    init(onFrame: @escaping @Sendable (SurfaceBox) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        onFrame(SurfaceBox(surface: surface))
    }
}
