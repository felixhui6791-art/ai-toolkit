import Cocoa

// 造一张“贴近真实网页”的长测试图：左85%是每行独一无二的随机纹理(供匹配，无歧义)，
// 右15%是一条干净的亮度渐变(顶15→底235，供判分)。再按给定滚动量切成帧。
//   gentest <outdir> <viewportH> <step> <jitter:0|1>

let args = CommandLine.arguments
guard args.count >= 5 else { print("用法: gentest <outdir> <H> <step> <jitter0/1>"); exit(2) }
let outdir = args[1]
let H = Int(args[2])!, step = Int(args[3])!, jitter = args[4] == "1"

let W = 1000, totalH = 13600
let rampX = 850                                  // x>=850 为干净渐变区
let bpr = W * 4
var buf = [UInt8](repeating: 255, count: bpr * totalH)
for y in 0..<totalH {
    let ramp = 15 + Int(Double(y) * 220.0 / Double(totalH))   // 干净渐变 15..235
    for x in 0..<W {
        let o = y * bpr + x * 4
        let v: Int
        if x >= rampX {
            v = ramp
        } else {
            let hsh = UInt32(truncatingIfNeeded: (x &* 73856093) ^ (y &* 19349663) ^ (x &* y &* 83492791))
            v = 20 + Int(hsh % 200)                            // 每像素随机纹理 20..219
        }
        buf[o] = UInt8(v); buf[o + 1] = UInt8(v); buf[o + 2] = UInt8(v); buf[o + 3] = 255
    }
}
let cs = CGColorSpaceCreateDeviceRGB()

try? FileManager.default.removeItem(atPath: outdir)
try? FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)

let pat = [1.0, 1.18, 0.86, 1.08, 0.9]            // 抖动模式(±18%)，模拟真实滚动不完全均匀
var offs: [Int] = []
var off = 0, k = 0
while off + H <= totalH {
    offs.append(off)
    let s = jitter ? Int(Double(step) * pat[k % pat.count]) : step
    off += s; k += 1
}
offs.append(totalH - H)                            // 末帧(到底)
offs.append(totalH - H)                            // 再来一张相同(模拟到底 cmp 停)

// 直接从缓冲区切：帧的可视第0行 = 页面第 off 行（与真实截图朝向一致：往下滚=off增大）
let fbpr = W * 4
for (i, o) in offs.enumerated() {
    var fbuf = [UInt8](repeating: 255, count: fbpr * H)
    for r in 0..<H {
        let src = (o + (H - 1 - r)) * bpr      // 行序翻转，抵消 CG 左下原点 → 保存出来可视顶=页面第 off 行
        let dst = r * fbpr
        fbuf.replaceSubrange(dst..<dst + fbpr, with: buf[src..<src + fbpr])
    }
    let fctx = CGContext(data: &fbuf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: fbpr,
                         space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = fctx.makeImage()!
    let p = "\(outdir)/frame_\(String(format: "%03d", i)).tiff"
    if let t = NSImage(cgImage: c, size: NSSize(width: W, height: H)).tiffRepresentation {
        try? t.write(to: URL(fileURLWithPath: p))
    }
}
print("生成 \(offs.count) 帧 → \(outdir)   视口H=\(H) 步长=\(step) 抖动=\(jitter)")
print("真实滚动量: \(zip(offs.dropFirst(), offs).map { $0 - $1 })")
print("长图真实高度 = \(totalH)px")
print("朝向自检: 页面顶ramp=\(15), 底ramp=\(15 + Int(Double(totalH-1)*220.0/Double(totalH)))")
