import Cocoa

// ===== 长截图拼接引擎（纹理特征匹配，像素级渲染）=====
//   stitch <帧目录> <输出png>
//   stitch --selftest

let N_COLS = 256   // 每行取这么多列做指纹；够密才能抓到文字笔画、区分相似的文字行，避免“按行错锁”
let MIN_OVERLAP = 200      // 相邻帧至少重叠这么多像素行
var gExpectedScroll = 0    // 命令滚动量(像素)；把匹配范围限制在期望值附近，避免在重复图案上锁错

struct Frame { let cg: CGImage; let sig: [[Double]]; let w: Int; let h: Int }

// 读图：得到 CGImage + 每行 N 个采样点的【亮度+梯度】混合指纹
// 亮度：抓行的明暗(随机纹理类有效)；梯度：抓字的边缘形状(文字行更易区分)
// 两者拼起来作为 2*N_COLS 长的向量，文字和图都能稳定匹配
func loadFrame(_ path: String) -> Frame? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height, bpr = w * 4
    var buf = [UInt8](repeating: 0, count: bpr * h)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // 顶部为原点
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    // 先把整张图按"亮度灰度"压成单通道(用临时数组)
    var L = [Double](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = y * bpr
        for x in 0..<w {
            let o = row + x * 4
            L[y * w + x] = 0.299 * Double(buf[o]) + 0.587 * Double(buf[o + 1]) + 0.114 * Double(buf[o + 2])
        }
    }
    let cols = (0..<N_COLS).map { min(w - 2, max(2, Int((Double($0) + 0.5) / Double(N_COLS) * Double(w)))) }
    let lumaOnly = ProcessInfo.processInfo.environment["STITCH_LUMA"] != nil   // 可对比：纯亮度 vs 混合
    let dim = lumaOnly ? N_COLS : N_COLS * 2
    var sig = [[Double]](repeating: [Double](repeating: 0, count: dim), count: h)
    for y in 0..<h {
        for (ci, x) in cols.enumerated() {
            sig[y][ci] = L[y * w + x]                                          // 亮度部分
            if !lumaOnly && y > 0 && y < h - 1 {
                let dx = abs(L[y * w + x + 1] - L[y * w + x - 1])
                let dy = abs(L[(y + 1) * w + x] - L[(y - 1) * w + x])
                sig[y][N_COLS + ci] = (dx + dy) * 2.5                          // 梯度部分(放大权重)
            }
        }
    }
    return Frame(cg: cg, sig: sig, w: w, h: h)
}

func rowDist(_ a: [Double], _ b: [Double]) -> Double {
    var d = 0.0; let n = a.count; for k in 0..<n { d += abs(a[k] - b[k]) }; return d
}

// 固定不动的行(头/尾/侧栏)标记，不参与匹配
// 阈值按指纹长度比例：原 N_COLS=256 阈值 20 → 现 2*N_COLS=512+梯度2.5x权重 → 阈值 60
func staticRows(_ prev: [[Double]], _ cur: [[Double]], _ h: Int) -> [Bool] {
    var stat = [Bool](repeating: false, count: h)
    let thr = (prev.first?.count ?? N_COLS) >= N_COLS * 2 ? 60.0 : 20.0   // 自适应:混合指纹用60,纯亮度用20
    for r in 0..<h { stat[r] = rowDist(cur[r], prev[r]) < thr }
    return stat
}

// 在偏移 s 处的匹配代价(越小越吻合)。只比较固定的 K 行(cur 顶部 K 行 ↔ prev 第 s..s+K 行)，
// 这样不同偏移用“同等行数”比较，消除“偏移越大重叠越少→平均代价碰巧偏低”的系统性偏向。
func scrollCost(_ prev: [[Double]], _ cur: [[Double]], _ stat: [Bool], _ h: Int, _ s: Int, _ K: Int) -> Double {
    if s < 1 || s + K > h { return Double.greatestFiniteMagnitude }
    var cost = 0.0, cnt = 0, r = 0
    while r < K {
        if !stat[r] && !stat[r + s] { cost += rowDist(cur[r], prev[r + s]); cnt += 1 }
        r += 3
    }
    return cnt > max(20, K / 15) ? cost / Double(cnt) : Double.greatestFiniteMagnitude
}

// 在 [minS,maxS] 内找最吻合的滚动量，返回(滚动量, 代价)。K=最大偏移处的重叠行数(全程统一)
func findScroll(_ prev: [[Double]], _ cur: [[Double]], _ stat: [Bool], _ h: Int, _ minS: Int, _ maxS: Int) -> (Int, Double) {
    let lim = min(maxS, h - MIN_OVERLAP)
    let K = max(MIN_OVERLAP, h - lim)
    var bestS = -1, bestCost = Double.greatestFiniteMagnitude
    var s = max(4, minS)
    while s <= lim {
        let c = scrollCost(prev, cur, stat, h, s, K)
        if c < bestCost { bestCost = c; bestS = s }
        s += 1
    }
    return (bestS > 0 ? bestS : 0, bestCost)
}

// 找“真正在滚动的正文栏”的左右边界：对比相邻两帧，固定不动的贴边浮窗/侧栏(整列几乎不变)被排除
func scrollingBand(_ a: CGImage, _ b: CGImage) -> (Int, Int) {
    let w = a.width, h = a.height, bpr = w * 4
    func px(_ c: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h)); return buf
    }
    let pa = px(a), pb = px(b)
    var act = [Double](repeating: 0, count: w)
    for x in 0..<w {
        var diff = 0, n = 0, y = 80
        while y < h - 80 {
            let o = y * bpr + x * 4
            let d = abs(Int(pa[o]) - Int(pb[o])) + abs(Int(pa[o + 1]) - Int(pb[o + 1])) + abs(Int(pa[o + 2]) - Int(pb[o + 2]))
            if d > 40 { diff += 1 }
            n += 1; y += 4
        }
        act[x] = Double(diff) / Double(max(n, 1))
    }
    let thr = 0.08
    var L = 0, R = w - 1
    while L < w && act[L] < thr { L += 1 }
    while R > L && act[R] < thr { R -= 1 }
    if R - L < w / 4 { return (0, w - 1) }      // 检测异常/整页都在滚 → 不裁
    return (max(0, L - 16), min(w - 1, R + 16))
}

func stitchToPNG(_ paths: [String], _ outPath: String) -> Int {
    var frames: [Frame] = []
    for p in paths { if let f = loadFrame(p) { frames.append(f) } }
    guard let first = frames.first else { return 0 }
    let w = first.w, h = first.h
    // 滚动是匀速的(实测相邻帧差异恒定)。全局求解：找一个统一滚动量 S*，使所有帧对的总代价最小。
    // 50帧一起“投票”，单帧的歧义/噪声被抵消 → 比单帧中位数稳得多。
    let INF = Double.greatestFiniteMagnitude
    var stats: [[Bool]] = []
    for i in 1..<frames.count { stats.append(staticRows(frames[i - 1].sig, frames[i].sig, h)) }

    func totalCost(_ S: Int, _ K: Int) -> (Double, Int) {     // 所有帧对在偏移 S 处的平均代价
        var sum = 0.0, valid = 0
        for i in 1..<frames.count {
            let c = scrollCost(frames[i - 1].sig, frames[i].sig, stats[i - 1], h, S, K)
            if c < INF { sum += c; valid += 1 }
        }
        return (valid > 0 ? sum / Double(valid) : INF, valid)
    }
    // 粗搜统一滚动量(步长8)
    var bestS = h / 4, bestC = INF
    var S = 100
    while S <= h - MIN_OVERLAP {
        let (c, v) = totalCost(S, MIN_OVERLAP)
        if v > frames.count / 3 && c < bestC { bestC = c; bestS = S }
        S += 8
    }
    // 细化 ±40 步长1 → 全局值精确到像素(累积50帧时1px误差=50px≈一行，所以这步至关重要)
    let rlo = max(8, bestS - 40), rhi = min(h - MIN_OVERLAP, bestS + 40)
    let Kr = max(MIN_OVERLAP, h - rhi)
    var rs = rlo, scroll = bestS, rc = INF
    while rs <= rhi { let (c, _) = totalCost(rs, Kr); if c < rc { rc = c; scroll = rs }; rs += 1 }
    // 全局给出大概滚动量，再在它附近的【窄窗 ±130】内逐帧精确微调：
    // 窗口比一行还窄(排除整行错锁的大跳)，256列指纹在窄窗内能精准定位每帧真实滚动量 → 消除接缝重影。
    let margin = 70
    let loS = max(8, scroll - margin), hiS = min(h - MIN_OVERLAP, scroll + margin)
    let K2 = max(MIN_OVERLAP, h - hiS)
    FileHandle.standardError.write("[debug] 全局统一滚动量=\(scroll) 微调窗=[\(loS),\(hiS)]\n".data(using: .utf8)!)

    var offsets = [0]
    for i in 1..<frames.count {
        let st = stats[i - 1]
        // 重复帧(cur≈prev，到底)→0；否则取窄窗内的精确值(不强制 snap，因为真实滚动会有±10%波动)
        let cAtScroll = scrollCost(frames[i - 1].sig, frames[i].sig, st, h, scroll, K2)
        let (bs, _) = findScroll(frames[i - 1].sig, frames[i].sig, st, h, loS, hiS)
        let s = (cAtScroll == INF) ? 0 : (bs > 0 ? bs : scroll)
        offsets.append(offsets[i - 1] + s)
    }
    // ===== 双层平滑：5帧中位拉回孤立错锁 + 累积偏差校正(防止系统性漂移导致接缝叠半行) =====
    var dl = [Int](); for i in 1..<offsets.count { dl.append(offsets[i] - offsets[i - 1]) }
    var dl2 = dl
    let medWin = Int(ProcessInfo.processInfo.environment["MED_WIN"] ?? "") ?? 2
    let medThr = Int(ProcessInfo.processInfo.environment["MED_THR"] ?? "") ?? 25
    for i in 0..<dl.count where dl[i] != 0 {
        var win = [Int]()
        for k in max(0, i - medWin)...min(dl.count - 1, i + medWin) where dl[k] != 0 { win.append(dl[k]) }
        win.sort(); let med = win[win.count / 2]
        if abs(dl[i] - med) > medThr { dl2[i] = med }   // 离群→拉回邻域中位数
    }
    // 第2层：累积偏差校正(可用 NOBIAS=1 关闭做对比)——假设滚动匀速，纯文字页有用，图文页可能制造折叠
    if ProcessInfo.processInfo.environment["NOBIAS"] == nil {
        let nzAvg: Double = { let nz = dl2.filter { $0 > 0 }; return nz.isEmpty ? Double(scroll) : Double(nz.reduce(0, +)) / Double(nz.count) }()
        var bias = 0.0
        for i in 0..<dl2.count where dl2[i] != 0 {
            bias += Double(dl2[i]) - nzAvg
            if bias > 15 { dl2[i] -= Int(bias); bias = 0 }
            else if bias < -15 { dl2[i] -= Int(bias); bias = 0 }
        }
    }
    // ===== 招A：接缝处精对齐 =====
    var changedFrames = 0; var totalChange = 0
    // 渲染时新增的是 frames[i] 顶部 dl[i] 行；这些行在 frame[i] 内对应 source-rows (h - dl[i] .. h)
    // 它们应该跟 frame[i-1] 底部 dl[i] 行【外的下一段】内容相同——但我们这里反过来：
    // 用 frame[i-1] 底部 80 行 (h-80..h) 作模板，在 frame[i] 里精确找它对应到哪一段
    // 真实 delta = h - (该段在 cur 的起始行) - 80
    let tplH = 80
    for i in 0..<dl2.count where dl2[i] > 0 {
        let prev = frames[i].sig, cur = frames[i + 1].sig
        if h < tplH + 4 { continue }
        // 模板 = prev 底部 tplH 行（视觉上相邻 i+1 帧顶部新增部分的"上一行"）
        var bestDelta = dl2[i], bestCost = Double.greatestFiniteMagnitude
        // 在 ±18 范围精搜
        for d in max(1, dl2[i] - 18)...min(h - tplH - 4, dl2[i] + 18) {
            // 真实 delta = d 时，prev 底部 tplH 行应等于 cur 第 (h - tplH - d .. h - d) 行
            let curStart = h - tplH - d
            if curStart < 0 || curStart + tplH > h { continue }
            var cost = 0.0, cnt = 0
            for r in 0..<tplH {
                let pr = prev[h - tplH + r], cr = cur[curStart + r]
                let rd = rowDist(pr, cr)
                if rd < 5000 { cost += rd; cnt += 1 }     // 过滤异常行(纯静态/极端)
            }
            if cnt > tplH / 2 {
                let avg = cost / Double(cnt)
                if avg < bestCost { bestCost = avg; bestDelta = d }
            }
        }
        if bestDelta != dl2[i] { changedFrames += 1; totalChange += abs(bestDelta - dl2[i]) }
        dl2[i] = bestDelta
    }
    FileHandle.standardError.write("[debug] 招A接缝精对齐: \(changedFrames)/\(dl2.count) 帧被修改,总变化=\(totalChange)px\n".data(using: .utf8)!)
    offsets = [0]; for d in dl2 { offsets.append(offsets.last! + d) }
    let totalH = offsets.last! + h
    var deltas = [Int](); for i in 1..<offsets.count { deltas.append(offsets[i] - offsets[i - 1]) }
    FileHandle.standardError.write("[debug] 每帧滚动px: \(deltas)\n[debug] totalH=\(totalH) h=\(h)\n".data(using: .utf8)!)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: totalH, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    let cg = ctx.cgContext   // 底部为原点, 1 单位=1 像素
    cg.draw(frames[0].cg, in: CGRect(x: 0, y: totalH - h, width: w, height: h))   // 第一帧整张(顶部)
    for i in 1..<frames.count {
        let newH = offsets[i] - offsets[i - 1]      // 本帧新增高度
        if newH <= 0 { continue }
        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: totalH - (offsets[i] + h), width: w, height: newH))  // 只画新增的底部
        cg.draw(frames[i].cg, in: CGRect(x: 0, y: totalH - (offsets[i] + h), width: w, height: h))
        cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    // 检测重复段,写到 .dupes 给用户在编辑器里一键裁(自动裁会移位制造新错位,实测反而更糟,故不自动裁)
    let dupes = detectDuplicates(rep, h: h, w: w)
    let payload = dupes.map { "y=\($0.y) off=\($0.off) sim=\($0.sim)" }.joined(separator: "\n")
    try? payload.write(toFile: outPath + ".dupes", atomically: true, encoding: .utf8)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 0 }
    try? png.write(to: URL(fileURLWithPath: outPath))
    return rep.pixelsHigh
}

// 扫描图，返回所有"几乎完全重复"的段 (y起始行, off到重复处的偏移, sim相似度)
func detectDuplicates(_ rep: NSBitmapImageRep, h: Int, w: Int) -> [(y: Int, off: Int, sim: Int)] {
    let totalH = rep.pixelsHigh
    let bpr = rep.bytesPerRow
    guard let data = rep.bitmapData else { return [] }
    let N = 32
    let cols = (0..<N).map { min(w - 1, Int((Double($0) + 0.5) / Double(N) * Double(w))) }
    var sig = [[Double]](repeating: [Double](repeating: 0, count: N), count: totalH)
    let bps = rep.samplesPerPixel
    for y in 0..<totalH {
        for (ci, x) in cols.enumerated() {
            let o = y * bpr + x * bps
            sig[y][ci] = 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
        }
    }
    func rd(_ a: [Double], _ b: [Double]) -> Double { var d = 0.0; for k in 0..<N { d += abs(a[k] - b[k]) }; return d }
    let segH = 80
    var out: [(Int, Int, Int)] = []
    var y = 0
    while y < totalH - segH - 200 {
        var variance = 0.0
        for r in 0..<segH where r % 4 == 0 { variance += rd(sig[y + r], sig[y]) }
        if variance < 500 { y += segH; continue }
        var bestSim = Double.greatestFiniteMagnitude, bestOff = 0
        var off = 40
        while off <= 200 {
            var cost = 0.0
            for r in 0..<segH where y + segH + off + r < totalH { cost += rd(sig[y + r], sig[y + off + r]) }
            if cost < bestSim { bestSim = cost; bestOff = off }
            off += 2
        }
        if bestSim < 4000 && bestOff > 0 {
            out.append((y, bestOff, Int(bestSim)))
            y += segH + bestOff
        } else { y += segH }
    }
    return out
}

// 从图里裁掉指定的若干 [start,end) 像素行段，返回新图
func cutSegments(_ rep: NSBitmapImageRep, ranges: [(Int, Int)], w: Int) -> NSBitmapImageRep {
    let totalH = rep.pixelsHigh, bpr = rep.bytesPerRow
    guard let src = rep.bitmapData, !ranges.isEmpty else { return rep }
    let sorted = ranges.sorted { $0.0 < $1.0 }
    let cut = sorted.reduce(0) { $0 + ($1.1 - $1.0) }
    let newH = totalH - cut
    guard newH > 0, let newRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: newH, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let dst = newRep.bitmapData else { return rep }
    let newBpr = newRep.bytesPerRow
    var srcY = 0, dstY = 0, ri = 0
    while srcY < totalH {
        if ri < sorted.count && srcY >= sorted[ri].0 && srcY < sorted[ri].1 { srcY = sorted[ri].1; ri += 1; continue }
        memcpy(dst.advanced(by: dstY * newBpr), src.advanced(by: srcY * bpr), min(bpr, newBpr))
        srcY += 1; dstY += 1
    }
    return newRep
}

// (旧版自动裁掉重复段，保留代码不调用，将来想自动模式时再启用)
func removeDuplicates(_ rep: NSBitmapImageRep, around offsets: [Int], h: Int, w: Int) -> NSBitmapImageRep {
    let totalH = rep.pixelsHigh
    let bpr = rep.bytesPerRow
    guard let data = rep.bitmapData else { return rep }
    // 构造每行 32 列亮度指纹(用于快速比较)
    let N = 32
    let cols = (0..<N).map { min(w - 1, Int((Double($0) + 0.5) / Double(N) * Double(w))) }
    var sig = [[Double]](repeating: [Double](repeating: 0, count: N), count: totalH)
    let bps = rep.samplesPerPixel
    for y in 0..<totalH {
        for (ci, x) in cols.enumerated() {
            let o = y * bpr + x * bps
            sig[y][ci] = 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
        }
    }
    func rd(_ a: [Double], _ b: [Double]) -> Double { var d = 0.0; for k in 0..<N { d += abs(a[k] - b[k]) }; return d }
    // 围绕每个接缝(offsets[i+1]+h ≈ canvas 位置 totalH - offsets[i+1] - h ...实际还是排成 canvas top-origin)，
    // 简化：扫描整张图，对每个候选 y 检测下方 20..180 行是否有 80 行段跟它"几乎相同"
    let segH = 80
    var skipRanges: [(Int, Int)] = []     // 要裁掉的 [y_start, y_end)
    var y = 0
    while y < totalH - segH - 200 {
        // 跳过已经划入裁剪范围的 y
        if skipRanges.last.map({ y < $0.1 }) ?? false { y += 1; continue }
        var variance = 0.0
        for r in 0..<segH where r % 4 == 0 { variance += rd(sig[y + r], sig[y]) }
        if variance < 500 { y += segH; continue }
        var bestSim = Double.greatestFiniteMagnitude, bestOff = 0
        var off = 50              // 真叠的偏移>=一行(~50px),太小的偏移会误判"相邻文字行相似"
        while off <= 180 {
            var cost = 0.0
            for r in 0..<segH where y + segH + off + r < totalH { cost += rd(sig[y + r], sig[y + off + r]) }
            if cost < bestSim { bestSim = cost; bestOff = off }
            off += 2
        }
        if bestSim < 3000 && bestOff > 0 {
            // [y, y+segH] 跟 [y+bestOff, y+bestOff+segH] 内容几乎一样 = 这段被画了两次
            // 裁掉 [y, y+bestOff](=从第一次出现到第二次出现之前的内容) → 直接进入第二次出现的版本，干净
            let dropStart = y, dropEnd = y + bestOff
            skipRanges.append((dropStart, dropEnd))
            FileHandle.standardError.write("[debug] 招F裁重: y=\(y) 裁掉 \(bestOff)px (相似度=\(Int(bestSim)))\n".data(using: .utf8)!)
            y = dropEnd
        } else { y += segH }
    }
    if skipRanges.isEmpty { return rep }
    // 把要裁的范围排除，生成新图
    let totalCut = skipRanges.reduce(0) { $0 + ($1.1 - $1.0) }
    let newH = totalH - totalCut
    guard let newRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: newH, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let newData = newRep.bitmapData else { return rep }
    let newBpr = newRep.bytesPerRow
    var srcY = 0, dstY = 0
    var skipIdx = 0
    while srcY < totalH {
        if skipIdx < skipRanges.count && srcY >= skipRanges[skipIdx].0 && srcY < skipRanges[skipIdx].1 {
            srcY = skipRanges[skipIdx].1; skipIdx += 1; continue
        }
        // 拷贝这一行
        memcpy(newData.advanced(by: dstY * newBpr), data.advanced(by: srcY * bpr), min(bpr, newBpr))
        srcY += 1; dstY += 1
    }
    FileHandle.standardError.write("[debug] 招F裁掉 \(totalCut)px (\(skipRanges.count)处), 新高=\(newH)\n".data(using: .utf8)!)
    return newRep
}

func selftest() {
    let W = 300, TH = 1800, H = 600
    let offs = [0, 300, 600, 900, 1200]
    let dir = NSTemporaryDirectory() + "lstest"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: TH, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
    for y in 0..<TH {   // 每行唯一颜色 + 列上有变化(纹理)
        for x in 0..<W {
            NSColor(deviceRed: CGFloat((y + x) & 255) / 255.0, green: CGFloat((y * 3) & 255) / 255.0, blue: CGFloat((x * 5) & 255) / 255.0, alpha: 1).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let tallCG = rep.cgImage!
    var paths: [String] = []
    for (i, off) in offs.enumerated() {
        let c = tallCG.cropping(to: CGRect(x: 0, y: off, width: W, height: H))!
        let p = "\(dir)/frame_\(String(format: "%03d", i)).tiff"
        if let t = NSImage(cgImage: c, size: NSSize(width: W, height: H)).tiffRepresentation { try? t.write(to: URL(fileURLWithPath: p)) }
        paths.append(p)
    }
    let gotH = stitchToPNG(paths, "\(dir)/stitched.png")
    print("自测: 原高 \(TH)，拼出 \(gotH) → \(abs(gotH - TH) <= 6 ? "✅ 通过" : "❌ 不对")")
}

let args = CommandLine.arguments
if args.contains("--selftest") {
    selftest()
} else if args.count >= 3 {
    if args.count >= 4, let ev = Int(args[3]) { gExpectedScroll = ev }   // 期望滚动量(像素)
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: args[1])) ?? [])
        .filter { $0.hasPrefix("frame_") && ($0.hasSuffix(".tiff") || $0.hasSuffix(".png")) }.sorted().map { args[1] + "/" + $0 }
    let h = stitchToPNG(files, args[2])
    print(h > 0 ? "拼接完成: \(args[2])  高度 \(h)px  (帧数 \(files.count))" : "拼接失败")
} else {
    print("用法: stitch <帧目录> <输出png>  或  stitch --selftest")
}
