-- 本地 AI 工具集 —— Hammerspoon 入口
-- 在 ~/.hammerspoon/init.lua 里用一行加载它：
--   dofile(os.getenv("HOME") .. "/Hui/ai-toolkit/hammerspoon/init.lua")

local PROJ   = os.getenv("HOME") .. "/Hui/ai-toolkit"
local FFMPEG = PROJ .. "/bin/ffmpeg"
local PY     = PROJ .. "/.venv/bin/python"
local WAV    = PROJ .. "/recordings/clip.wav"
local DASH_URL = "http://127.0.0.1:7799"

local cfg = {}
local function loadConfig()
  cfg = hs.json.read(PROJ .. "/config.json") or {}
end
loadConfig()

------------------------------------------------------------
-- 工具函数
------------------------------------------------------------
local function pasteAtCursor(text)
  if not text or text == "" then return end
  local old = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v")
  hs.timer.doAfter(0.4, function()
    if old then hs.pasteboard.setContents(old) end
  end)
end

local function getSelectedText()
  local old = hs.pasteboard.getContents()
  hs.eventtap.keyStroke({ "cmd" }, "c")
  hs.timer.usleep(120000)
  local sel = hs.pasteboard.getContents()
  if old then hs.timer.doAfter(0.3, function() hs.pasteboard.setContents(old) end) end
  return sel
end

local function parseHotkey(spec)
  local mods, key = {}, nil
  for token in spec:gmatch("[^+]+") do
    local t = token:lower()
    if t == "cmd" or t == "command" then table.insert(mods, "cmd")
    elseif t == "alt" or t == "option" or t == "opt" then table.insert(mods, "alt")
    elseif t == "ctrl" or t == "control" then table.insert(mods, "ctrl")
    elseif t == "shift" then table.insert(mods, "shift")
    else key = t end
  end
  return mods, key
end

------------------------------------------------------------
-- 工具一：语音听写
------------------------------------------------------------
local recTask = nil
-- 用系统默认输入设备（避免连 iPhone 时误用其麦克风）
local function micInput()
  local din = hs.audiodevice.defaultInputDevice()
  if din then local n = din:name(); if n and n ~= "" then return ":" .. n end end
  return ":" .. (cfg.audio_device_index or "0")
end
local function startDictation()
  hs.fs.mkdir(PROJ .. "/recordings")
  recTask = hs.task.new(FFMPEG, nil, {
    "-y", "-f", "avfoundation", "-i", micInput(),
    "-ar", "16000", "-ac", "1", WAV,
  })
  recTask:start()
  hs.alert.show("🎙 录音中…（再按一次结束）", 999)
end
local function stopDictation()
  hs.alert.closeAll()
  if recTask then recTask:terminate(); recTask = nil end
  hs.alert.show("⏳ 转写中…", 999)
  hs.timer.doAfter(0.5, function()
    local t = hs.task.new(PY, function(code, out, err)
      hs.alert.closeAll()
      out = (out or ""):gsub("^%s+", ""):gsub("%s+$", "")
      if out ~= "" then pasteAtCursor(out)
      else hs.alert.show("没听清，再试一次 🙉"); if err and err ~= "" then print("[听写] " .. err) end end
    end, { PROJ .. "/core/transcribe.py", WAV })
    t:start()
  end)
end
-- 切换式：按一下开始，再按一下结束
local dictRecording = false
local function toggleDictation()
  if not dictRecording then dictRecording = true; startDictation()
  else dictRecording = false; stopDictation() end
end

------------------------------------------------------------
-- 文本工具
------------------------------------------------------------
local function textTool(preset, label)
  local sel = getSelectedText()
  if not sel or sel == "" then hs.alert.show("先选中一段文字再按 🙂"); return end
  hs.alert.show("⏳ " .. label .. "中…", 999)
  -- 用临时文件把选中的文字传给程序（比 stdin 稳）
  local tmp = PROJ .. "/recordings/_text.txt"
  local f = io.open(tmp, "w")
  if f then f:write(sel); f:close() end
  local t = hs.task.new(PY, function(code, out, err)
    hs.alert.closeAll()
    os.remove(tmp)
    out = (out or ""):gsub("%s+$", "")
    if out ~= "" then pasteAtCursor(out)
    else hs.alert.show(label .. "失败 — 可能还没下载大模型？点菜单栏 🤖 → 打开控制面板 → 选个型号下载", 4); if err and err ~= "" then print("[" .. label .. "] " .. err) end end
  end, { PROJ .. "/core/llm.py", "--preset", preset, "--infile", tmp })
  t:start()
end

------------------------------------------------------------
-- 绑定 / 解绑快捷键（按 config.json 里的 tools）
------------------------------------------------------------
-- 单独修饰键（按住说话）：名字 -> {keyCode, 设备无关flag名}
local MODKEYS = {
  rightcmd = { 54, "cmd" }, leftcmd = { 55, "cmd" }, cmd = { 54, "cmd" },
  rightoption = { 61, "alt" }, rightalt = { 61, "alt" },
  fn = { 63, "fn" }, rightshift = { 60, "shift" }, rightcontrol = { 62, "ctrl" },
}

-- ⌥A 截图：先用精准检测取景器(见下方 selectRegion，AX透明遮罩→网页内也准)选好区域，
-- 再截全屏、打开 AIShot 并“预选中”那块 → 直达标注/提字/翻译/钉图(放大镜取色+手柄微调也保留)。
-- 真正实现放在 selectRegion 定义之后(见 doScreenshot 实体)，这里先前向声明。
local doScreenshot

------------------------------------------------------------
-- 长截图：框选区域 → 滚动连拍 → 拼接
------------------------------------------------------------
-- 长截图：复用截图程序的选区器(--selectonly) → 滚动连拍 → 拼接
------------------------------------------------------------
-- 自动滚动长截图（学市面上 Snagit/CleanShot 的做法：程序自己一步步滚，恒定重叠）
local longHotkeys, longDir, longRegion, longCount, longStep, longMax, longDone, longScale, longExpected, longScrollTimer
local function longFrame(i) return string.format("%s/frame_%03d.tiff", longDir, i) end

local function longCapture(path, cb)
  hs.alert.closeAll()                           -- 截前清掉提示浮层
  hs.task.new("/usr/sbin/screencapture",
    function() if cb then hs.timer.doAfter(0.05, cb) end end,
    { "-x", "-t", "tiff",
      string.format("-R%d,%d,%d,%d", longRegion.x, longRegion.y, longRegion.w, longRegion.h),
      "-o", path }):start()
end

local function longCleanup()
  if longHotkeys then for _, hk in ipairs(longHotkeys) do hk:delete() end; longHotkeys = nil end
end

local function longStitch()
  if longDone then return end
  longDone = true
  longCleanup()
  hs.alert.show("⏳ 拼接中…", 1.5)
  hs.timer.doAfter(0.5, function()
    local libdir = os.getenv("HOME") .. "/Pictures/截图收集"
    hs.execute("mkdir -p '" .. libdir .. "'")
    local out = libdir .. "/长截图_" .. os.date("%Y%m%d_%H%M%S") .. ".png"
    hs.task.new(PROJ .. "/screenshot/stitch", function(code, so, se)
      if code == 0 then
        local img = hs.image.imageFromPath(out)
        if img then hs.pasteboard.writeObjects(img) end
        -- 打开标注编辑器（可滚动 + 画框/箭头/打码/文字）；保存会覆盖这张图
        hs.task.new("/usr/bin/open", nil, { "-n", PROJ .. "/screenshot/AIShot.app", "--args", "--edit", out }):start()
        hs.alert.show("长截图完成 ✅ 已入收集架 + 复制 + 打开标注编辑器")
      else hs.alert.show("拼接失败"); print("[长截图] " .. (se or "")) end
    end, { longDir, out, tostring(longExpected or 0) }):start()   -- 把期望滚动量传给拼接器
  end)
end

-- 两图差异(变化像素千分比)：对桌宠/光标这种小面积动画不敏感
local function longDiff(a, b)
  local out = hs.execute(string.format("'%s/screenshot/imgdiff' '%s' '%s'", PROJ, a, b))
  return tonumber(out and out:match("%d+")) or 1000
end

-- 持续匀速滚动：每隔很短时间发一个小滚动，页面像录屏那样一直顺滑往下滑（不停顿）
local function longStartScroll()
  if longScrollTimer then longScrollTimer:stop() end
  longScrollTimer = hs.timer.new(0.035, function()
    if longDone then return end
    hs.eventtap.scrollWheel({ 0, -longStep }, {}, "pixel")
  end)
  longScrollTimer:start()
end
local function longStopScroll()
  if longScrollTimer then longScrollTimer:stop(); longScrollTimer = nil end
end

-- 边滑边连续抓拍：抓一张 → 立刻抓下一张（不停顿）；跟上一帧几乎没变=到底，停
local function longGrabLoop()
  if longDone then return end
  local nextp = longDir .. "/next.tiff"
  longCapture(nextp, function()
    if longDone then return end
    local last = longFrame(longCount)
    if longDiff(nextp, last) < 8 or longCount >= longMax then   -- 跟上一帧几乎没变=到底
      os.remove(nextp); longStopScroll(); longStitch()
    else
      longCount = longCount + 1
      os.rename(nextp, longFrame(longCount))
      hs.timer.doAfter(0.05, longGrabLoop)                      -- 抓下一张（滑动一直没停，只是抓拍间隔拉开点，减少帧数）
    end
  end)
end

local function startLongCapture()
  longDir = "/tmp/aishot_longframes"
  hs.execute("rm -rf '" .. longDir .. "'; mkdir -p '" .. longDir .. "'")
  longCount = 0
  longDone = false
  longStep = 22                                              -- 每次小滚动的量（持续高频发）→ 连续顺滑下滑
  longMax = 240                                              -- 连续抓拍帧数多，上限放大（到底会自动停）
  hs.mouse.absolutePosition({ x = longRegion.x + longRegion.w / 2,
                              y = longRegion.y + longRegion.h / 2 })  -- 鼠标移到区域中心，滚动才作用在目标窗口
  longHotkeys = {
    hs.hotkey.bind({}, "return", function() longStopScroll(); longStitch() end),     -- 提前完成
    hs.hotkey.bind({}, "escape", function() longDone = true; longStopScroll(); longCleanup(); hs.alert.show("已取消长截图") end),
  }
  longCapture(longFrame(0), function()                       -- 首帧
    longStartScroll()                                        -- 开始持续滚动
    longGrabLoop()                                           -- 同时开始连续抓拍
  end)
end

-- 框选 / 智能检测一个区域。cb(region) 或 cb(nil) 取消。
-- 交互：鼠标移到窗口/界面元素上自动高亮 → 单击截取那一块；按住拖拽 = 自由框选；
--        空格 = 在「元素级 / 窗口级」之间切换；Esc 取消；allowFull 时回车 ↩ = 整屏（cb 收到 {full=true}）。
local selTap, selEsc, selCanvas, selFull, selSpace
-- 命中检测：返回光标下窗口/元素的全局矩形（winMode=按窗口；否则按界面元素）
local function detectUnder(x, y, winMode, clampFrame)
  local function clamp(r)
    if not r then return nil end
    local x1 = math.max(r.x, clampFrame.x); local y1 = math.max(r.y, clampFrame.y)
    local x2 = math.min(r.x + r.w, clampFrame.x + clampFrame.w)
    local y2 = math.min(r.y + r.h, clampFrame.y + clampFrame.h)
    if x2 - x1 < 8 or y2 - y1 < 8 then return nil end
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
  end
  if winMode then
    for _, w in ipairs(hs.window.orderedWindows()) do        -- 前→后，第一个命中=最上层
      local app = w:application()
      if app and app:name() ~= "Hammerspoon" then
        local fr = w:frame()
        if fr.w >= 40 and fr.h >= 40 and x >= fr.x and x <= fr.x + fr.w and y >= fr.y and y <= fr.y + fr.h then
          return clamp({ x = fr.x, y = fr.y, w = fr.w, h = fr.h })
        end
      end
    end
    return nil
  end
  local ok, el = pcall(hs.axuielement.systemElementAtPosition, x, y)
  if not ok or not el then return nil end
  local fr = el:attributeValue("AXFrame")
  if not fr then
    local pos = el:attributeValue("AXPosition"); local sz = el:attributeValue("AXSize")
    if pos and sz then fr = { x = pos.x, y = pos.y, w = sz.w, h = sz.h } end
  end
  if not fr or not fr.w or fr.w < 8 or fr.h < 8 then return nil end
  return clamp({ x = fr.x, y = fr.y, w = fr.w, h = fr.h })
end

local function selectRegion(cb, allowFull, startWin)
  if selTap or selCanvas then return end                            -- 已有选区器在进行，忽略，杜绝叠加两层覆盖层/泄漏
  local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  local sf = scr:fullFrame()
  selCanvas = hs.canvas.new(sf)
  selCanvas:level(hs.canvas.windowLevels.overlay)
  selCanvas:appendElements(
    { type = "rectangle", action = "fill", fillColor = { alpha = 0.18, white = 0 } },             -- [1] 压暗
    { type = "rectangle", action = "stroke", strokeColor = { alpha = 0 }, strokeWidth = 2 },       -- [2] 高亮/选框(初始透明)
    { type = "rectangle", action = "fill", fillColor = { alpha = 0, white = 0.07 } },              -- [3] 提示胶囊底(由 drawHint 设置)
    { type = "text", text = "", textColor = { alpha = 0 } },                                       -- [4] 提示文字(由 drawHint 设置)
    { type = "text", text = "", textColor = { alpha = 0 } })                                       -- [5] 高亮角标(窗口/元素)
  selCanvas:show()

  local p0, dragging, winMode, detected = nil, false, startWin or false, nil
  local lastT = 0
  local pillW, pillH = 640, 40
  local pillX, pillY = 24, sf.h - pillH - 24                         -- 提示胶囊：左下角(画布坐标，顶左原点)
  local pillShown = true
  local function drawHint()                                          -- 左下角提示胶囊，按 pillShown 显隐
    local a = pillShown and 0.82 or 0
    local ta = pillShown and 1 or 0
    local cur = winMode and "窗口" or "元素"
    local other = winMode and "元素" or "窗口"
    selCanvas[3] = { type = "rectangle", action = "fill", fillColor = { alpha = a, white = 0.07 },
      roundedRectRadii = { xRadius = 10, yRadius = 10 }, frame = { x = pillX, y = pillY, w = pillW, h = pillH } }
    selCanvas[4] = { type = "text",
      text = string.format("检测【%s】  按 空格 切换为【%s】   ·   单击=截取 · 拖拽=框选%s · Esc 取消",
        cur, other, allowFull and " · 回车=整屏" or ""),
      frame = { x = pillX, y = pillY + 9, w = pillW, h = 24 },
      textColor = { white = 1, alpha = ta }, textSize = 15, textAlignment = "center" }
  end
  local function showRect(r)                                         -- r=全局矩形，nil=清除
    if r then
      selCanvas[2] = { type = "rectangle", action = "strokeAndFill", strokeWidth = 2.5,
        strokeColor = { red = 0.04, green = 0.52, blue = 1, alpha = 1 },
        fillColor = { red = 0.04, green = 0.52, blue = 1, alpha = 0.12 },
        frame = { x = r.x - sf.x, y = r.y - sf.y, w = r.w, h = r.h } }
      local ly = math.max(0, r.y - sf.y - 20)                        -- 角标贴在框左上(超出屏顶则改到框内)
      selCanvas[5] = { type = "text", text = winMode and " 窗口 " or " 元素 ", textSize = 13,
        textColor = { white = 1, alpha = 1 }, frame = { x = r.x - sf.x, y = ly, w = 60, h = 18 } }
    else
      selCanvas[2] = { type = "rectangle", action = "stroke", strokeColor = { alpha = 0 }, strokeWidth = 2 }
      selCanvas[5] = { type = "text", text = "", textColor = { alpha = 0 } }
    end
  end
  drawHint()

  local function finish(region)
    if selTap then selTap:stop(); selTap = nil end
    if selEsc then selEsc:delete(); selEsc = nil end
    if selFull then selFull:delete(); selFull = nil end
    if selSpace then selSpace:delete(); selSpace = nil end
    if selCanvas then selCanvas:delete(); selCanvas = nil end
    cb(region)
  end
  if allowFull then selFull = hs.hotkey.bind({}, "return", function() finish({ full = true }) end) end
  selSpace = hs.hotkey.bind({}, "space", function()                 -- 切窗口/元素级，并就地重新检测
    winMode = not winMode; drawHint()
    local mp = hs.mouse.absolutePosition()
    detected = detectUnder(mp.x, mp.y, winMode, sf); showRect(detected)
  end)

  local T = hs.eventtap.event.types
  selTap = hs.eventtap.new({ T.mouseMoved, T.leftMouseDown, T.leftMouseDragged, T.leftMouseUp }, function(e)
    local t, m = e:getType(), e:location()
    if t == T.mouseMoved then
      local cx, cy = m.x - sf.x, m.y - sf.y                         -- 鼠标靠近左下角提示就自动隐藏它(不挡视线)
      local want = not (cx >= pillX - 40 and cx <= pillX + pillW + 40 and cy >= pillY - 40 and cy <= pillY + pillH + 40)
      if want ~= pillShown then pillShown = want; drawHint() end
      if not p0 then                                                -- 未按下时才做悬停检测(带轻微节流)
        local now = hs.timer.secondsSinceEpoch()
        if now - lastT >= 0.04 then
          lastT = now
          detected = detectUnder(m.x, m.y, winMode, sf); showRect(detected)
        end
      end
    elseif t == T.leftMouseDown then
      p0 = m; dragging = false
      detected = detectUnder(m.x, m.y, winMode, sf); showRect(detected)  -- 按下即检测：单击兜底，不只靠悬停
    elseif t == T.leftMouseDragged and p0 then
      if math.abs(m.x - p0.x) > 6 or math.abs(m.y - p0.y) > 6 then dragging = true end
      if dragging then
        selCanvas[2] = { type = "rectangle", action = "strokeAndFill", strokeWidth = 2,
          strokeColor = { red = 0.04, green = 0.52, blue = 1, alpha = 1 },
          fillColor = { red = 0.04, green = 0.52, blue = 1, alpha = 0.10 },
          frame = { x = math.min(p0.x, m.x) - sf.x, y = math.min(p0.y, m.y) - sf.y,
                    w = math.abs(m.x - p0.x), h = math.abs(m.y - p0.y) } }
      end
    elseif t == T.leftMouseUp and p0 then
      local a = p0; p0 = nil
      if dragging then                                              -- 自由框选：太小当取消
        local x, y = math.min(a.x, m.x), math.min(a.y, m.y)
        local w, h = math.abs(m.x - a.x), math.abs(m.y - a.y)
        if w < 50 or h < 50 then finish(nil)
        else finish({ x = math.floor(x), y = math.floor(y), w = math.floor(w), h = math.floor(h) }) end
      else                                                          -- 单击：截取当前高亮块
        local r = detected or detectUnder(m.x, m.y, winMode, sf)     -- 再兜底检测一次
        if r then finish({ x = math.floor(r.x), y = math.floor(r.y), w = math.floor(r.w), h = math.floor(r.h) })
        else hs.alert.show("这里没检测到内容，请拖拽框选 或按 Esc 取消", 1.2) end
      end
    end
    return true                                                     -- 吞掉鼠标事件，别让底下页面响应
  end)
  selTap:start()
  selEsc = hs.hotkey.bind({}, "escape", function() finish(nil) end)
end

local function doLongShot()
  hs.alert.show("📜 长截图：移到窗口/正文上单击直接选中，或拖拽框选；空格切窗口/元素；Esc 取消", 2.5)
  selectRegion(function(region)
    if not region then hs.alert.show("已取消长截图"); return end
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local mode = scr:currentMode()
    longScale = (mode and mode.scale) or 2                    -- Retina 缩放(通常2)
    longRegion = region                                       -- 用户框选的区域(全局点坐标，screencapture -R 直接用)
    hs.alert.show("📜 1.5 秒后自动向下滚动截取所选区域\n到底自动停 · Esc 取消 · ↩ 提前完成", 1.5)
    hs.timer.doAfter(1.7, startLongCapture)
  end)
end

------------------------------------------------------------
-- 工具：录屏（系统自带 screencapture -v，零依赖；框选区域或整屏）
-- 开始/停止用同一个快捷键切换；停止靠给进程发 SIGINT(才能写出完整 mov)
------------------------------------------------------------
local recVidTask, recVidPid, recVidOut, recVidMenu, recVidTimer, recVidStart, recVidHotkeys, recVidStopping, recVidSelecting

local function recVidFinish()
  if not recVidTask or recVidStopping then return end
  recVidStopping = true
  if recVidHotkeys then for _, hk in ipairs(recVidHotkeys) do hk:delete() end; recVidHotkeys = nil end
  if recVidTimer then recVidTimer:stop(); recVidTimer = nil end
  if recVidMenu then recVidMenu:delete(); recVidMenu = nil end
  hs.alert.closeAll()
  local pid, out = recVidPid, recVidOut
  recVidTask = nil; recVidPid = nil
  -- 关键：screencapture 录屏要发 SIGINT 才会正常收尾写文件（SIGTERM/terminate 会把文件丢掉）
  if pid then hs.execute("kill -INT " .. pid) end
  hs.alert.show("⏳ 正在保存录屏…", 1.5)
  hs.timer.doAfter(1.6, function()
    recVidStopping = false
    if out and hs.fs.attributes(out) then
      hs.execute(string.format("open -R '%s'", out))                 -- 在访达里高亮这个文件
      hs.alert.show("录屏完成 ✅ 已存到「影片/录屏收集」并在访达打开")
    else
      hs.alert.show("录屏好像没保存成功 😕（看看是否给了屏幕录制权限）")
    end
  end)
end

local function startScreenRecord(region)                              -- region=nil → 整屏
  local libdir = os.getenv("HOME") .. "/Movies/录屏收集"
  hs.execute("mkdir -p '" .. libdir .. "'")
  recVidOut = libdir .. "/录屏_" .. os.date("%Y%m%d_%H%M%S") .. ".mov"
  local args = { "-v", "-x", "-k" }                                  -- -x 静音 -k 显示鼠标点击
  if region and not region.full then
    table.insert(args, string.format("-R%d,%d,%d,%d", region.x, region.y, region.w, region.h))
  end
  table.insert(args, recVidOut)
  recVidTask = hs.task.new("/usr/sbin/screencapture", function() end, args)
  recVidTask:start()
  recVidPid = recVidTask:pid()
  recVidStart = os.time()
  recVidMenu = hs.menubar.new()                                      -- 菜单栏红点+计时，点它即停
  local function tick()
    if not recVidMenu then return end
    local s = os.time() - (recVidStart or os.time())
    recVidMenu:setTitle(string.format("🔴 %d:%02d", math.floor(s / 60), s % 60))
  end
  tick()
  if recVidMenu then recVidMenu:setClickCallback(recVidFinish) end
  recVidTimer = hs.timer.new(1, tick):start()
  recVidHotkeys = { hs.hotkey.bind({}, "escape", recVidFinish) }     -- Esc 也能停（主快捷键由 toggle 处理）
  hs.alert.show("🔴 录制中（纯画面·无声音）…  再按一次快捷键 / 点菜单栏 🔴 / Esc  即可停止", 2.5)
end

local function doRecord()
  recVidSelecting = true                                             -- 标记"框选中"，挡住重复进入
  hs.alert.show("🎬 录屏（无声音）：移到窗口上单击直接选中，或拖拽框选；整屏按回车 ↩；空格切窗口/元素；取消按 Esc", 3.5)
  selectRegion(function(region)
    recVidSelecting = false
    if not region then hs.alert.show("已取消录屏"); return end
    startScreenRecord(region)
  end, true)                                                         -- allowFull：回车=整屏
end

-- 同一个快捷键：没在录就开始（先框选），正在录就停止
local function toggleRecord()
  if recVidStopping then hs.alert.show("正在保存上一段录屏，请稍候…"); return end  -- 收尾窗口期，忽略
  if recVidTask then recVidFinish()
  elseif recVidSelecting then return                                 -- 正在框选，别叠第二个选区器（取消用 Esc）
  else doRecord() end
end

-- ⌥A 截图实体：精准检测取景(selectRegion，网页内也准) → 截全屏 → ShotWindow 预选中那块 → 直达标注/提字/翻译/钉图
function doScreenshot()
  hs.alert.show("📸 截图：移到窗口/元素上单击选中，或拖拽框选；整屏按回车 ↩；空格切窗口/元素；Esc 取消", 2.5)
  selectRegion(function(region)
    if not region then return end
    local APP = PROJ .. "/screenshot/AIShot.app"
    local full = "/tmp/aifull.tiff"; os.remove(full)
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = scr:fullFrame()
    local rx, ry, rw, rh
    if region.full then rx, ry, rw, rh = 0, 0, math.floor(f.w), math.floor(f.h)
    else rx, ry, rw, rh = math.floor(region.x - f.x), math.floor(region.y - f.y), region.w, region.h end
    hs.task.new("/usr/sbin/screencapture", function()
      local file = io.open(full, "r")
      if file then file:close()
        hs.task.new("/usr/bin/open", nil, { "-n", APP, "--args", "--shot", full,
          "--presel", string.format("%d,%d,%d,%d", rx, ry, rw, rh) }):start()
      end
    end, { "-x", "-t", "tiff", string.format("-R%d,%d,%d,%d", f.x, f.y, f.w, f.h), "-o", full }):start()
  end, true)
end

local bound = {}
local dictTap = nil
local function bindAll()
  for _, hk in ipairs(bound) do hk:delete() end
  bound = {}
  if dictTap then dictTap:stop(); dictTap = nil end
  for key, tool in pairs(cfg.tools or {}) do
    if tool.enabled and tool.hotkey and tool.hotkey ~= "" then
      local spec = tool.hotkey:lower()
      local mod = (tool.kind == "speech") and MODKEYS[spec] or nil
      if mod then
        -- 按住单个修饰键说话（监听 flagsChanged）
        dictTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
          -- 仅在"按下"那一刻切换：按一下开始，再按一下结束
          if e:getKeyCode() == mod[1] and e:getFlags()[mod[2]] then toggleDictation() end
          return false
        end)
        dictTap:start()
      else
        local mods, k = parseHotkey(tool.hotkey)
        if k then
          if tool.kind == "speech" then
            table.insert(bound, hs.hotkey.bind(mods, k, toggleDictation))
          elseif tool.kind == "screenshot" then
            table.insert(bound, hs.hotkey.bind(mods, k, doScreenshot))
          elseif tool.kind == "longshot" then
            table.insert(bound, hs.hotkey.bind(mods, k, doLongShot))
          elseif tool.kind == "record" then
            table.insert(bound, hs.hotkey.bind(mods, k, toggleRecord))
          else
            local preset, label = tool.preset, tool.name
            table.insert(bound, hs.hotkey.bind(mods, k, function() textTool(preset, label) end))
          end
        end
      end
    end
  end
end

------------------------------------------------------------
-- 控制面板（独立窗口，用 hs.webview 显示同一个面板）
------------------------------------------------------------
local dashWin = nil
local function openDashboard()
  if dashWin then dashWin:show():bringToFront(true); return end
  local scr = hs.screen.mainScreen():frame()
  local w, h = 900, 760
  dashWin = hs.webview.new({ x = scr.x + (scr.w - w) / 2, y = scr.y + (scr.h - h) / 2, w = w, h = h })
    :windowStyle({ "titled", "closable", "resizable" })
    :windowTitle("本地 AI 工具集 · 控制面板")
    :allowTextEntry(true)
    :deleteOnClose(true)
    :windowCallback(function(action) if action == "closing" then dashWin = nil end end)
    :url(DASH_URL)
  dashWin:show():bringToFront(true)
end

-- 截图收集架（右侧抽屉）
local trayWin = nil
local function toggleTray()
  if trayWin then trayWin:delete(); trayWin = nil; return end
  local f = hs.screen.mainScreen():frame()
  local W = 320
  trayWin = hs.webview.new({ x = f.x + f.w - W, y = f.y, w = W, h = f.h })
    :windowStyle({ "titled", "closable", "resizable" })
    :windowTitle("📸 截图·录屏 收集")
    :deleteOnClose(true)
    :windowCallback(function(a) if a == "closing" then trayWin = nil end end)
    :url(DASH_URL .. "/tray")
  trayWin:show():bringToFront(true)
end

------------------------------------------------------------
-- 自动更新：定时查 GitHub 仓库版本，有新版就在菜单栏提示，一键拉取覆盖更新(保留用户设置)
------------------------------------------------------------
local refreshMenu                                                   -- 前向声明：checkUpdate 在 refreshMenu 定义之前就要用它
local function localVersion()
  local f = io.open(PROJ .. "/VERSION"); local v = f and f:read("*l"); if f then f:close() end
  return (v or ""):gsub("%s+$", "")
end
local updateAvail, updateRemoteVer = false, nil
local updating = false
local function checkUpdate(manual)
  local repo = (cfg.update_repo or ""):gsub("%s+", "")
  if repo == "" then if manual then hs.alert.show("还没设置更新源（GitHub 仓库）") end; return end
  if manual then hs.alert.show("⏳ 检查更新中…", 1) end
  local url = "https://raw.githubusercontent.com/" .. repo .. "/main/VERSION"
  hs.task.new("/usr/bin/curl", function(code, out)
    local remote = (out or ""):gsub("%s+$", "")
    if code == 0 and remote ~= "" then
      if remote ~= localVersion() then
        updateAvail = true; updateRemoteVer = remote; refreshMenu()
        if manual then hs.alert.show("🆕 有新版本，点菜单栏 🤖 → 更新") end
      else
        updateAvail = false; refreshMenu()
        if manual then hs.alert.show("已经是最新版 ✅") end
      end
    elseif manual then hs.alert.show("检查更新失败（网络？仓库名？）") end
  end, { "-fsL", "--connect-timeout", "10", "--max-time", "20", url }):start()
end
local function doUpdate()
  if updating then return end
  local repo = (cfg.update_repo or ""):gsub("%s+", "")
  if repo == "" then return end
  updating = true
  hs.alert.show("⏳ 正在更新到最新版…（下载+覆盖，请稍候）", 999)
  hs.task.new("/bin/bash", function(code, _, se)
    updating = false; hs.alert.closeAll()
    if code == 0 then
      updateAvail = false
      hs.alert.show("✅ 已更新到最新版，正在重载…")
      hs.timer.doAfter(1.0, function() hs.reload() end)
    else
      hs.alert.show("更新失败，稍后再试（已保留你的配置不变）"); if se and se ~= "" then print("[更新] " .. se) end
    end
  end, { PROJ .. "/core/selfupdate.sh", repo }):start()
end

------------------------------------------------------------
-- 菜单栏图标
------------------------------------------------------------
menu = hs.menubar.new()  -- 用全局变量持有，防止被 Lua 垃圾回收导致图标消失
function refreshMenu()                                              -- 复用上面的前向声明(不要再 local)
  if not menu then return end
  menu:setTitle(updateAvail and "🤖🔴" or "🤖")
  local items = { { title = "本地 AI 工具集", disabled = true }, { title = "-" } }
  for _, key in ipairs({ "dictation", "translate", "polish", "summarize", "screenshot", "longshot", "record" }) do
    local t = (cfg.tools or {})[key]
    if t then
      table.insert(items, {
        title = string.format("%s %s   [%s]", t.icon or "•", t.name, t.hotkey or "未设"),
        checked = t.enabled,
        fn = function() openDashboard() end,
      })
    end
  end
  table.insert(items, { title = "-" })
  table.insert(items, { title = "文本模型: " .. ((cfg.models or {}).text or "未设"), disabled = true })
  table.insert(items, { title = "语音模型: " .. ((cfg.models or {}).speech or "未设"), disabled = true })
  table.insert(items, { title = "-" })
  table.insert(items, { title = "📸 截图·录屏 收集 (⌥G)", fn = function() toggleTray() end })
  table.insert(items, { title = "⚙︎ 打开控制面板", fn = function() openDashboard() end })
  table.insert(items, { title = "-" })
  if updateAvail then
    table.insert(items, { title = "🆕 有新版本（" .. (updateRemoteVer or "") .. "）→ 点此更新", fn = function() doUpdate() end })
  else
    table.insert(items, { title = "↻ 检查更新", fn = function() checkUpdate(true) end })
  end
  table.insert(items, { title = "↻ 重新加载", fn = function() hs.reload() end })
  menu:setMenu(items)
end

------------------------------------------------------------
-- 控制面板服务器（本地网页）
------------------------------------------------------------
local serverTask = hs.task.new("/usr/bin/python3", nil, { PROJ .. "/ui/server.py" })
serverTask:start()

------------------------------------------------------------
-- 配置变更自动重载
------------------------------------------------------------
local watcher = hs.pathwatcher.new(PROJ .. "/config.json", function()
  loadConfig(); bindAll(); refreshMenu()
  hs.alert.show("设置已更新 ✅")
end):start()

-- 设置开机自动启动，避免每次手动开
hs.autoLaunch(true)

bindAll()

------------------------------------------------------------
-- 自愈：听写用的修饰键监听(eventtap)偶尔被系统(休眠/超时/用户输入)禁用，
-- 会导致"过一会儿按右⌘没反应、要重载"。这里定时检查并自动重启，免手动重载。
------------------------------------------------------------
local function reviveDictTap()
  if dictTap and not dictTap:isEnabled() then
    dictTap:start()
    print("[听写] 监听曾被系统禁用，已自动重启")
  end
end
dictWatchdog = hs.timer.new(4, reviveDictTap):start()        -- 每4秒检查一次（全局持有防GC）
dictWake = hs.caffeinate.watcher.new(function(ev)            -- 休眠/锁屏唤醒后立刻补一枪
  local W = hs.caffeinate.watcher
  if ev == W.systemDidWake or ev == W.screensDidWake or ev == W.sessionDidBecomeActive then
    hs.timer.doAfter(1.5, reviveDictTap)
  end
end):start()

refreshMenu()
hs.hotkey.bind({ "alt" }, "g", toggleTray)   -- ⌥G 开关截图收集架

-- 启动 12 秒后自动查一次更新；之后每 6 小时查一次（都不阻塞、不打扰）
hs.timer.doAfter(12, function() checkUpdate(false) end)
updateTimer = hs.timer.new(6 * 3600, function() checkUpdate(false) end):start()  -- 全局持有防GC

-- 自动化验证用：URL 触发器，脚本执行 open "hammerspoon://longshot" 即可精确触发长截图
hs.urlevent.bind("longshot", function() doLongShot() end)
hs.urlevent.bind("record", function() toggleRecord() end)            -- 录屏开始/停止切换
hs.urlevent.bind("detectprobe", function()                           -- 可行性探针：命中测试能否拿到元素边框
  local f = io.open("/tmp/detect_probe.txt", "w")
  -- 聚焦 Chrome，鼠标移到其窗口内一个位置，做命中测试
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus() end end
  hs.timer.usleep(400000)
  local mp = hs.mouse.absolutePosition()
  local win = app and (app:mainWindow())
  local probePts = {}
  if win then local fr = win:frame()
    probePts = {
      { x = fr.x + fr.w/2, y = fr.y + 60 },     -- 顶部工具栏区域
      { x = fr.x + fr.w/2, y = fr.y + fr.h/2 }, -- 正文区域
    }
  else probePts = { { x = mp.x, y = mp.y } } end
  for i, p in ipairs(probePts) do
    f:write(string.format("--- 探测点%d (%.0f,%.0f) ---\n", i, p.x, p.y))
    local el = hs.axuielement.systemElementAtPosition(p.x, p.y)
    if not el then f:write("  systemElementAtPosition 返回 nil\n")
    else
      local role = el:attributeValue("AXRole")
      local frame = el:attributeValue("AXFrame")
      local pos = el:attributeValue("AXPosition")
      local size = el:attributeValue("AXSize")
      f:write("  AXRole=" .. tostring(role) .. "\n")
      f:write("  AXFrame=" .. (frame and string.format("%.0f,%.0f,%.0f,%.0f", frame.x, frame.y, frame.w, frame.h) or "nil") .. "\n")
      f:write("  AXPosition=" .. tostring(pos and (pos.x..","..pos.y)) .. "  AXSize=" .. tostring(size and (size.w..","..size.h)) .. "\n")
      -- 看父链能否走到"更大块"的元素(用于 window/element 两级)
      local parent = el:attributeValue("AXParent")
      local pframe = parent and parent:attributeValue("AXFrame")
      f:write("  父元素 AXRole=" .. tostring(parent and parent:attributeValue("AXRole")) ..
              "  AXFrame=" .. (pframe and string.format("%.0f,%.0f,%.0f,%.0f", pframe.x, pframe.y, pframe.w, pframe.h) or "nil") .. "\n")
    end
  end
  f:write("--- orderedWindows 数=" .. #hs.window.orderedWindows() .. " ---\n")
  for i, w in ipairs(hs.window.orderedWindows()) do
    if i > 5 then break end
    local fr = w:frame()
    f:write(string.format("  win%d %s [%s] %.0f,%.0f,%.0f,%.0f\n", i,
      (w:application() and w:application():name() or "?"), tostring(w:title()):sub(1,20), fr.x, fr.y, fr.w, fr.h))
  end
  -- 关键测试：盖一层全屏压暗 canvas 后，命中测试还能不能看穿到底下的应用？
  if win and #probePts >= 2 then
    local scr = hs.screen.mainScreen():fullFrame()
    local testCanvas = hs.canvas.new(scr)
    testCanvas:level(hs.canvas.windowLevels.overlay)
    testCanvas:appendElements({ type = "rectangle", action = "fill", fillColor = { alpha = 0.18, white = 0 } })
    testCanvas:show()
    hs.timer.usleep(300000)
    local p = probePts[2]
    local el2 = hs.axuielement.systemElementAtPosition(p.x, p.y)
    local role2 = el2 and el2:attributeValue("AXRole")
    -- 找出这个元素属于哪个 App（看是不是被 Hammerspoon 自己的遮罩挡了）
    local appOfEl = "?"
    local cur = el2
    for _ = 1, 12 do
      if not cur then break end
      local r = cur:attributeValue("AXRole")
      if r == "AXApplication" then appOfEl = tostring(cur:attributeValue("AXTitle")); break end
      cur = cur:attributeValue("AXParent")
    end
    f:write("--- 遮罩canvas在场时命中点2 ---\n")
    f:write("  AXRole=" .. tostring(role2) .. "  所属App=" .. appOfEl .. "\n")
    f:write(appOfEl == "Hammerspoon" and "  ❌ 被遮罩挡住(返回了Hammerspoon自己)\n" or "  ✅ 看穿了遮罩(返回底下应用的元素)\n")
    testCanvas:delete()
  end
  f:close()
end)
hs.urlevent.bind("recordfull", function()                            -- 自动化：直接整屏录制(跳过框选)
  if recVidTask then recVidFinish() else startScreenRecord(nil) end
end)
hs.urlevent.bind("longtest", function()   -- 自动化：先把 Chrome 窗口聚焦并最大化，再长截图
  local app = hs.application.find("Google Chrome")
  if app then
    app:activate()
    local win = app:mainWindow() or (app:allWindows() or {})[1]
    if win then win:focus(); win:maximize() end
  end
  hs.timer.doAfter(0.8, doLongShot)
end)
hs.urlevent.bind("regiontest", function()   -- 自动化：聚焦Chrome → 模拟拖拽框选一个区域 → 长截图
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(1.0, function()
    doLongShot()
    local ME, TY = hs.eventtap.event.newMouseEvent, hs.eventtap.event.types
    hs.timer.doAfter(0.6, function() ME(TY.leftMouseDown, { x = 220, y = 170 }):post() end)
    hs.timer.doAfter(0.70, function() ME(TY.leftMouseDragged, { x = 650, y = 600 }):post() end)
    hs.timer.doAfter(0.80, function() ME(TY.leftMouseDragged, { x = 1150, y = 980 }):post() end)
    hs.timer.doAfter(0.90, function() ME(TY.leftMouseUp, { x = 1150, y = 980 }):post() end)
  end)
end)
-- 自动化：驱动真实 selectRegion 验证检测交互（结果写 /tmp/detect_test.txt）
local function _detectRun(mode)
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(0.9, function()
    selectRegion(function(region)
      local f = io.open("/tmp/detect_test.txt", "w")
      f:write("mode=" .. mode .. " region=" .. (region and (region.full and "FULL" or
        string.format("%d,%d,%d,%d", region.x, region.y, region.w, region.h)) or "nil") .. "\n")
      f:close()
    end)
    local ME, TY = hs.eventtap.event.newMouseEvent, hs.eventtap.event.types
    local pt = { x = 864, y = 546 }                                  -- Chrome 正文区
    if mode == "click" then                                          -- 移到元素→单击截取
      hs.timer.doAfter(0.3, function() ME(TY.mouseMoved, pt):post() end)
      hs.timer.doAfter(0.5, function() ME(TY.mouseMoved, { x = 866, y = 548 }):post() end)
      hs.timer.doAfter(0.8, function() ME(TY.leftMouseDown, pt):post() end)
      hs.timer.doAfter(0.9, function() ME(TY.leftMouseUp, pt):post() end)
    elseif mode == "drag" then                                       -- 自由拖拽框选
      hs.timer.doAfter(0.3, function() ME(TY.leftMouseDown, { x = 300, y = 250 }):post() end)
      hs.timer.doAfter(0.45, function() ME(TY.leftMouseDragged, { x = 700, y = 600 }):post() end)
      hs.timer.doAfter(0.6, function() ME(TY.leftMouseDragged, { x = 900, y = 760 }):post() end)
      hs.timer.doAfter(0.75, function() ME(TY.leftMouseUp, { x = 900, y = 760 }):post() end)
    end
  end)
end
hs.urlevent.bind("shottest", function() doScreenshot() end)         -- 完整 ⌥A 流程(检测取景)
local function _readPt()                                             -- 从 /tmp/aimove_pt.txt 读 "x y"
  local f = io.open("/tmp/aimove_pt.txt"); local s = f and f:read("*a"); if f then f:close() end
  local x, y = (s or "700 400"):match("(%-?%d+)%s+(%-?%d+)")
  return { x = tonumber(x) or 700, y = tonumber(y) or 400 }
end
hs.urlevent.bind("aimove", function()                               -- 测试用:真鼠标移到指定点触发悬停高亮
  local p = _readPt()
  hs.mouse.absolutePosition(p)
  hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.mouseMoved, p):post()
end)
hs.urlevent.bind("selonly", function() selectRegion(function() end, true) end)  -- 测试用:只打开选区器(不模拟点击)
hs.urlevent.bind("selesc", function() hs.eventtap.keyStroke({}, "escape") end)  -- 测试用:发 Esc 关掉选区器
hs.urlevent.bind("selwinshow", function()                           -- 测试用:以"窗口模式"开框选器，在指定点显示窗口高亮
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(0.8, function()
    selectRegion(function() end, false, true)                        -- startWin=true
    local p = _readPt()
    hs.timer.doAfter(0.4, function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, p):post() end)
    hs.timer.doAfter(3.0, function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, p):post() end)
  end)
end)
hs.urlevent.bind("shotclick", function()                            -- 测试用:⌥A 取景→在指定点单击元素→截图
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(0.9, function()
    doScreenshot()
    local p = _readPt()
    local ME, TY = hs.eventtap.event.newMouseEvent, hs.eventtap.event.types
    hs.timer.doAfter(0.4, function() ME(TY.leftMouseDown, p):post() end)
    hs.timer.doAfter(0.5, function() ME(TY.leftMouseUp, p):post() end)
  end)
end)
hs.urlevent.bind("selregionshow", function()                        -- 测试用:打开框选器并在指定点显示高亮(mouseDown触发，不松开)
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(0.8, function()
    selectRegion(function() end, false)
    local p = _readPt()
    hs.timer.doAfter(0.4, function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseDown, p):post() end)
    hs.timer.doAfter(3.0, function() hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.leftMouseUp, p):post() end)  -- 自动收尾关闭
  end)
end)
hs.urlevent.bind("detectat", function()                             -- 测试用:打印指定点的检测结果 vs 原始AXFrame
  local p = _readPt()
  local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
  local r = detectUnder(p.x, p.y, false, sf)
  local ok, el = pcall(hs.axuielement.systemElementAtPosition, p.x, p.y)
  local role = ok and el and el:attributeValue("AXRole")
  local af = ok and el and el:attributeValue("AXFrame")
  local f = io.open("/tmp/detect_at.txt", "w")
  f:write(string.format("点=(%d,%d) 屏sf=%d,%d,%d,%d\n", p.x, p.y, sf.x, sf.y, sf.w, sf.h))
  f:write("AXRole=" .. tostring(role) .. "\n")
  f:write("原始AXFrame(全局)=" .. (af and string.format("%.0f,%.0f,%.0f,%.0f", af.x, af.y, af.w, af.h) or "nil") .. "\n")
  f:write("detectUnder(相对屏,裁剪后)=" .. (r and string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h) or "nil") .. "\n")
  f:close()
end)
hs.urlevent.bind("detecttest", function() _detectRun("click") end)
hs.urlevent.bind("detectdragtest", function() _detectRun("drag") end)
hs.urlevent.bind("detectunit", function()                           -- 直接测 detectUnder(绕开事件合成)
  local app = hs.application.find("Google Chrome")
  if app then app:activate(); local w = app:mainWindow(); if w then w:focus(); w:maximize() end end
  hs.timer.doAfter(0.9, function()
    local sf = (hs.mouse.getCurrentScreen() or hs.screen.mainScreen()):fullFrame()
    local el = detectUnder(864, 546, false, sf)                     -- 元素级
    local wn = detectUnder(864, 546, true, sf)                      -- 窗口级
    local f = io.open("/tmp/detect_test.txt", "w")
    f:write("元素=" .. (el and string.format("%d,%d,%d,%d", el.x, el.y, el.w, el.h) or "nil") .. "\n")
    f:write("窗口=" .. (wn and string.format("%d,%d,%d,%d", wn.x, wn.y, wn.w, wn.h) or "nil") .. "\n")
    f:close()
  end)
end)
hs.urlevent.bind("axprobe", function()   -- 可行性探测：能否读到真实滚动位置
  local tf = io.open("/tmp/ax_target.txt"); local target = (tf and tf:read("*l")) or "Google Chrome"; if tf then tf:close() end
  local f = io.open("/tmp/ax_probe.txt", "w")
  local app = hs.application.find(target)
  f:write("target=" .. target .. "  app=" .. (app and app:name() or "nil") .. "\n")
  if not app then f:write("找不到该App\n"); f:close(); return end
  app:activate()
  local axApp = hs.axuielement.applicationElement(app)
  local win = axApp and axApp:attributeValue("AXFocusedWindow")
  if not win then f:write("无焦点窗口\n"); f:close(); return end
  local found = {}
  local function walk(el, depth)
    if not el or depth > 14 or #found >= 1 then return end
    local ok, role = pcall(function() return el:attributeValue("AXRole") end)
    if ok and role == "AXScrollArea" then found[#found + 1] = el; return end
    local kids = el:attributeValue("AXChildren") or {}
    for _, k in ipairs(kids) do walk(k, depth + 1) end
  end
  walk(win, 0)
  f:write("找到 ScrollArea 数=" .. #found .. "\n")
  if #found >= 1 then
    local sa = found[1]
    local vsb = sa:attributeValue("AXVerticalScrollBar")
    local v1 = vsb and vsb:attributeValue("AXValue")
    f:write("竖滚动条=" .. tostring(vsb) .. "  值1=" .. tostring(v1) .. "\n")
    local w = app:focusedWindow() or app:mainWindow()
    if w then local fr = w:frame(); hs.mouse.absolutePosition({ x = fr.x + fr.w / 2, y = fr.y + fr.h / 2 }) end
    hs.eventtap.scrollWheel({ 0, -300 }, {}, "pixel")
    hs.timer.doAfter(0.5, function()
      local v2 = vsb and vsb:attributeValue("AXValue")
      local g = io.open("/tmp/ax_probe.txt", "a")
      g:write("值2(滚动后)=" .. tostring(v2) .. "\n")
      g:write(v1 ~= v2 and "✅ 滚动位置可读且会变化 → 方案②可行\n" or "❌ 读不到/不变 → 方案②对此App不可行\n")
      g:close()
    end)
  else
    f:write("❌ 没找到可读的滚动区域\n")
  end
  f:close()
end)
hs.urlevent.bind("captest", function()
  local f = io.open("/tmp/hs_diag.txt", "w")
  local win = hs.window.focusedWindow()
  f:write("focusedWindow=" .. tostring(win) .. "\n")
  if win then local fr = win:frame(); f:write(string.format("appname=%s frame=%d,%d,%d,%d\n",
      (win:application() and win:application():name()) or "?", fr.x, fr.y, fr.w, fr.h)) end
  local s = hs.screen.mainScreen():fullFrame()
  f:write(string.format("mainScreen=%d,%d,%d,%d screens=%d\n", s.x, s.y, s.w, s.h, #hs.screen.allScreens()))
  f:close()
  hs.task.new("/usr/sbin/screencapture", function(c, o, e)
    local g = io.open("/tmp/hs_diag.txt", "a"); g:write("FULLcap exit=" .. tostring(c) .. " err=" .. tostring(e) .. "\n"); g:close()
  end, { "-x", "-t", "tiff", "/tmp/hs_captest.tiff" }):start()
  hs.task.new("/usr/sbin/screencapture", function(c, o, e)
    local g = io.open("/tmp/hs_diag.txt", "a"); g:write("REGIONcap exit=" .. tostring(c) .. " err=" .. tostring(e) .. "\n"); g:close()
  end, { "-x", "-t", "tiff", "-R100,100,500,400", "/tmp/hs_captest_r.tiff" }):start()
end)

hs.alert.show("本地 AI 工具集 已加载 ✅")
