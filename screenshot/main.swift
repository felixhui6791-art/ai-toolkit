import Cocoa
import Vision

let PROJ = (NSHomeDirectory() as NSString).appendingPathComponent("Hui/ai-toolkit")

// ===== OCR / 翻译 =====
func runOCR(_ image: NSImage, _ completion: @escaping (String) -> Void) {
    guard let t = image.tiffRepresentation, let b = NSBitmapImageRep(data: t), let cg = b.cgImage else { completion(""); return }
    let req = VNRecognizeTextRequest { req, _ in
        let obs = req.results as? [VNRecognizedTextObservation] ?? []
        let s = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        DispatchQueue.main.async { completion(s) }
    }
    req.recognitionLevel = .accurate; req.recognitionLanguages = ["zh-Hans", "en-US"]; req.usesLanguageCorrection = true
    DispatchQueue.global().async { try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) }
}
func normalize(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }

func llmTranslateOnce(_ userPrompt: String) -> String {
    let tmp = NSTemporaryDirectory() + "aishot_ocr.txt"
    try? userPrompt.write(toFile: tmp, atomically: true, encoding: .utf8)
    let p = Process(); p.executableURL = URL(fileURLWithPath: PROJ + "/.venv/bin/python")
    p.arguments = [PROJ + "/core/llm.py", "--system", "你是翻译引擎，只输出译文本身。", "--infile", tmp]
    let outPipe = Pipe(), errPipe = Pipe(); p.standardOutput = outPipe; p.standardError = errPipe
    try? p.run(); p.waitUntilExit()
    let out = (String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if out.isEmpty {
        let err = (String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? "" : "翻译失败：\(err)"
    }
    return out
}

func translate(_ text: String) -> String {
    // 强力指令：连文件名/术语也翻，避免模型把英文当专有名词照抄
    let prompt1 = "把下面的内容翻译成简体中文：其中的英文单词/短语都要译成中文意思，即使它是文件名、文件夹名或技术术语也必须翻译（例如 core=核心、bin=程序目录、logs=日志、models=模型、tools=工具、setup=配置、ui=界面、README=自述文件）。保留文件后缀(如 .md/.json)。已经是中文的原样保留。只输出结果，不要原文、不要解释：\n\n\(text)"
    var out = llmTranslateOnce(prompt1)
    if out.isEmpty || normalize(out) == normalize(text) {
        let prompt2 = "下面每一项请改写成简体中文，把所有英文都译成中文意思，禁止照抄原文，只输出中文：\n\n\(text)"
        let retry = llmTranslateOnce(prompt2)
        if !retry.isEmpty { out = retry }
    }
    return out.isEmpty ? "（翻译失败，请重试一次）" : out
}
func saveToLibrary(_ image: NSImage) {
    let lib = (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/截图收集")
    try? FileManager.default.createDirectory(atPath: lib, withIntermediateDirectories: true)
    let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd_HHmmss_SSS"
    let path = lib + "/截图_" + fmt.string(from: Date()) + ".png"
    if let t = image.tiffRepresentation, let b = NSBitmapImageRep(data: t), let png = b.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

func showResult(_ title: String, _ text: String) {
    let a = NSAlert(); a.messageText = title; a.informativeText = text.isEmpty ? "（没识别到文字）" : text
    a.addButton(withTitle: "复制并关闭"); a.addButton(withTitle: "关闭"); NSApp.activate(ignoringOtherApps: true)
    if a.runModal() == .alertFirstButtonReturn { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

enum Tool { case none, rect, arrow, pen, highlighter, mosaic, text, eraser }
struct Annotation { var tool: Tool; var color: NSColor; var width: CGFloat
    var rect: CGRect = .zero; var points: [CGPoint] = []; var p0: CGPoint = .zero; var p1: CGPoint = .zero
    var text: String = ""; var fontSize: CGFloat = 20 }

// ===================================================================
//  ShotView：定格全屏图 + 选区(可调整) + 标注，全部一层完成
// ===================================================================
class ShotView: NSView, NSTextFieldDelegate {
    let image: NSImage
    lazy var imageCG: CGImage? = { guard let t = image.tiffRepresentation, let b = NSBitmapImageRep(data: t) else { return nil }; return b.cgImage }()
    var sel: CGRect = .zero; var hasSel = false
    enum Handle { case none, move, tl, tr, bl, br, t, b, l, r }
    var anns: [Annotation] = []; var undoStack: [[Annotation]] = []; var redoStack: [[Annotation]] = []
    var cur: Annotation?
    var tool: Tool = .none; var color: NSColor = .systemRed; var width: CGFloat = 4
    enum Mode { case idle, creatingSel, movingSel, resizing, drawing, erasing }
    var mode: Mode = .idle; var dragHandle: Handle = .none
    var dragMouse: CGPoint = .zero; var dragRect: CGRect = .zero; var createOrigin: CGPoint = .zero
    var activeField: NSTextField?
    var onSelChanged: (() -> Void)?
    var rScale: CGFloat = 1; var rOff: CGPoint = .zero
    let hh: CGFloat = 9
    var cursor: CGPoint = .zero; var hasCursor = false
    var colorHex = false; var copiedFlash = false
    var selectOnly = false   // 长截图“只选区”模式：回车把选区写出后退出
    var editor = false       // 长图编辑器模式：整张图为画布，无变暗/无框选，只标注
    var dupes: [(y: Int, off: Int)] = []   // 可疑接缝位置(编辑器画橙色提示横线)
    lazy var bitmap: NSBitmapImageRep? = { guard let t = image.tiffRepresentation else { return nil }; return NSBitmapImageRep(data: t) }()

    init(frame: NSRect, image: NSImage) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func viewDidMoveToWindow() {
        NSCursor.crosshair.set()
        window?.acceptsMouseMovedEvents = true
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseMoved(with e: NSEvent) {
        let pad: CGFloat = 270
        setNeedsDisplay(NSRect(x: cursor.x-pad, y: cursor.y-pad, width: pad*2, height: pad*2))
        cursor = convert(e.locationInWindow, from: nil); hasCursor = true
        setNeedsDisplay(NSRect(x: cursor.x-pad, y: cursor.y-pad, width: pad*2, height: pad*2))
    }
    override func flagsChanged(with e: NSEvent) { if e.modifierFlags.contains(.shift) { colorHex.toggle(); needsDisplay = true } }

    // —— 撤销 ——
    func pushUndo() { undoStack.append(anns); redoStack.removeAll() }
    func undo() { guard let s = undoStack.popLast() else { return }; redoStack.append(anns); anns = s; needsDisplay = true }
    func redo() { guard let s = redoStack.popLast() else { return }; undoStack.append(anns); anns = s; needsDisplay = true }

    // —— 坐标映射（屏显=原样；导出=减选区原点再放大）——
    func sclP(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - rOff.x) * rScale, y: (p.y - rOff.y) * rScale) }
    func scl(_ r: CGRect) -> CGRect { CGRect(x: (r.minX - rOff.x) * rScale, y: (r.minY - rOff.y) * rScale, width: r.width * rScale, height: r.height * rScale) }

    // —— 选区控制点 ——
    func handleRects() -> [(Handle, CGRect)] {
        let r = sel, mx = r.midX, my = r.midY
        let pts: [(Handle, CGPoint)] = [(.tl, .init(x: r.minX, y: r.minY)), (.tr, .init(x: r.maxX, y: r.minY)),
            (.bl, .init(x: r.minX, y: r.maxY)), (.br, .init(x: r.maxX, y: r.maxY)), (.t, .init(x: mx, y: r.minY)),
            (.b, .init(x: mx, y: r.maxY)), (.l, .init(x: r.minX, y: my)), (.r, .init(x: r.maxX, y: my))]
        return pts.map { ($0.0, CGRect(x: $0.1.x - hh, y: $0.1.y - hh, width: hh*2, height: hh*2)) }
    }
    func handleAt(_ p: CGPoint) -> Handle { if !hasSel { return .none }; for (h, r) in handleRects() where r.contains(p) { return h }; return sel.contains(p) ? .move : .none }
    func norm(_ r: CGRect) -> CGRect { CGRect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY), width: abs(r.width), height: abs(r.height)) }
    func resize(_ r: CGRect, _ h: Handle, _ p: CGPoint) -> CGRect {
        var a = r.minX, b = r.minY, c = r.maxX, d = r.maxY
        switch h { case .tl: a = p.x; b = p.y; case .tr: c = p.x; b = p.y; case .bl: a = p.x; d = p.y; case .br: c = p.x; d = p.y
        case .t: b = p.y; case .b: d = p.y; case .l: a = p.x; case .r: c = p.x; default: break }
        return norm(CGRect(x: a, y: b, width: c-a, height: d-b))
    }

    // —— 画一条标注 ——
    func drawOne(_ a: Annotation) {
        let lw = a.width * rScale
        switch a.tool {
        case .rect: a.color.setStroke(); let p = NSBezierPath(rect: scl(a.rect)); p.lineWidth = lw; p.stroke()
        case .arrow: a.color.setStroke(); a.color.setFill(); drawArrow(sclP(a.p0), sclP(a.p1), lw)
        case .pen:
            guard a.points.count > 1 else { break }; a.color.setStroke()
            let p = NSBezierPath(); p.lineWidth = lw; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: sclP(a.points[0])); for q in a.points.dropFirst() { p.line(to: sclP(q)) }; p.stroke()
        case .highlighter:
            guard a.points.count > 1 else { break }; a.color.withAlphaComponent(0.35).setStroke()
            let p = NSBezierPath(); p.lineWidth = a.width*5*rScale; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: sclP(a.points[0])); for q in a.points.dropFirst() { p.line(to: sclP(q)) }; p.stroke()
        case .mosaic: drawMosaic(a.rect)
        case .text: a.text.draw(at: sclP(a.p0), withAttributes: [.font: NSFont.boldSystemFont(ofSize: a.fontSize*rScale), .foregroundColor: a.color])
        case .none, .eraser: break
        }
    }
    func drawArrow(_ from: CGPoint, _ to: CGPoint, _ lw: CGFloat) {
        let p = NSBezierPath(); p.lineWidth = lw; p.lineCapStyle = .round; p.move(to: from); p.line(to: to)
        let ang = atan2(to.y-from.y, to.x-from.x), len = max(12, lw*4)
        for da in [CGFloat.pi*0.83, -CGFloat.pi*0.83] { p.move(to: to); p.line(to: CGPoint(x: to.x+cos(ang+da)*len, y: to.y+sin(ang+da)*len)) }
        p.stroke()
    }
    func drawMosaic(_ vr: CGRect) {
        guard let cg = imageCG, vr.width > 2, vr.height > 2 else { return }
        let px = CGFloat(cg.width) / bounds.width
        let pr = CGRect(x: vr.minX*px, y: vr.minY*px, width: vr.width*px, height: vr.height*px)
        guard let sub = cg.cropping(to: pr) else { return }
        let sw = 14, sh = max(1, Int(14.0 * pr.height / pr.width))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sw, pixelsHigh: sh, bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx; ctx.imageInterpolation = .medium
            NSImage(cgImage: sub, size: NSSize(width: sub.width, height: sub.height)).draw(in: NSRect(x: 0, y: 0, width: sw, height: sh))
            NSGraphicsContext.restoreGraphicsState()
        }
        let small = NSImage(size: NSSize(width: sw, height: sh)); small.addRepresentation(rep)
        NSGraphicsContext.current?.imageInterpolation = .none; small.draw(in: scl(vr)); NSGraphicsContext.current?.imageInterpolation = .default
    }

    override func draw(_ dirty: NSRect) {
        image.draw(in: bounds)
        if editor {                                   // 编辑器模式：整图为画布，直接画标注，无变暗/控制点/放大镜
            rScale = 1; rOff = .zero
            for a in anns { drawOne(a) }; if let c = cur { drawOne(c) }
            // 在可疑接缝位置画橙色提示横线 + 右侧 chip 标记
            for d in dupes {
                let yy = CGFloat(d.y), oh = CGFloat(d.off)
                NSColor.systemOrange.withAlphaComponent(0.35).setFill()
                NSRect(x: 0, y: yy, width: bounds.width, height: oh).fill()
                NSColor.systemOrange.setStroke()
                let p = NSBezierPath(rect: NSRect(x: 0.5, y: yy + 0.5, width: bounds.width - 1, height: oh - 1)); p.lineWidth = 2; p.stroke()
                // 标签
                let tag = "可能叠 \(d.off)px → 点'一键裁'消除"
                let attr: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13),
                    .foregroundColor: NSColor.white, .backgroundColor: NSColor.systemOrange]
                tag.draw(at: NSPoint(x: 10, y: yy + 4), withAttributes: attr)
            }
            return
        }
        let dim = NSColor(white: 0, alpha: 0.45)
        if !hasSel {
            dim.setFill(); bounds.fill()
            "拖动选择截图区域".draw(at: NSPoint(x: bounds.midX-70, y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.white, .backgroundColor: NSColor(white: 0, alpha: 0.5)])
        } else {
            dim.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: sel.minY).fill()
            NSRect(x: 0, y: sel.maxY, width: bounds.width, height: bounds.height - sel.maxY).fill()
            NSRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height).fill()
            NSRect(x: sel.maxX, y: sel.minY, width: bounds.width - sel.maxX, height: sel.height).fill()
            rScale = 1; rOff = .zero
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: sel).addClip()
            for a in anns { drawOne(a) }; if let c = cur { drawOne(c) }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke(); let bp = NSBezierPath(rect: sel); bp.lineWidth = 2; bp.stroke()
            NSColor.white.setFill()
            for (_, hr) in handleRects() { let d = NSBezierPath(ovalIn: hr.insetBy(dx: 2, dy: 2)); d.fill(); NSColor.systemBlue.setStroke(); d.lineWidth = 1.5; d.stroke() }
            var ly = sel.minY - 20; if ly < 2 { ly = sel.minY + 4 }
            "\(Int(sel.width)) × \(Int(sel.height))".draw(at: NSPoint(x: sel.minX+2, y: ly), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .backgroundColor: NSColor(white: 0, alpha: 0.6)])
        }
        if selectOnly {
            let banner = "📜 长截图：拖框选择「滚动区域」 → 双击 或 回车↩︎ 确认 → Esc 取消"
            let at: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15),
                .foregroundColor: NSColor.white, .backgroundColor: NSColor(white: 0, alpha: 0.7)]
            let sz = banner.size(withAttributes: at)
            banner.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: 22), withAttributes: at)
        }
        if tool == .none && hasCursor { drawLoupe() }
    }

    func colorAt(_ p: CGPoint) -> NSColor? {
        guard let bm = bitmap else { return nil }
        let sx = CGFloat(bm.pixelsWide) / bounds.width
        let x = Int(p.x * sx), y = Int(p.y * sx)
        if x < 0 || y < 0 || x >= bm.pixelsWide || y >= bm.pixelsHigh { return nil }
        return bm.colorAt(x: x, y: y)
    }
    func colorString(_ c: NSColor) -> String {
        guard let rc = c.usingColorSpace(.deviceRGB) else { return "-" }
        let r = Int(round(rc.redComponent*255)), g = Int(round(rc.greenComponent*255)), b = Int(round(rc.blueComponent*255))
        return colorHex ? String(format: "#%02X%02X%02X", r, g, b) : "\(r), \(g), \(b)"
    }
    func drawLoupe() {
        guard let cg = imageCG else { return }
        let L: CGFloat = 130, panelH: CGFloat = 96, gap: CGFloat = 16, N = 13
        let scale = CGFloat(cg.width) / bounds.width
        let half = CGFloat(N)/2
        let crop = CGRect(x: cursor.x*scale - half, y: cursor.y*scale - half, width: CGFloat(N), height: CGFloat(N))
        var lx = cursor.x + gap, ly = cursor.y + gap
        if lx + L > bounds.width - 4 { lx = cursor.x - gap - L }
        if ly + L + panelH > bounds.height - 4 { ly = cursor.y - gap - L - panelH }
        lx = max(4, lx); ly = max(4, ly)
        let loupe = NSRect(x: lx, y: ly, width: L, height: L)
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: loupe).addClip()
        if let sub = cg.cropping(to: crop) {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: sub, size: crop.size).draw(in: loupe)
            NSGraphicsContext.current?.imageInterpolation = .default
        } else { NSColor.darkGray.setFill(); loupe.fill() }
        let cell = L/CGFloat(N)
        NSColor(white: 1, alpha: 0.4).setStroke()
        let v = NSBezierPath(); v.lineWidth = cell; v.move(to: NSPoint(x: loupe.midX, y: loupe.minY)); v.line(to: NSPoint(x: loupe.midX, y: loupe.maxY)); v.stroke()
        let hb = NSBezierPath(); hb.lineWidth = cell; hb.move(to: NSPoint(x: loupe.minX, y: loupe.midY)); hb.line(to: NSPoint(x: loupe.maxX, y: loupe.midY)); hb.stroke()
        NSColor.black.setStroke(); let cbx = NSBezierPath(rect: NSRect(x: loupe.midX-cell/2, y: loupe.midY-cell/2, width: cell, height: cell)); cbx.lineWidth = 1.5; cbx.stroke()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke(); let bd = NSBezierPath(rect: loupe); bd.lineWidth = 1; bd.stroke()
        // 信息面板
        let panel = NSRect(x: lx, y: loupe.maxY, width: L, height: panelH)
        NSColor(white: 0.1, alpha: 0.92).setFill(); panel.fill()
        let col = colorAt(cursor)
        let wAttr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
        let sAttr: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.82, alpha: 1)]
        "(\(Int(cursor.x)), \(Int(cursor.y)))".draw(at: NSPoint(x: lx+10, y: panel.minY+8), withAttributes: wAttr)
        if let c = col { c.setFill(); let sw = NSRect(x: lx+10, y: panel.minY+32, width: 13, height: 13); sw.fill(); NSColor.white.setStroke(); NSBezierPath(rect: sw).stroke()
            colorString(c).draw(at: NSPoint(x: lx+30, y: panel.minY+30), withAttributes: wAttr) }
        (copiedFlash ? "已复制 ✓" : "按 C 复制颜色值").draw(at: NSPoint(x: lx+10, y: panel.minY+54), withAttributes: sAttr)
        "按 Shift 切换 RGB/HEX".draw(at: NSPoint(x: lx+10, y: panel.minY+74), withAttributes: sAttr)
    }

    // —— 橡皮命中 ——
    func distSeg(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y; if dx == 0 && dy == 0 { return hypot(p.x-a.x, p.y-a.y) }
        let t = max(0, min(1, ((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy))); return hypot(p.x-(a.x+t*dx), p.y-(a.y+t*dy))
    }
    func hit(_ a: Annotation, _ p: CGPoint) -> Bool {
        switch a.tool {
        case .rect: return abs(a.rect.minX-p.x) < 8 || abs(a.rect.maxX-p.x) < 8 || abs(a.rect.minY-p.y) < 8 || abs(a.rect.maxY-p.y) < 8
        case .mosaic: return a.rect.contains(p)
        case .pen, .highlighter: return a.points.contains { hypot($0.x-p.x, $0.y-p.y) < a.width*2 + 8 }
        case .arrow: return distSeg(p, a.p0, a.p1) < a.width + 8
        case .text: return CGRect(x: a.p0.x, y: a.p0.y - a.fontSize, width: 220, height: a.fontSize*1.5).contains(p)
        default: return false
        }
    }
    func eraseAt(_ p: CGPoint) { let n = anns.count; anns.removeAll { hit($0, p) }; if anns.count != n { needsDisplay = true } }

    // —— 鼠标 ——
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if selectOnly && e.clickCount >= 2 && hasSel && sel.contains(p) { confirmSelectOnly(); return }  // 双击确认
        if !editor {
            let h = handleAt(p)
            if hasSel && h != .none && h != .move { mode = .resizing; dragHandle = h; dragRect = sel; dragMouse = p; return }
        }
        switch tool {
        case .none:
            if editor { break }                       // 编辑器模式无框选操作（滚动条/触控板翻页）
            if hasSel && sel.contains(p) { mode = .movingSel; dragMouse = p; dragRect = sel }
            else { mode = .creatingSel; createOrigin = p; sel = CGRect(origin: p, size: .zero); hasSel = true }
        case .eraser: pushUndo(); mode = .erasing; eraseAt(p)
        case .text: startText(at: p)
        default:
            pushUndo(); mode = .drawing; cur = Annotation(tool: tool, color: color, width: width)
            if tool == .pen || tool == .highlighter { cur?.points = [p] } else { cur?.p0 = p; cur?.p1 = p; cur?.rect = CGRect(origin: p, size: .zero) }
        }
        needsDisplay = true
    }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        cursor = p; hasCursor = true
        switch mode {
        case .creatingSel: sel = norm(CGRect(x: createOrigin.x, y: createOrigin.y, width: p.x-createOrigin.x, height: p.y-createOrigin.y))
        case .movingSel: sel = dragRect.offsetBy(dx: p.x-dragMouse.x, dy: p.y-dragMouse.y)
        case .resizing: sel = resize(dragRect, dragHandle, p)
        case .drawing:
            if var c = cur {
                if tool == .pen || tool == .highlighter { c.points.append(p) }
                else { c.p1 = p; c.rect = CGRect(x: min(c.p0.x, p.x), y: min(c.p0.y, p.y), width: abs(p.x - c.p0.x), height: abs(p.y - c.p0.y)) }
                cur = c
            }
        case .erasing: eraseAt(p)
        default: break
        }
        needsDisplay = true
    }
    override func mouseUp(with e: NSEvent) {
        switch mode {
        case .creatingSel, .movingSel, .resizing: sel = norm(sel); onSelChanged?()
        case .drawing:
            if let c = cur { var keep = true
                if c.tool == .rect || c.tool == .mosaic { keep = c.rect.width > 3 && c.rect.height > 3 }
                else if c.tool == .arrow { keep = hypot(c.p1.x-c.p0.x, c.p1.y-c.p0.y) > 5 }
                else if c.tool == .pen || c.tool == .highlighter { keep = c.points.count > 1 }
                if keep { anns.append(c) } else if !undoStack.isEmpty { undoStack.removeLast() } }
            cur = nil
        default: break
        }
        mode = .idle; needsDisplay = true
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { NSApp.terminate(nil); return }   // ESC
        if selectOnly && (e.keyCode == 36 || e.keyCode == 76) { confirmSelectOnly(); return }   // 回车确认
        if (e.charactersIgnoringModifiers ?? "").lowercased() == "c", tool == .none, let c = colorAt(cursor) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(colorString(c), forType: .string)
            copiedFlash = true; needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.copiedFlash = false; self.needsDisplay = true }
        }
    }

    func confirmSelectOnly() {
        if hasSel {
            let s = sel
            try? "\(Int(s.minX)),\(Int(s.minY)),\(Int(s.width)),\(Int(s.height))".write(toFile: "/tmp/airegion.txt", atomically: true, encoding: .utf8)
        }
        NSApp.terminate(nil)
    }
    func startText(at p: CGPoint) {
        pushUndo()
        let tf = NSTextField(frame: NSRect(x: p.x, y: p.y - 13, width: 240, height: 26))
        tf.font = NSFont.boldSystemFont(ofSize: 20); tf.textColor = color; tf.backgroundColor = .clear
        tf.isBordered = true; tf.focusRingType = .none; tf.placeholderString = "输入文字，回车确认"; tf.delegate = self
        addSubview(tf); activeField = tf; window?.makeFirstResponder(tf)
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let tf = activeField else { return }
        let s = tf.stringValue, o = tf.frame.origin; tf.removeFromSuperview(); activeField = nil
        if !s.isEmpty { var a = Annotation(tool: .text, color: color, width: width); a.text = s; a.p0 = CGPoint(x: o.x+2, y: o.y+4); anns.append(a); needsDisplay = true }
        else if !undoStack.isEmpty { undoStack.removeLast() }
        window?.makeFirstResponder(self)
    }

    // —— 导出：裁剪选区 + 合成标注 ——
    func result() -> NSImage? {
        guard hasSel, let cg = imageCG else { return nil }
        let sc = CGFloat(cg.width) / bounds.width   // 用真实像素宽，兼容 Retina
        let pr = CGRect(x: sel.minX*sc, y: sel.minY*sc, width: sel.width*sc, height: sel.height*sc)
        guard let cropped = cg.cropping(to: pr) else { return nil }
        let out = NSImage(size: NSSize(width: pr.width, height: pr.height)); out.lockFocusFlipped(true)
        NSImage(cgImage: cropped, size: NSSize(width: pr.width, height: pr.height)).draw(in: NSRect(x: 0, y: 0, width: pr.width, height: pr.height))
        rScale = sc; rOff = sel.origin
        for a in anns { drawOne(a) }
        rScale = 1; rOff = .zero
        out.unlockFocus(); return out
    }
}

// ===== 钉图窗口 =====
class PinView: NSImageView {
    var anchor: NSPoint = .zero
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount >= 2 { NSApp.terminate(nil); return }   // 双击关闭
        anchor = NSEvent.mouseLocation
    }
    override func mouseDragged(with e: NSEvent) {               // 手动拖动窗口
        let now = NSEvent.mouseLocation
        if let w = window { w.setFrameOrigin(NSPoint(x: w.frame.origin.x + (now.x - anchor.x), y: w.frame.origin.y + (now.y - anchor.y))) }
        anchor = now
    }
    override func rightMouseDown(with e: NSEvent) { NSApp.terminate(nil) }  // 右键关闭
}
class PinWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ f: NSRect, to s: NSScreen?) -> NSRect { f }
    override func cancelOperation(_ s: Any?) { NSApp.terminate(nil) }       // ESC 关闭
    init(image: NSImage, at: NSRect) {
        super.init(contentRect: at, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .statusBar; hasShadow = true; backgroundColor = .clear; isOpaque = false
        let iv = PinView(frame: NSRect(origin: .zero, size: at.size)); iv.image = image; iv.imageScaling = .scaleAxesIndependently
        contentView = iv
        setFrame(at, display: true)
    }
}

// ===== 截图主窗口（全屏定格层 + 工具栏） =====
class ShotWindow: NSWindow {
    let shot: ShotView
    let screenFrame: NSRect
    var mainPill: NSView!, subPill: NSView!
    var toolBtns: [Int: NSButton] = [:]
    let tagTool: [Int: Tool] = [1: .rect, 2: .arrow, 3: .pen, 4: .highlighter, 5: .mosaic, 6: .text, 7: .eraser]
    var colorList: [NSColor] = []
    var pinWin: PinWindow?
    var resultPanel: NSView?
    var resultTextView: NSTextView?
    var resultText = ""
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ s: Any?) { NSApp.terminate(nil) }

    init(screen: NSScreen, image: NSImage, selectOnly: Bool = false) {
        screenFrame = screen.frame
        shot = ShotView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver; isOpaque = true; backgroundColor = .black; hasShadow = false
        contentView = shot
        shot.selectOnly = selectOnly
        if !selectOnly {
            buildBars()
            shot.onSelChanged = { [weak self] in self?.layoutBars() }
        }
        makeFirstResponder(shot)
    }

    func icon(_ sym: String, _ fb: String, _ act: Selector, _ tag: Int = 0, isTool: Bool = false) -> NSButton {
        let b = NSButton(); b.target = self; b.action = act; b.tag = tag
        if let im = NSImage(systemSymbolName: sym, accessibilityDescription: nil) { b.image = im; b.imagePosition = .imageOnly; b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular) } else { b.title = fb }
        b.isBordered = false; b.bezelStyle = .regularSquare; b.contentTintColor = .darkGray
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true; b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if isTool { toolBtns[tag] = b }
        return b
    }
    func sep() -> NSView { let v = NSBox(); v.boxType = .separator; v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true; v.heightAnchor.constraint(equalToConstant: 20).isActive = true; return v }
    func pill(_ items: [NSView]) -> NSView {
        let st = NSStackView(views: items); st.orientation = .horizontal; st.spacing = 7; st.alignment = .centerY
        st.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12); st.layoutSubtreeIfNeeded()
        let sz = st.fittingSize
        let bg = NSView(frame: NSRect(x: 0, y: 0, width: sz.width, height: sz.height))
        bg.wantsLayer = true; bg.layer?.backgroundColor = NSColor.white.cgColor; bg.layer?.cornerRadius = 11
        bg.layer?.shadowColor = NSColor.black.cgColor; bg.layer?.shadowOpacity = 0.25; bg.layer?.shadowRadius = 6; bg.layer?.shadowOffset = .zero
        st.frame = bg.bounds; st.autoresizingMask = [.width, .height]; bg.addSubview(st); return bg
    }
    func buildBars() {
        mainPill = pill([
            icon("rectangle", "▭", #selector(pickTool(_:)), 1, isTool: true),
            icon("arrow.up.right", "↗", #selector(pickTool(_:)), 2, isTool: true),
            icon("pencil.tip", "✏︎", #selector(pickTool(_:)), 3, isTool: true),
            icon("highlighter", "▰", #selector(pickTool(_:)), 4, isTool: true),
            icon("square.grid.3x3.fill", "▦", #selector(pickTool(_:)), 5, isTool: true),
            icon("textformat", "T", #selector(pickTool(_:)), 6, isTool: true),
            icon("eraser", "⌫", #selector(pickTool(_:)), 7, isTool: true),
            sep(), icon("arrow.uturn.backward", "↶", #selector(doUndo)), icon("arrow.uturn.forward", "↷", #selector(doRedo)),
            sep(), icon("xmark", "✕", #selector(doCancel)), icon("pin", "📌", #selector(doPin)),
            icon("square.and.arrow.down", "💾", #selector(doSave)), icon("doc.on.doc", "❐", #selector(doCopy)),
            sep(), icon("text.viewfinder", "字", #selector(doOCR)), icon("globe", "译", #selector(doTranslate)),
        ])
        colorList = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]
        var items: [NSView] = colorList.enumerated().map { (i, c) in
            let b = NSButton(); b.title = ""; b.bezelStyle = .circular; b.isBordered = true; b.bezelColor = c
            b.target = self; b.action = #selector(pickColor(_:)); b.tag = i; b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true; b.heightAnchor.constraint(equalToConstant: 22).isActive = true; return b
        }
        items.append(sep())
        for (i, n) in ["细", "中", "粗"].enumerated() { let b = NSButton(title: n, target: self, action: #selector(pickWidth(_:))); b.bezelStyle = .rounded; b.tag = i; b.translatesAutoresizingMaskIntoConstraints = false; items.append(b) }
        subPill = pill(items)
        mainPill.isHidden = true; subPill.isHidden = true
        shot.addSubview(mainPill); shot.addSubview(subPill)
    }
    func layoutBars() {
        if mainPill == nil { return }   // 只选区模式没有工具栏
        guard shot.hasSel else { mainPill.isHidden = true; subPill.isHidden = true; return }
        mainPill.isHidden = false
        let s = shot.sel
        let bw = shot.bounds.width, bh = shot.bounds.height
        var mx = s.midX - mainPill.frame.width/2
        mx = max(8, min(mx, bw - mainPill.frame.width - 8))
        var my = s.maxY + 10                                   // 选区下方（翻转坐标：y 向下）
        if my + mainPill.frame.height + (subPill.isHidden ? 0 : subPill.frame.height) > bh - 6 { my = s.minY - mainPill.frame.height - 10 }
        if my < 6 { my = 6 }
        mainPill.setFrameOrigin(NSPoint(x: mx, y: my))
        let sx = s.midX - subPill.frame.width/2
        subPill.setFrameOrigin(NSPoint(x: max(8, min(sx, bw - subPill.frame.width - 8)), y: my + mainPill.frame.height + 6))
    }
    @objc func pickTool(_ b: NSButton) {
        let t = tagTool[b.tag] ?? .none; shot.tool = t
        for (tag, btn) in toolBtns { btn.contentTintColor = (tag == b.tag) ? .systemBlue : .darkGray }
        subPill.isHidden = !(t == .rect || t == .arrow || t == .pen || t == .highlighter || t == .text)
        layoutBars()
    }
    @objc func pickColor(_ b: NSButton) { if b.tag < colorList.count { shot.color = colorList[b.tag] } }
    @objc func pickWidth(_ b: NSButton) { shot.width = [2.0, 4.0, 8.0][b.tag] }
    @objc func doUndo() { shot.undo() }
    @objc func doRedo() { shot.redo() }
    @objc func doCancel() { NSApp.terminate(nil) }
    @objc func doCopy() { if let im = shot.result() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([im]); saveToLibrary(im) }; NSApp.terminate(nil) }
    @objc func doSave() {
        guard let im = shot.result() else { NSApp.terminate(nil); return }
        saveToLibrary(im)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "截图.png"; panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url, let t = im.tiffRepresentation, let bmp = NSBitmapImageRep(data: t), let png = bmp.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        NSApp.terminate(nil)
    }
    @objc func doPin() {
        guard let im = shot.result() else { return }
        saveToLibrary(im)
        let rectScreen = self.convertToScreen(shot.convert(shot.sel, to: nil))
        self.orderOut(nil)
        let win = PinWindow(image: im, at: rectScreen)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        self.pinWin = win
    }
    @objc func doOCR() {
        guard let im = shot.result() else { return }
        showResultPanel("⏳ 识别中…")
        runOCR(im) { [weak self] text in self?.updateResult(text.isEmpty ? "（没识别到文字）" : text) }
    }
    @objc func doTranslate() {
        guard let im = shot.result() else { return }
        showResultPanel("⏳ 翻译中…")
        runOCR(im) { [weak self] text in
            if text.isEmpty { self?.updateResult("（没识别到文字）"); return }
            DispatchQueue.global().async { let t = translate(text); DispatchQueue.main.async { self?.updateResult(t) } }
        }
    }
    func showResultPanel(_ text: String) {
        resultPanel?.removeFromSuperview()
        mainPill.isHidden = true; subPill.isHidden = true       // 读结果时先收起工具栏
        let s = shot.sel
        let W: CGFloat = max(320, min(s.width, 560)), H: CGFloat = 180
        let p = NSView()
        p.wantsLayer = true; p.layer?.backgroundColor = NSColor.white.cgColor; p.layer?.cornerRadius = 12
        p.layer?.shadowColor = NSColor.black.cgColor; p.layer?.shadowOpacity = 0.28; p.layer?.shadowRadius = 8; p.layer?.shadowOffset = .zero
        let scroll = NSScrollView(frame: NSRect(x: 12, y: 46, width: W-24, height: H-58))
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isSelectable = true; tv.drawsBackground = false
        tv.font = NSFont.systemFont(ofSize: 14); tv.string = text; tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.minSize = NSSize(width: 0, height: 0); tv.maxSize = NSSize(width: 1e7, height: 1e7); tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        p.addSubview(scroll); resultTextView = tv; resultText = text
        let copyB = NSButton(title: "复制", target: self, action: #selector(copyResult)); copyB.bezelStyle = .rounded; copyB.frame = NSRect(x: W-156, y: 9, width: 66, height: 30)
        let closeB = NSButton(title: "关闭", target: self, action: #selector(closeResult)); closeB.bezelStyle = .rounded; closeB.frame = NSRect(x: W-82, y: 9, width: 66, height: 30)
        p.addSubview(copyB); p.addSubview(closeB)
        var px = s.midX - W/2; px = max(8, min(px, shot.bounds.width - W - 8))
        var py = s.maxY + 12
        if py + H > shot.bounds.height - 8 { py = s.minY - H - 12 }       // 下方放不下就放上方
        if py < 8 { py = 8 }
        p.frame = NSRect(x: px, y: py, width: W, height: H)
        shot.addSubview(p); resultPanel = p
    }
    func updateResult(_ text: String) { resultText = text; resultTextView?.string = text }
    @objc func copyResult() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(resultText, forType: .string)
    }
    @objc func closeResult() { resultPanel?.removeFromSuperview(); resultPanel = nil; layoutBars() }
}

// ===== 长图标注编辑器（可滚动窗口 + 固定工具栏） =====
class EditorWindow: NSWindow {
    var shot: ShotView
    var scrollView: NSScrollView!
    var toolBtns: [Int: NSButton] = [:]
    let tagTool: [Int: Tool] = [1: .rect, 2: .arrow, 3: .pen, 4: .highlighter, 5: .mosaic, 6: .text, 7: .eraser]
    let colorList: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]
    let savePath: String
    let origImage: NSImage                                 // 保留原始拼接图(裁剪是非破坏性的)
    var dupes: [(y: Int, off: Int)] = []                   // 可疑接缝列表(从 .dupes 读)
    var dupeChipLabel: NSTextField?                        // "⚠️ N 处可疑" 提示
    var dupeButtons: [NSButton] = []                       // "一键裁/清除标记/逐个review" 按钮
    override var canBecomeKey: Bool { true }

    func tbtn(_ sym: String, _ fb: String, _ act: Selector, _ tag: Int = 0, isTool: Bool = false) -> NSButton {
        let b = NSButton(); b.target = self; b.action = act; b.tag = tag
        if let im = NSImage(systemSymbolName: sym, accessibilityDescription: nil) { b.image = im; b.imagePosition = .imageOnly
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular) } else { b.title = fb }
        b.isBordered = false; b.bezelStyle = .regularSquare; b.contentTintColor = .darkGray
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true; b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if isTool { toolBtns[tag] = b }
        return b
    }

    init(image: NSImage, savePath: String) {
        self.savePath = savePath
        self.origImage = image
        let isz = image.size
        shot = ShotView(frame: NSRect(origin: .zero, size: isz), image: image)
        shot.editor = true; shot.hasSel = true; shot.sel = NSRect(origin: .zero, size: isz)
        shot.color = .systemRed; shot.width = 4
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let barH: CGFloat = 46
        let winW = min(isz.width + 4, vis.width * 0.72)
        let winH = min(isz.height + barH, vis.height * 0.92)
        let rect = NSRect(x: vis.midX - winW / 2, y: vis.midY - winH / 2, width: winW, height: winH)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "长图标注 — 画框 / 打码 / 文字，完成后保存或复制"
        let content = NSView(frame: NSRect(origin: .zero, size: rect.size))

        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: winW, height: winH - barH))
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder; scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = shot
        content.addSubview(scrollView)

        // 读 <savePath>.dupes（拼接器写的"可疑接缝位置"列表）
        if let txt = try? String(contentsOfFile: savePath + ".dupes", encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                var y = 0, off = 0
                for tok in line.split(separator: " ") {
                    let parts = tok.split(separator: "=")
                    if parts.count == 2, let v = Int(parts[1]) {
                        if parts[0] == "y" { y = v } else if parts[0] == "off" { off = v }
                    }
                }
                if off > 0 { dupes.append((y, off)) }
            }
            shot.dupes = dupes.map { ($0.y, $0.off) }       // ShotView 画橙色横线在这些 y 位置
            shot.needsDisplay = true
        }

        var items: [NSView] = [
            tbtn("rectangle", "▭", #selector(pickTool(_:)), 1, isTool: true),
            tbtn("arrow.up.right", "↗", #selector(pickTool(_:)), 2, isTool: true),
            tbtn("pencil.tip", "✏︎", #selector(pickTool(_:)), 3, isTool: true),
            tbtn("highlighter", "▰", #selector(pickTool(_:)), 4, isTool: true),
            tbtn("square.grid.3x3.fill", "▦", #selector(pickTool(_:)), 5, isTool: true),
            tbtn("textformat", "T", #selector(pickTool(_:)), 6, isTool: true),
            tbtn("eraser", "⌫", #selector(pickTool(_:)), 7, isTool: true),
        ]
        for (i, c) in colorList.enumerated() {
            let b = NSButton(); b.title = ""; b.bezelStyle = .circular; b.isBordered = true; b.bezelColor = c
            b.target = self; b.action = #selector(pickColor(_:)); b.tag = i; b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true; b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            items.append(b)
        }
        for (i, n) in ["细", "中", "粗"].enumerated() { let b = NSButton(title: n, target: self, action: #selector(pickWidth(_:))); b.bezelStyle = .rounded; b.tag = i; b.translatesAutoresizingMaskIntoConstraints = false; items.append(b) }
        items.append(tbtn("arrow.uturn.backward", "↶", #selector(doUndo)))
        items.append(tbtn("arrow.uturn.forward", "↷", #selector(doRedo)))
        // ===== 可疑接缝相关按钮（仅在 .dupes 非空时显示） =====
        if !dupes.isEmpty {
            let sep = NSBox(); sep.boxType = .separator; sep.translatesAutoresizingMaskIntoConstraints = false
            sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
            items.append(sep)
            let chip = NSTextField(labelWithString: "⚠️ \(dupes.count) 处可能叠")
            chip.font = .boldSystemFont(ofSize: 12); chip.textColor = .systemOrange
            items.append(chip); dupeChipLabel = chip
            let trimAll = NSButton(title: "一键裁全部", target: self, action: #selector(doTrimAll))
            trimAll.bezelStyle = .rounded; trimAll.contentTintColor = .systemOrange
            let clearMark = NSButton(title: "清除标记", target: self, action: #selector(doClearMarks))
            clearMark.bezelStyle = .rounded
            items.append(trimAll); items.append(clearMark)
            dupeButtons = [trimAll, clearMark]
        }
        let saveB = NSButton(title: "✓ 保存", target: self, action: #selector(doSave)); saveB.bezelStyle = .rounded; saveB.keyEquivalent = "\r"
        let copyB = NSButton(title: "复制", target: self, action: #selector(doCopy)); copyB.bezelStyle = .rounded
        items.append(saveB); items.append(copyB)
        let st = NSStackView(views: items); st.orientation = .horizontal; st.spacing = 6; st.alignment = .centerY
        st.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSView(frame: NSRect(x: 0, y: winH - barH, width: winW, height: barH))
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        bar.autoresizingMask = [.width, .minYMargin]
        bar.addSubview(st)
        NSLayoutConstraint.activate([st.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
                                     st.centerYAnchor.constraint(equalTo: bar.centerYAnchor)])
        content.addSubview(bar)
        contentView = content
        makeFirstResponder(shot)
        DispatchQueue.main.async { [weak self] in self?.shot.scroll(NSPoint(x: 0, y: 0)) }   // 滚到顶部
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func pickTool(_ b: NSButton) {
        shot.tool = tagTool[b.tag] ?? .none
        for (tag, btn) in toolBtns { btn.contentTintColor = (tag == b.tag) ? .systemBlue : .darkGray }
    }
    @objc func pickColor(_ b: NSButton) { if b.tag < colorList.count { shot.color = colorList[b.tag] } }
    @objc func pickWidth(_ b: NSButton) { shot.width = [2.0, 4.0, 8.0][b.tag] }
    @objc func doUndo() { shot.undo() }
    @objc func doRedo() { shot.redo() }
    @objc func doSave() {
        if let im = shot.result(), let t = im.tiffRepresentation, let bmp = NSBitmapImageRep(data: t),
           let png = bmp.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: savePath)) }
        // 顺手把 .dupes 临时文件清理掉
        try? FileManager.default.removeItem(atPath: savePath + ".dupes")
        NSApp.terminate(nil)
    }
    @objc func doCopy() {
        if let im = shot.result() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([im]) }
        try? FileManager.default.removeItem(atPath: savePath + ".dupes")
        NSApp.terminate(nil)
    }

    // 把所有标记位置的重复段从图里裁掉，重建 ShotView
    @objc func doTrimAll() {
        if dupes.isEmpty { return }
        guard let cg = origImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let isz = origImage.size
        let imgW = cg.width, imgH = cg.height
        let scaleY = Double(imgH) / Double(isz.height)         // points → pixels
        // 计算要裁的像素行范围(按 origImage 当前 image-points 坐标转 cg-pixel 坐标)
        var dropRanges: [(Int, Int)] = []
        for d in dupes {
            let yPx = Int(Double(d.y) * scaleY)
            let offPx = Int(Double(d.off) * scaleY)
            dropRanges.append((yPx, min(imgH, yPx + offPx)))
        }
        // 用 NSBitmapImageRep 重新拼图，跳过这些 ranges
        let totalCut = dropRanges.reduce(0) { $0 + ($1.1 - $1.0) }
        let newH = imgH - totalCut
        let bpr = imgW * 4
        guard let newRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: imgW, pixelsHigh: newH, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let dst = newRep.bitmapData else { return }
        // 把原图按行拷贝到新 rep，跳过 dropRanges
        var srcBuf = [UInt8](repeating: 0, count: bpr * imgH)
        srcBuf.withUnsafeMutableBufferPointer { sbp in
            let srcPtr = sbp.baseAddress!
            let ctx = CGContext(data: srcPtr, width: imgW, height: imgH, bitsPerComponent: 8, bytesPerRow: bpr,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))   // CG 缓冲：row0=底
            let newBpr = newRep.bytesPerRow
            var dstTopY = 0
            for srcTopY in 0..<imgH {
                var skip = false
                for r in dropRanges where srcTopY >= r.0 && srcTopY < r.1 { skip = true; break }
                if skip { continue }
                let srcBufRow = imgH - 1 - srcTopY               // top-y 转 CG buf 行(row0=底)
                let dstBufRow = newH - 1 - dstTopY
                memcpy(dst.advanced(by: dstBufRow * newBpr), srcPtr.advanced(by: srcBufRow * bpr), min(bpr, newBpr))
                dstTopY += 1
            }
        }
        guard let newCG = newRep.cgImage else { return }
        let newImg = NSImage(cgImage: newCG, size: NSSize(width: Double(imgW) / scaleY, height: Double(newH) / scaleY))
        // 用新图重建 ShotView（用户的现有标注会丢失——但截图刚出来一般没标注；如果有，已记于 anns 也会丢，对此提示）
        let newShot = ShotView(frame: NSRect(origin: .zero, size: newImg.size), image: newImg)
        newShot.editor = true; newShot.hasSel = true; newShot.sel = NSRect(origin: .zero, size: newImg.size)
        newShot.color = shot.color; newShot.width = shot.width; newShot.tool = shot.tool
        newShot.anns = shot.anns                              // 保留已有标注(虽然 y 坐标可能错位，但保险起见)
        scrollView.documentView = newShot
        shot = newShot
        // 清掉 dupes 标记
        dupes = []
        for b in dupeButtons { b.isHidden = true }
        dupeChipLabel?.stringValue = "✓ 已裁掉所有标记"
        dupeChipLabel?.textColor = .systemGreen
    }

    @objc func doClearMarks() {
        dupes = []
        shot.dupes = []; shot.needsDisplay = true
        for b in dupeButtons { b.isHidden = true }
        dupeChipLabel?.stringValue = "标记已清除"
        dupeChipLabel?.textColor = .secondaryLabelColor
    }
}

// ===== 启动 =====
class AppDelegate: NSObject, NSApplicationDelegate {
    var win: ShotWindow?
    var editWin: EditorWindow?
    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--edit"), i+1 < args.count, FileManager.default.fileExists(atPath: args[i+1]),
           let img = NSImage(contentsOfFile: args[i+1]) {
            let w = EditorWindow(image: img, savePath: args[i+1])
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); self.editWin = w
            return
        }
        var path: String?
        if let i = args.firstIndex(of: "--shot"), i+1 < args.count { path = args[i+1] }
        guard let pth = path, FileManager.default.fileExists(atPath: pth), let img = NSImage(contentsOfFile: pth) else { NSApp.terminate(nil); return }
        let m = NSEvent.mouseLocation
        let scr = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
        let w = ShotWindow(screen: scr, image: img, selectOnly: args.contains("--selectonly"))
        // ⌥A 检测取景：Hammerspoon 已用精准检测选好区域，这里直接预选中那块，跳过框选、直达标注/提字/翻译/钉图
        if let i = args.firstIndex(of: "--presel"), i+1 < args.count {
            let p = args[i+1].split(separator: ",").compactMap { Double($0) }
            if p.count == 4 { w.shot.sel = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]); w.shot.hasSel = true; w.shot.onSelChanged?() }
        }
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); self.win = w
    }
}

// 复制图片到剪贴板模式（供收集架"复制"用）
if CommandLine.arguments.contains("--copy") {
    if let i = CommandLine.arguments.firstIndex(of: "--copy"), i + 1 < CommandLine.arguments.count,
       let img = NSImage(contentsOfFile: CommandLine.arguments[i + 1]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }
    exit(0)
}

// 移到废纸篓模式（不弹界面，供截图收集架删除用）
if CommandLine.arguments.contains("--trash") {
    let fm = FileManager.default
    for p in CommandLine.arguments.dropFirst() where p != "--trash" {
        if fm.fileExists(atPath: p) { try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil) }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
