import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A captured window image plus a cheap fingerprint, so unchanged images can be skipped
/// without redrawing the UI.
public struct WindowImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let fingerprint: UInt64

    public init(_ cgImage: CGImage) {
        self.cgImage = cgImage
        self.fingerprint = ImageFingerprint.of(cgImage)
    }

    public var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}

/// Captures window images at the window's own aspect ratio.
///
/// On-screen windows go through ScreenCaptureKit. Windows on another Space or in full screen
/// (which ScreenCaptureKit refuses with "Failed to start stream") go through the private
/// `CGSHWCaptureWindowList`. Each path falls back to the other.
public actor WindowCapturer {
    private let maxPixelSize: CGSize
    private var shareableContent: SCShareableContent?
    private var shareableContentDate = Date.distantPast
    private let shareableContentLifetime: TimeInterval = 3

    public init(maxPixelSize: CGSize = CGSize(width: 480, height: 320)) {
        self.maxPixelSize = maxPixelSize
    }

    public func capture(_ window: DockWindow) async -> WindowImage? {
        if window.isOnScreen {
            if let image = await captureWithScreenCaptureKit(window) { return WindowImage(image) }
            return windowServerCapture(window.id).map(WindowImage.init)
        }
        if let image = windowServerCapture(window.id) { return WindowImage(image) }
        return await captureWithScreenCaptureKit(window).map(WindowImage.init)
    }

    /// Captures several windows, at most `limit` at a time.
    public func capture(_ windows: [DockWindow], limit: Int = 4) async -> [WindowNumber: WindowImage] {
        var results: [WindowNumber: WindowImage] = [:]
        var pending = windows[...]
        await withTaskGroup(of: (WindowNumber, WindowImage?).self) { group in
            func startNext() {
                guard let window = pending.popFirst() else { return }
                group.addTask { (window.id, await self.capture(window)) }
            }
            for _ in 0..<limit { startNext() }
            for await (id, image) in group {
                if let image { results[id] = image }
                startNext()
            }
        }
        return results
    }

    // MARK: - ScreenCaptureKit

    private func captureWithScreenCaptureKit(_ window: DockWindow) async -> CGImage? {
        guard let scWindow = await shareableWindow(window.id) else { return nil }
        let size = Self.fittedSize(for: scWindow.frame.size, within: maxPixelSize)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(origin: .zero, size: scWindow.frame.size)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.scalesToFit = true
        configuration.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func shareableWindow(_ id: WindowNumber) async -> SCWindow? {
        if Date().timeIntervalSince(shareableContentDate) > shareableContentLifetime
            || shareableContent?.windows.contains(where: { $0.windowID == id }) != true {
            shareableContent = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            shareableContentDate = Date()
        }
        return shareableContent?.windows.first { $0.windowID == id }
    }

    // MARK: - WindowServer (private)

    private func windowServerCapture(_ id: WindowNumber) -> CGImage? {
        guard let capture = PrivateSymbols.hwCaptureWindowList,
              let mainConnection = PrivateSymbols.mainConnectionID else { return nil }
        var windowID = id
        let ignoreGlobalClipShape: UInt32 = 1 << 11
        let nominalResolution: UInt32 = 1 << 9
        guard let images = capture(mainConnection(), &windowID, 1, ignoreGlobalClipShape | nominalResolution)?
                .takeRetainedValue() as? [CGImage],
              let full = images.first, full.width > 1, full.height > 1
        else { return nil }
        return Self.scaled(full, within: maxPixelSize)
    }

    // MARK: - Geometry

    /// Largest size with the source's aspect ratio that fits `bounds` (never upscales).
    public static func fittedSize(for source: CGSize, within bounds: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return CGSize(width: 1, height: 1) }
        let scale = min(bounds.width / source.width, bounds.height / source.height, 1)
        return CGSize(
            width: max(1, (source.width * scale).rounded()),
            height: max(1, (source.height * scale).rounded())
        )
    }

    static func scaled(_ image: CGImage, within bounds: CGSize) -> CGImage {
        let size = fittedSize(for: CGSize(width: image.width, height: image.height), within: bounds)
        guard Int(size.width) != image.width || Int(size.height) != image.height,
              let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage() ?? image
    }
}

/// 64-bit fingerprint of an 8x8 grayscale thumbnail of an image (FNV-1a over the pixels).
/// Equal fingerprints mean "looks the same", so the UI can skip a redraw.
public enum ImageFingerprint {
    public static func of(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return 0 }
        return fnv1a(pixels)
    }

    public static func fnv1a(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
