import AppKit
import ApplicationServices
import ScreenCaptureKit

/// 一块屏幕在按下截图键那一刻的冻结画面。
///
/// 坐标约定：截图模块里的“视图坐标”以屏幕左上角为原点、y 轴向下、单位是点，
/// 与 `CGImage` 裁剪和 `CGWindowList` / 辅助功能返回的坐标同向，换算只差平移和缩放。
struct ScreenShot {
    let screen: NSScreen
    /// 屏幕在全局 Cocoa 坐标系中的位置（y 轴向上）。
    let frame: CGRect
    let image: CGImage
    /// 每点对应的像素数。
    let scale: CGFloat

    /// 视图坐标里的矩形对应的像素矩形，已裁到图像范围内。
    func pixelRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// 读取一个像素的 sRGB 颜色。
    func color(at point: CGPoint) -> RGBColor? {
        let x = Int(point.x * scale), y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? RGBColor(red: bytes[0], green: bytes[1], blue: bytes[2]) : nil
    }

    /// 全局 `CGWindowList` 坐标（主屏左上角为原点）换算到本屏视图坐标。
    func viewRect(fromGlobal rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -(ScreenGeometry.primaryHeight - frame.maxY))
    }

    func globalPoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: point.x + frame.minX, y: point.y + ScreenGeometry.primaryHeight - frame.maxY)
    }

    /// 视图坐标里的矩形换算回全局 Cocoa 坐标（用于把贴图放回原位）。
    func cocoaRect(fromView rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

struct RGBColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "\(red), \(green), \(blue)" }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

enum ScreenGeometry {
    /// 主屏高度：Cocoa 坐标（y 向上）和 CG 全局坐标（y 向下）以它为界互相翻转。
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum ScreenCapturer {
    /// 截取所有屏幕。用 ScreenCaptureKit 而不是已废弃的 `CGWindowListCreateImage`。
    static func captureAllScreens() async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var shots: [ScreenShot] = []

        for screen in NSScreen.screens {
            guard let displayID = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let pixelScale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * pixelScale)
            configuration.height = Int(filter.contentRect.height * pixelScale)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            shots.append(ScreenShot(
                screen: screen,
                frame: screen.frame,
                image: image,
                scale: CGFloat(image.width) / screen.frame.width
            ))
        }

        return shots
    }
}

/// 截图时自动识别鼠标下的窗口；有辅助功能权限时还能细到窗口里的按钮、输入框等界面元素。
///
/// 窗口列表在截图那一刻拍一次快照，和冻结画面保持一致；界面元素按需查询。
final class WindowDetector {
    private struct WindowInfo {
        let frame: CGRect
        let pid: pid_t
    }

    private let windows: [WindowInfo]
    private let usesAccessibility: Bool
    private var applicationElements: [pid_t: AXUIElement] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(usesAccessibility: Bool) {
        self.usesAccessibility = usesAccessibility

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // 普通窗口到菜单栏、状态栏这几层；更高层多是系统的透明遮罩，会挡住下面的窗口。
        let maximumLayer = Int(CGWindowLevelForKey(.statusWindow))
        windows = list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, (0...maximumLayer).contains(layer),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 8, bounds.height >= 8,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { return nil }
            return WindowInfo(frame: bounds, pid: pid)
        }
    }

    /// 鼠标下从小到大的候选区域（全局 CG 坐标）：界面元素……所在窗口。
    func candidates(at point: CGPoint) -> [CGRect] {
        guard let window = windows.first(where: { $0.frame.contains(point) }) else { return [] }

        var result: [CGRect] = []
        if usesAccessibility, window.pid != ownPID {
            // 对自己的进程发辅助功能请求会在主线程上等自己，直到超时。
            result = elementFrames(at: point, pid: window.pid, within: window.frame)
        }
        if result.last != window.frame {
            result.append(window.frame)
        }
        return result
    }

    private func elementFrames(at point: CGPoint, pid: pid_t, within windowFrame: CGRect) -> [CGRect] {
        let application = applicationElement(for: pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return [] }

        var frames: [CGRect] = []
        for _ in 0..<12 {
            let role = stringAttribute(kAXRoleAttribute, of: element)
            if role == kAXApplicationRole as String { break }

            if let frame = frame(of: element) {
                let clipped = frame.intersection(windowFrame)
                if clipped.width >= 4, clipped.height >= 4, clipped.contains(point), frames.last != clipped {
                    frames.append(clipped)
                }
            }
            if role == kAXWindowRole as String { break }

            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return frames
    }

    private func applicationElement(for pid: pid_t) -> AXUIElement {
        if let element = applicationElements[pid] { return element }
        let element = AXUIElementCreateApplication(pid)
        // 无响应的 App 不能拖住截图界面。
        AXUIElementSetMessagingTimeout(element, 0.08)
        applicationElements[pid] = element
        return element
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}

/// 截图、贴图共用的位图工具。
enum SnipImage {
    /// 在“左上角为原点、单位为点”的上下文里绘制，生成指定像素密度的位图。
    /// 同时设置好 `NSGraphicsContext`，文字等 AppKit 绘制也能直接使用。
    static func render(size: CGSize, scale: CGFloat, colorSpace: CGColorSpace? = nil, draw: (CGContext) -> Void) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let space = colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            draw(context)
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// 顺时针（`clockwise`）或逆时针旋转 90°。
    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = image.height, height = image.width
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    /// 写入剪贴板：PNG 给新应用，TIFF 给只认 TIFF 的老应用；都带上点尺寸，粘贴后大小正确。
    static func copyToPasteboard(_ image: CGImage, pixelsPerPoint: CGFloat) {
        let representation = bitmap(image, pixelsPerPoint: pixelsPerPoint)
        let item = NSPasteboardItem()
        if let png = representation.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        if let tiff = representation.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    static func pngData(_ image: CGImage, pixelsPerPoint: CGFloat) -> Data? {
        bitmap(image, pixelsPerPoint: pixelsPerPoint).representation(using: .png, properties: [:])
    }

    private static func bitmap(_ image: CGImage, pixelsPerPoint: CGFloat) -> NSBitmapImageRep {
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = CGSize(width: CGFloat(image.width) / pixelsPerPoint, height: CGFloat(image.height) / pixelsPerPoint)
        return representation
    }

    static func defaultFileName(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "截图 \(formatter.string(from: date)).png"
    }
}

extension CGContext {
    /// 在 y 轴向下的上下文里正向绘制图像（`CGContext.draw` 默认按 y 轴向上绘制，会上下颠倒）。
    func drawUpright(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
