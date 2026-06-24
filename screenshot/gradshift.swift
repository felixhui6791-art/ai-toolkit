import Cocoa

// 用左侧单调渐变条测“两帧之间真实滚动了多少像素”(渐变唯一→绝不会错锁，是地面真相)。
//   gradshift <frameA> <frameB>
func col(_ p: String, _ x: Int) -> [Double]? {
    guard let img = NSImage(contentsOfFile: p),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var v = [Double](repeating: 0, count: h)
    for vy in 0..<h { v[vy] = Double(buf[(h - 1 - vy) * bpr + x * 4]) }  // 视觉自上而下
    return v
}
let a = CommandLine.arguments
guard a.count >= 3, let v0 = col(a[1], 69), let v1 = col(a[2], 69) else { print("err"); exit(1) }
let h = v0.count
let top = 240, bot = min(h - 10, top + 1400)   // 取渐变清晰的一段
// 斜率 b：渐变每像素行的亮度增量
var b = 0.0, cnt = 0
for r in stride(from: top, to: bot - 50, by: 10) {
    // 只在灰阶(渐变)区取
    if v0[r] > 16 && v0[r] < 236 && v0[r + 50] > 16 && v0[r + 50] < 236 {
        b += (v0[r + 50] - v0[r]) / 50.0; cnt += 1
    }
}
guard cnt > 5, b > 0.001 else { print("渐变不清晰"); exit(1) }
b /= Double(cnt)
// 平均亮度差 d = b * 滚动量
var d = 0.0, c2 = 0
for r in stride(from: top, to: bot, by: 5) where v0[r] > 18 && v0[r] < 234 && v1[r] > 18 && v1[r] < 234 {
    d += (v1[r] - v0[r]); c2 += 1
}
d /= Double(max(c2, 1))
print(String(format: "真实滚动 = %.0f px  (斜率b=%.4f/px, 平均亮度差d=%.1f)", d / b, b, d))
