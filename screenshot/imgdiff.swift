import Cocoa

// 比较两张同尺寸截图，输出“有变化的像素占千分之几”(整数)。
// 用于长截图：判断画面是否静止 / 是否到底——对小面积动画(桌宠/光标)不敏感。
//   imgdiff <a> <b>   → 打印 0..1000

func load(_ p: String) -> (px: [UInt8], w: Int, h: Int)? {
    guard let img = NSImage(contentsOfFile: p),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
}

let args = CommandLine.arguments
guard args.count >= 3, let a = load(args[1]), let b = load(args[2]), a.w == b.w, a.h == b.h else {
    print(1000); exit(0)            // 读不到/尺寸不符 → 当作“完全不同”
}
let n = a.w * a.h
var diff = 0
var i = 0
let bpr = a.w * 4
// 每隔几个像素抽样即可，够准又快
var idx = 0
while idx < n {
    let o = idx * 4
    let dr = abs(Int(a.px[o]) - Int(b.px[o]))
    let dg = abs(Int(a.px[o + 1]) - Int(b.px[o + 1]))
    let db = abs(Int(a.px[o + 2]) - Int(b.px[o + 2]))
    if dr + dg + db > 36 { diff += 1 }    // 该像素算“变了”
    idx += 2
    i += 1
}
_ = bpr
print(Int(Double(diff) * 1000.0 / Double(max(i, 1))))
