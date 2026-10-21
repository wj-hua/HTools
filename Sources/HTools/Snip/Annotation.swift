import AppKit
import Combine

enum CaptureTool: String, CaseIterable, Identifiable {
    case rectangle, ellipse, arrow, pen, marker, mosaic, text, number

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .marker: return "记号笔"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .number: return "序号"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .marker: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "textformat"
        case .number: return "1.circle"
        }
    }

    /// 截图界面里切换工具的单键快捷键。
    var shortcut: Character {
        switch self {
        case .rectangle: return "r"
        case .ellipse: return "e"
        case .arrow: return "a"
        case .pen: return "p"
        case .marker: return "m"
        case .mosaic: return "x"
        case .text: return "t"
        case .number: return "n"
        }
    }

    /// 马赛克取的是原图像素，颜色没有意义。
    var usesColor: Bool { self != .mosaic }
}

/// 一笔标注。坐标是截图视图坐标（左上角原点，单位点），导出时同一份绘制代码直接复用。
struct Annotation {
    let tool: CaptureTool
    let color: NSColor
    /// 粗细档位：0 细、1 中、2 粗。
    let size: Int
    var points: [CGPoint]
    var text = ""
    var number = 0
    /// 马赛克的低分辨率图，放大绘制时关闭插值即成色块。
    var mosaic: CGImage?

    var lineWidth: CGFloat { [2, 4, 7][size] }
    var markerWidth: CGFloat { [10, 16, 24][size] }
    var fontSize: CGFloat { [16, 22, 32][size] }
    var numberDiameter: CGFloat { [20, 26, 34][size] }
    var mosaicBlock: CGFloat { [6, 10, 16][size] }

    var font: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }

    /// 两点围成的矩形（矩形、椭圆、马赛克）。
    var boxRect: CGRect {
        guard let first = points.first, let last = points.last else { return .null }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// 画完以后是否值得保留（点一下没拖动的形状直接丢弃）。
    var isMeaningful: Bool {
        switch tool {
        case .rectangle, .ellipse, .mosaic: return boxRect.width >= 2 && boxRect.height >= 2
        case .arrow:
            guard let first = points.first, let last = points.last else { return false }
            return hypot(last.x - first.x, last.y - first.y) >= 4
        case .pen, .marker: return points.count >= 2
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .number: return !points.isEmpty
        }
    }

    func draw(in context: CGContext) {
        switch tool {
        case .rectangle:
            stroke(NSBezierPath(rect: boxRect))
        case .ellipse:
            stroke(NSBezierPath(ovalIn: boxRect))
        case .arrow:
            drawArrow()
        case .pen:
            stroke(smoothPath(), width: lineWidth)
        case .marker:
            color.withAlphaComponent(0.4).setStroke()
            let path = smoothPath()
            path.lineWidth = markerWidth
            path.stroke()
        case .mosaic:
            guard let mosaic else { return }
            context.saveGState()
            context.interpolationQuality = .none
            context.drawUpright(mosaic, in: boxRect)
            context.restoreGState()
        case .text:
            guard let origin = points.first else { return }
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: origin)
        case .number:
            guard let center = points.first else { return }
            let diameter = numberDiameter
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: circle).fill()
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.55, weight: .bold),
                .foregroundColor: Self.contrastingTextColor(on: color),
            ])
            let labelSize = label.size()
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2))
        }
    }

    private func stroke(_ path: NSBezierPath, width: CGFloat? = nil) {
        color.setStroke()
        path.lineWidth = width ?? lineWidth
        path.stroke()
    }

    private func smoothPath() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        // 以相邻两点的中点为端点、原始点为控制点，鼠标采样的折线变成平滑曲线。
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let next = points[index + 1]
            path.curve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), controlPoint: control)
        }
        path.line(to: points[points.count - 1])
        return path
    }

    private func drawArrow() {
        guard let start = points.first, let end = points.last else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let length = hypot(end.x - start.x, end.y - start.y)
        let headLength = min(max(12, lineWidth * 4), length)
        let headHalfWidth = headLength * 0.45

        let base = CGPoint(x: end.x - cos(angle) * headLength, y: end.y - sin(angle) * headLength)
        let shaft = NSBezierPath()
        shaft.lineCapStyle = .round
        shaft.move(to: start)
        // 线身停在箭头内部，粗线的端头不会从箭尖两侧露出来。
        shaft.line(to: CGPoint(x: end.x - cos(angle) * headLength * 0.6, y: end.y - sin(angle) * headLength * 0.6))
        stroke(shaft)

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: base.x + sin(angle) * headHalfWidth, y: base.y - cos(angle) * headHalfWidth))
        head.line(to: CGPoint(x: base.x - sin(angle) * headHalfWidth, y: base.y + cos(angle) * headHalfWidth))
        head.close()
        color.setFill()
        head.fill()
    }

    private static func contrastingTextColor(on color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.65 ? .black : .white
    }

    /// 生成马赛克：把原图这块区域缩小到每个色块一个像素。
    static func pixelate(_ shot: ScreenShot, rect: CGRect, block: CGFloat) -> CGImage? {
        let pixelRect = shot.pixelRect(for: rect)
        guard pixelRect.width >= 1, pixelRect.height >= 1, let crop = shot.image.cropping(to: pixelRect) else { return nil }

        let width = max(1, Int((rect.width / block).rounded(.up)))
        let height = max(1, Int((rect.height / block).rounded(.up)))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// 截图编辑状态：当前工具、颜色、粗细与标注的撤销栈。工具栏（SwiftUI）和画布（AppKit）共用。
@MainActor
final class CaptureEditor: ObservableObject {
    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    @Published var tool: CaptureTool? {
        didSet { if tool != oldValue { onToolChange?() } }
    }
    @Published var colorIndex: Int {
        didSet { UserDefaults.standard.set(colorIndex, forKey: "snip.colorIndex") }
    }
    @Published var sizeIndex: Int {
        didSet { UserDefaults.standard.set(sizeIndex, forKey: "snip.sizeIndex") }
    }
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var undone: [Annotation] = []

    /// 画布据此重绘、重新摆放工具栏。
    var onChange: (() -> Void)?
    var onToolChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        colorIndex = min(max(defaults.object(forKey: "snip.colorIndex") as? Int ?? 0, 0), Self.palette.count - 1)
        sizeIndex = min(max(defaults.object(forKey: "snip.sizeIndex") as? Int ?? 1, 0), 2)
    }

    var color: NSColor { Self.palette[colorIndex] }
    var canUndo: Bool { !annotations.isEmpty }
    var canRedo: Bool { !undone.isEmpty }
    var nextNumber: Int { annotations.filter { $0.tool == .number }.count + 1 }

    func makeAnnotation(_ tool: CaptureTool, at point: CGPoint) -> Annotation {
        var annotation = Annotation(tool: tool, color: color, size: sizeIndex, points: [point])
        if tool == .number { annotation.number = nextNumber }
        return annotation
    }

    func add(_ annotation: Annotation) {
        guard annotation.isMeaningful else { return }
        annotations.append(annotation)
        undone.removeAll()
        onChange?()
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undone.append(last)
        onChange?()
    }

    func redo() {
        guard let last = undone.popLast() else { return }
        annotations.append(last)
        onChange?()
    }

    func reset() {
        tool = nil
        annotations.removeAll()
        undone.removeAll()
        onChange?()
    }
}
