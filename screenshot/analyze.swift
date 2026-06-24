import Cocoa

// 判分：拼好的图右侧那条干净亮度渐变(顶15→底235)必须保持单调、覆盖全程、总高≈13600。
//   reversal(亮度逆行) = 重复/错位拼接;  大跳变 = 漏拼;  总高不符 = 压缩/拉伸。
//   analyze <stitched.png>

let TRUE_H = 13600
guard CommandLine.arguments.count >= 2 else { print("用法: analyze <png>"); exit(2) }
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("❌ 读不到图"); exit(2) }
let w = cg.width, h = cg.height, bpr = w * 4
var buf = [UInt8](repeating: 0, count: bpr * h)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))   // 缓冲 row0=底部

let x = Int(Double(w) * 0.925)                              // 采样干净渐变列
var S: [Int] = []
var vy = 0
while vy < h {
    let y = h - 1 - vy                                      // 视觉自上而下
    S.append(Int(buf[y * bpr + x * 4]))
    vy += 3
}
guard S.count > 10 else { print("❌ 采样太少"); exit(1) }

let first = S.first!, last = S.last!, lo = S.min()!, hi = S.max()!
let dir = last >= first ? 1 : -1                            // 方向(拼接器可能上下翻转，判分对方向不敏感)
// 逆行：与总趋势相反且幅度>4 的相邻跳变 = 重复/错位
var reversals = 0, maxRev = 0
// 大跳变：相邻样本跳变>30(渐变全程220/约4500样本，正常每样本<1) = 漏拼一段
var bigJumps = 0
for i in 1..<S.count {
    let d = (S[i] - S[i - 1]) * dir
    if d < -4 { reversals += 1; maxRev = max(maxRev, -d) }
    if abs(S[i] - S[i - 1]) > 30 { bigJumps += 1 }
}
let range = hi - lo
let heightErr = Double(abs(h - TRUE_H)) / Double(TRUE_H) * 100

print("拼接输出: \(w) x \(h)px   (真实应为 \(TRUE_H)px, 误差 \(String(format: "%.1f", heightErr))%)")
print("渐变列: 顶端亮度=\(first) 底端=\(last) 方向=\(dir > 0 ? "↓增(正常)" : "↑减(上下翻转)")  覆盖范围=\(lo)..\(hi)(应≈15..235)")
print("亮度逆行次数=\(reversals)(最大逆行\(maxRev))   大跳变次数=\(bigJumps)")
print(String(repeating: "=", count: 44))

var problems: [String] = []
if heightErr > 3 { problems.append("总高误差 \(String(format: "%.1f", heightErr))% > 3% → 内容被压缩/拉伸(漏拼或重复)") }
if range < 185 { problems.append("亮度覆盖只有 \(range) < 185 → 没拍全整页") }
if reversals > 2 { problems.append("亮度逆行 \(reversals) 次 → 有重复/错位拼接") }
if bigJumps > 1 { problems.append("大跳变 \(bigJumps) 次 → 漏拼了内容") }

if problems.isEmpty {
    print("✅✅✅ 完美：单调、无重复、无遗漏、总高吻合(高度误差\(String(format: "%.1f", heightErr))%)")
    exit(0)
} else {
    print("❌ 发现问题：")
    for p in problems { print("  • " + p) }
    exit(1)
}
