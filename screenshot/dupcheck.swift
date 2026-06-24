import Cocoa

// 自动数拼接图里的"叠"瑕疵：扫描每 50 行段，看下方 30-300 行内有没有几乎完全相同的段(=重复)
//   dupcheck <png>   → 打印瑕疵数

guard CommandLine.arguments.count >= 2 else { print("用法: dupcheck <png>"); exit(2) }
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path),
      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("err"); exit(1) }
let w = cg.width, h = cg.height, bpr = w * 4
var buf = [UInt8](repeating: 0, count: bpr * h)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1); ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// 行指纹：每行取 32 列亮度（够区分文字行）
let cols = (0..<32).map { min(w-1, Int((Double($0)+0.5)/32.0 * Double(w))) }
var sig = [[Double]](repeating: [Double](repeating: 0, count: 32), count: h)
for y in 0..<h { let row = y*bpr; for (ci,x) in cols.enumerated() {
    let o = row + x*4; sig[y][ci] = 0.299*Double(buf[o]) + 0.587*Double(buf[o+1]) + 0.114*Double(buf[o+2]) } }

func rdist(_ a: [Double], _ b: [Double]) -> Double { var d=0.0; for k in 0..<32 { d += abs(a[k]-b[k]) }; return d }

// 80行段指纹比较：从每行 y 出发，看下方 30..200 行内是否存在一段【几乎完全相同】(说明真"叠"了)
let segH = 80
var dupes = 0; var positions: [Int] = []
var y = 0
while y < h - segH - 200 {
    var variance = 0.0
    for r in 0..<segH { variance += rdist(sig[y+r], sig[y]) }
    if variance < 500 { y += segH; continue }

    var bestSim = Double.greatestFiniteMagnitude; var bestOff = 0
    var off = 30
    while off <= 200 {
        var cost = 0.0
        for r in 0..<segH where y+segH+off+r < h { cost += rdist(sig[y+r], sig[y+off+r]) }
        if cost < bestSim { bestSim = cost; bestOff = off }
        off += 2
    }
    // 严格阈值：80 行 * 32 列 * 平均差异 < 0.4 → 几乎像素级一样
    if bestSim < 4000 { dupes += 1; positions.append(y); y += segH + bestOff } else { y += segH }
}
print("瑕疵段数=\(dupes)  位置=\(positions.prefix(10).map(String.init).joined(separator: ","))\(positions.count > 10 ? "..." : "")")
