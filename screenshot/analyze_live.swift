import Cocoa

// 判分“真实长截图”(纹理验证页 ttest.html)：左侧竖向渐变条必须单调、覆盖全程、无逆行无跳变。
// 不检查绝对高度(真实页渲染高度未知)。
//   analyze_live <stitched.png>

guard CommandLine.arguments.count >= 2 else { print("用法: analyze_live <png>"); exit(2) }
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("❌ 读不到图"); exit(2) }
let w = cg.width, h = cg.height, bpr = w * 4
var buf = [UInt8](repeating: 0, count: bpr * h)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))   // 缓冲 row0=底部

let x = max(10, Int(Double(w) * 0.02))      // 采样左侧渐变条
let skipTop = 220                            // 跳过顶部浏览器工具栏
var S: [Int] = []
var vy = skipTop
while vy < h {
    let y = h - 1 - vy                        // 视觉自上而下
    let o = y * bpr + x * 4
    let r = Int(buf[o]), g = Int(buf[o + 1]), b = Int(buf[o + 2])
    if abs(r - g) < 14 && abs(g - b) < 14 { S.append(r) }   // 只取灰阶(渐变条)，跳过别的
    vy += 3
}
guard S.count > 30 else { print("❌ 渐变条采样太少(\(S.count))，列可能没对准"); exit(1) }

let first = S.first!, last = S.last!, lo = S.min()!, hi = S.max()!
let dir = last >= first ? 1 : -1
var reversals = 0, maxRev = 0, bigJumps = 0
for i in 1..<S.count {
    let d = (S[i] - S[i - 1]) * dir
    if d < -6 { reversals += 1; maxRev = max(maxRev, -d) }
    if abs(S[i] - S[i - 1]) > 40 { bigJumps += 1 }
}
print("拼接输出: \(w) x \(h)px   渐变列 x=\(x)  采样点\(S.count)个")
print("渐变: 顶=\(first) 底=\(last) 方向=\(dir > 0 ? "↓增" : "↑减(翻转)")  覆盖=\(lo)..\(hi)(应≈15..235)")
print("亮度逆行=\(reversals)(最大\(maxRev))  大跳变=\(bigJumps)")
print(String(repeating: "=", count: 44))
var problems: [String] = []
if hi - lo < 190 { problems.append("覆盖只有 \(hi - lo) < 190 → 没拍全整页(漏了开头或结尾)") }
if reversals > 3 { problems.append("亮度逆行 \(reversals) 次 → 有重复/错位拼接") }
if bigJumps > 2 { problems.append("大跳变 \(bigJumps) 次 → 漏拼了内容") }
if problems.isEmpty {
    print("✅✅✅ 完美：渐变单调、覆盖全程、无重复、无遗漏")
    exit(0)
} else {
    print("❌ 发现问题："); for p in problems { print("  • " + p) }; exit(1)
}
