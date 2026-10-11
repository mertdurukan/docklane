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
/// Single frames come from the private `CGSHWCaptureWindowList`, which works for windows on
/// any Space and doesn't count as screen recording; ScreenCaptureKit is the fallback.
public actor WindowCapturer {
    private let maxPixelSize: CGSize
    private var shareableContent: SCShareableContent?
    private var shareableContentDate = Date.distantPast
    private let shareableContentLifetime: TimeInterval = 3

    public init(maxPixelSize: CGSize = CGSize(width: 480, height: 320)) {
        self.maxPixelSize = maxPixelSize
    }

    /// `within` overrides the capturer's maximum pixel size for this call.
    public func capture(_ window: DockWindow, within bounds: CGSize? = nil) async -> WindowImage? {
        let bounds = bounds ?? maxPixelSize
        // The WindowServer's single-frame capture first: it doesn't start a screen recording
        // (no purple indicator in the menu bar) and needs no shareable-content query.
        // ScreenCaptureKit only if that fails.
        if let image = windowServerCapture(window.id, within: bounds) { return WindowImage(image) }
        return await captureWithScreenCaptureKit(window, within: bounds).map(WindowImage.init)
    }

    /// Captures several windows, at most `limit` at a time.
    /// `within` gives each window's maximum pixel size (default: the capturer's).
    public func capture(_ windows: [DockWindow], within bounds: [WindowNumber: CGSize] = [:],
                        limit: Int = 4) async -> [WindowNumber: WindowImage] {
        var results: [WindowNumber: WindowImage] = [:]
        var pending = windows[...]
        await withTaskGroup(of: (WindowNumber, WindowImage?).self) { group in
            func startNext() {
                guard let window = pending.popFirst() else { return }
                group.addTask { (window.id, await self.capture(window, within: bounds[window.id])) }
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

    private func captureWithScreenCaptureKit(_ window: DockWindow, within bounds: CGSize) async -> CGImage? {
        guard let scWindow = await shareableWindow(window.id) else { return nil }
        let size = Self.fittedSize(for: scWindow.frame.size, within: bounds)
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

    private func windowServerCapture(_ id: WindowNumber, within bounds: CGSize) -> CGImage? {
        guard let capture = PrivateSymbols.hwCaptureWindowList,
              let mainConnection = PrivateSymbols.mainConnectionID else { return nil }
        var windowID = id
        let ignoreGlobalClipShape: UInt32 = 1 << 11
        let nominalResolution: UInt32 = 1 << 9
        guard let images = capture(mainConnection(), &windowID, 1, ignoreGlobalClipShape | nominalResolution)?
                .takeRetainedValue() as? [CGImage],
              let full = images.first, full.width > 1, full.height > 1
        else { return nil }
        return Self.scaled(full, within: bounds)
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
        guard Int(size.width) != image.width || Int(size.height) != image.height else { return image }
        // Same colour space and pixel format as the capture, so CoreGraphics draws it without
        // a converted copy (which it would keep in its image cache).
        func context(_ space: CGColorSpace?, _ info: UInt32) -> CGContext? {
            guard let space else { return nil }
            return CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                             bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        }
        guard let context = context(image.colorSpace, image.bitmapInfo.rawValue)
                ?? context(CGColorSpaceCreateDeviceRGB(), CGImageAlphaInfo.premultipliedLast.rawValue)
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
