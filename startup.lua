-- AE2 Visual Monitor for CC:Tweaked + Advanced Peripherals
-- Requires an Advanced Peripherals ME Bridge on the AE2 network.
-- Install as startup.lua on the ComputerCraft computer.

local bridge = peripheral.find("me_bridge")
if not bridge then error("No me_bridge found. Attach an Advanced Peripherals ME Bridge.") end

local monitorTargets = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    local device = peripheral.wrap(name)
    if device then
      if device.setTextScale then device.setTextScale(0.5) end
      monitorTargets[#monitorTargets + 1] = {name = name, device = device}
    end
  end
end
if #monitorTargets == 0 then
  monitorTargets[1] = {name = "terminal", device = term.current()}
end

local mon = monitorTargets[1].device

local VERSION = "2026-06-29.7"
local STATE_VERSION = 2
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
local STATE_FILE = ".ae2_usage_state"
local SAMPLE_SECONDS = 90
local WARMUP_SAMPLES = 3
local MIN_REAL_DROP = 512
local RECENT_DROP = 64
local CONSUMED_WATCH = 2048
local DROP_EVENTS_REQUIRED = 2
local LOW_STOCK = 4096
local FAST_DROP = 1024

local function call(name, default)
  local f = bridge[name]
  if type(f) ~= "function" then return default end
  local ok, result = pcall(f)
  if ok and result ~= nil then return result end
  return default
end

local function callAny(names, default)
  for _, name in ipairs(names) do
    local f = bridge[name]
    if type(f) == "function" then
      local ok, result = pcall(f)
      if ok and result ~= nil then return result end
    end
  end
  return default
end

local function n(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then return tonumber(v) or 0 end
  return 0
end

local function countTable(t)
  local c = 0
  for _ in pairs(t or {}) do c = c + 1 end
  return c
end

local function fmt(v)
  v = n(v)
  if v >= 1000000000 then return string.format("%.1fB", v / 1000000000) end
  if v >= 1000000 then return string.format("%.1fM", v / 1000000) end
  if v >= 1000 then return string.format("%.1fk", v / 1000) end
  return tostring(math.floor(v))
end

local function pct(used, total)
  used, total = n(used), n(total)
  if total <= 0 then return 0 end
  return math.max(0, math.min(100, (used / total) * 100))
end

local function amountOf(item)
  return n(item.amount or item.count or item.qty or item.size)
end

local function itemKey(item)
  return tostring(item.name or item.id or item.displayName or "unknown")
end

local function itemLabel(item)
  return tostring(item.displayName or item.name or item.id or "unknown")
end

local function set(fg, bg)
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
end

local function clearLine(y, bg)
  local w = mon.getSize()
  mon.setCursorPos(1, y)
  set(colors.white, bg or colors.black)
  mon.write(string.rep(" ", w))
end

local function writeAt(x, y, text, fg, bg, maxLen)
  local w = mon.getSize()
  if x > w then return end
  if maxLen then text = string.sub(text, 1, maxLen) end
  mon.setCursorPos(x, y)
  set(fg, bg)
  mon.write(string.sub(text, 1, math.max(0, w - x + 1)))
end

local function fillRect(x, y, rw, rh, bg)
  local w, h = mon.getSize()
  set(colors.white, bg)
  for yy = y, math.min(h, y + rh - 1) do
    if yy >= 1 then
      mon.setCursorPos(x, yy)
      mon.write(string.rep(" ", math.max(0, math.min(rw, w - x + 1))))
    end
  end
end

local function tile(x, y, w, title, value, sub, bg)
  fillRect(x, y, w, 3, bg)
  writeAt(x + 1, y, title, colors.black, bg, w - 2)
  writeAt(x + 1, y + 1, value, colors.white, bg, w - 2)
  writeAt(x + 1, y + 2, sub, colors.lightGray, bg, w - 2)
end

local function bar(x, y, w, label, used, total, color)
  local p = pct(used, total)
  local fill = math.floor((p / 100) * w + 0.5)
  writeAt(x, y, string.sub(label, 1, 8), colors.lightGray, colors.black, 8)
  fillRect(x + 9, y, w, 1, colors.gray)
  fillRect(x + 9, y, fill, 1, color)
  writeAt(x + 10 + w, y, string.format("%3d%%", math.floor(p + 0.5)), colors.white, colors.black, 4)
end

local function typeSlots(cells)
  local itemCells, fluidCells = 0, 0
  for _, cell in pairs(cells or {}) do
    local info = ""
    for k, v in pairs(cell) do
      if type(v) == "string" or type(v) == "number" then
        info = info .. " " .. tostring(k) .. "=" .. tostring(v)
      end
    end
    info = info:lower()
    if string.find(info, "fluid") or string.find(info, "chemical") then
      fluidCells = fluidCells + 1
    elseif string.find(info, "item") or string.find(info, "storage") or info ~= "" then
      itemCells = itemCells + 1
    end
  end
  return itemCells * 63, fluidCells * 63, itemCells, fluidCells
end

local function loadState()
  if not fs.exists(STATE_FILE) then return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0} end
  local h = fs.open(STATE_FILE, "r")
  if not h then return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0} end
  local raw = h.readAll()
  h.close()
  local ok, data = pcall(textutils.unserialize, raw)
  if ok and type(data) == "table" then
    if data.stateVersion ~= STATE_VERSION then
      return {last = {}, tracked = {}, warnings = {}, ignored = data.ignored or {}, stateVersion = STATE_VERSION, lastSample = 0}
    end
    data.last = data.last or {}
    data.tracked = data.tracked or {}
    data.warnings = data.warnings or {}
    data.recent = data.recent or {}
    data.ignored = data.ignored or {}
    data.lastSample = data.lastSample or 0
    return data
  end
  return {last = {}, tracked = {}, warnings = {}, ignored = {}, stateVersion = STATE_VERSION, lastSample = 0}
end

local function saveState(state)
  local h = fs.open(STATE_FILE, "w")
  if not h then return end
  h.write(textutils.serialize(state))
  h.close()
end

local usageState = loadState()
local warningButtons = {}
local updateButtons = {}
local statusMessage = nil
local statusUntil = 0

local function filteredWarnings(warnings)
  local filtered = {}
  for _, warning in ipairs(warnings or {}) do
    if not usageState.ignored[warning.key] then
      filtered[#filtered + 1] = warning
    end
  end
  return filtered
end

local function ignoreWarningAt(screen, x, y)
  for _, button in ipairs(warningButtons[screen] or {}) do
    if y == button.y and x >= button.x and x <= button.x2 then
      usageState.ignored[button.key] = button.name or true
      usageState.tracked[button.key] = nil
      usageState.warnings = filteredWarnings(usageState.warnings)
      saveState(usageState)
      return true
    end
  end
  return false
end

local function setStatus(message)
  statusMessage = message
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  statusUntil = now + 8
end

local function runUpdater()
  if not http or not http.get then
    setStatus("HTTP disabled; use wget")
    return true
  end

  setStatus("Updating from GitHub...")
  local url = UPDATE_URL .. "?v=" .. tostring(os.epoch and os.epoch("utc") or os.time())
  local res = http.get(url)
  if not res then
    setStatus("Update failed")
    return true
  end
  local body = res.readAll()
  res.close()
  if not body or #body < 1000 or not string.find(body, "AE2 Visual Monitor", 1, true) then
    setStatus("Bad update file")
    return true
  end

  local h = fs.open("startup.lua", "w")
  if not h then
    setStatus("Cannot write startup.lua")
    return true
  end
  h.write(body)
  h.close()
  os.reboot()
  return true
end

local function handleTouch(screen, x, y)
  local updateButton = updateButtons[screen]
  if updateButton and y == updateButton.y and x >= updateButton.x and x <= updateButton.x2 then
    return runUpdater()
  end
  return ignoreWarningAt(screen, x, y)
end

local function updateUsage(items)
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  if usageState.lastSample and now - usageState.lastSample < SAMPLE_SECONDS then
    usageState.warnings = filteredWarnings(usageState.warnings)
    return usageState.warnings or {}, usageState.recent or {}
  end

  local current = {}
  local warnings = {}
  local recent = {}
  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local amount = amountOf(item)
    current[key] = amount
    local prior = usageState.last[key]
    local label = itemLabel(item)
    if prior and not usageState.ignored[key] then
      local tracked = usageState.tracked[key] or {name = label, consumed = 0, lastDrop = 0, left = amount, samples = 0, dropEvents = 0}
      tracked.name = label
      tracked.samples = n(tracked.samples) + 1
      tracked.left = amount
      tracked.lastSeen = now

      if amount < prior then
        local drop = prior - amount
        if drop >= RECENT_DROP then
          recent[#recent + 1] = {
            key = key,
            name = label,
            drop = drop,
            left = amount,
            score = drop
          }
        end
        if drop >= MIN_REAL_DROP then
          tracked.consumed = n(tracked.consumed) + drop
          tracked.dropEvents = n(tracked.dropEvents) + 1
          tracked.lastDrop = drop
        else
          tracked.lastDrop = 0
        end
      elseif amount > prior then
        tracked.lastDrop = 0
        tracked.dropEvents = math.max(0, n(tracked.dropEvents) - 1)
        tracked.consumed = math.floor(n(tracked.consumed) * 0.5)
      else
        tracked.lastDrop = 0
      end

      usageState.tracked[key] = tracked

      local bigDrop = n(tracked.lastDrop) >= math.max(FAST_DROP, amount * 0.10)
      local learned = n(tracked.samples) >= WARMUP_SAMPLES
      local repeatedDrops = n(tracked.dropEvents) >= DROP_EVENTS_REQUIRED
      local heavyUse = n(tracked.consumed) >= CONSUMED_WATCH
      local lowStock = amount <= LOW_STOCK
      if learned and repeatedDrops and heavyUse and (lowStock or bigDrop) then
        warnings[#warnings + 1] = {
          key = key,
          name = label,
          drop = n(tracked.lastDrop),
          left = amount,
          consumed = tracked.consumed,
          score = (lowStock and 100000000 or 0) + n(tracked.lastDrop) + tracked.consumed
        }
      end
    end
  end

  for key, tracked in pairs(usageState.tracked or {}) do
    if tracked.lastSeen and now - tracked.lastSeen > 86400 then
      usageState.tracked[key] = nil
    end
  end

  table.sort(warnings, function(a, b) return a.score > b.score end)
  table.sort(recent, function(a, b) return a.score > b.score end)
  usageState.stateVersion = STATE_VERSION
  usageState.last = current
  usageState.lastSample = now
  usageState.warnings = warnings
  usageState.recent = recent
  saveState(usageState)
  return warnings, recent
end

while true do
  local items = callAny({"listItems", "getItems"}, {}) or {}
  local fluids = callAny({"listFluid", "listFluids", "getFluids"}, {}) or {}
  local cells = callAny({"listCells", "getCells"}, {}) or {}
  local drives = call("getDrives", {}) or {}
  local cpus = call("getCraftingCPUs", {}) or {}
  local tasks = callAny({"getCraftingTasks", "listCraftingTasks"}, {}) or {}

  local itemTypes, itemCount = 0, 0
  local top = {}
  for _, item in pairs(items) do
    itemTypes = itemTypes + 1
    local a = amountOf(item)
    itemCount = itemCount + a
    top[#top + 1] = {name = itemLabel(item), amount = a}
  end
  table.sort(top, function(a, b) return a.amount > b.amount end)
  local warnings, recent = updateUsage(items)

  local fluidTypes, fluidAmount = 0, 0
  for _, fluid in pairs(fluids) do
    fluidTypes = fluidTypes + 1
    fluidAmount = fluidAmount + amountOf(fluid)
  end

  local itemUsed = call("getUsedItemStorage", itemCount)
  local itemTotal = call("getTotalItemStorage", 0)
  local fluidUsed = call("getUsedFluidStorage", fluidAmount)
  local fluidTotal = call("getTotalFluidStorage", 0)
  local energy = callAny({"getEnergyStorage", "getStoredEnergy"}, 0)
  local energyCap = callAny({"getMaxEnergyStorage", "getEnergyCapacity"}, 0)
  local usage = call("getEnergyUsage", 0)
  local input = call("getAverageEnergyInput", 0)
  local itemTypeTotal, fluidTypeTotal, itemCellCount, fluidCellCount = typeSlots(cells)

  for _, target in ipairs(monitorTargets) do
    mon = target.device
    local screen = target.name
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local w, h = mon.getSize()
    local barW = math.max(12, w - 15)
    local tileW = math.floor((w - 4) / 3)

  clearLine(1, colors.cyan)
  writeAt(2, 1, "AE2 SYSTEM", colors.black, colors.cyan)
  updateButtons[screen] = {x = math.max(1, w - 4), x2 = w, y = 1}
  writeAt(w - 4, 1, "UPD", colors.white, colors.blue, 3)
  writeAt(w - 22, 1, textutils.formatTime(os.time(), true) .. " " .. itemTypes .. "I/" .. fluidTypes .. "F", colors.black, colors.cyan, 17)

  tile(1, 3, tileW, "ITEMS", fmt(itemUsed) .. "/" .. (itemTotal > 0 and fmt(itemTotal) or "?"), fmt(itemCount) .. " stacks", colors.green)
  tile(tileW + 3, 3, tileW, "TYPES", fmt(itemTypes) .. "/" .. (itemTypeTotal > 0 and fmt(itemTypeTotal) or "?"), itemCellCount .. " item cells", colors.yellow)
  tile((tileW * 2) + 5, 3, math.max(10, w - ((tileW * 2) + 4)), "POWER", fmt(energy) .. "/" .. (energyCap > 0 and fmt(energyCap) or "?"), fmt(usage) .. "/t use " .. fmt(input) .. "/t in", colors.orange)

  bar(1, 7, barW, "Items", itemUsed, itemTotal, colors.lime)
  bar(1, 8, barW, "Types", itemTypes, itemTypeTotal, colors.yellow)
  bar(1, 10, barW, "Fluids", fluidUsed, fluidTotal, colors.blue)
  bar(1, 11, barW, "FTypes", fluidTypes, fluidTypeTotal, colors.cyan)
  bar(1, 13, barW, "Power", energy, energyCap, colors.orange)

  clearLine(15, colors.gray)
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  if statusMessage and now < statusUntil then
    writeAt(2, 15, statusMessage, colors.black, colors.gray, w - 2)
  else
    writeAt(2, 15, "v" .. VERSION .. "  CELLS " .. countTable(cells) .. "  DRIVES " .. countTable(drives) .. "  CPUs " .. countTable(cpus) .. "  JOBS " .. countTable(tasks) .. "  FLUID CELLS " .. fluidCellCount, colors.black, colors.gray)
  end

  local watchColor = colors.gray
  if #warnings > 0 then watchColor = colors.red elseif #recent > 0 then watchColor = colors.orange end
  clearLine(17, watchColor)
  if #warnings > 0 then
    writeAt(2, 17, "CONFIRMED DEPLETION WARNINGS", colors.white, colors.red)
  elseif #recent > 0 then
    writeAt(2, 17, "RECENT USE - not a warning", colors.black, colors.orange)
  else
    writeAt(2, 17, "DEPLETION WATCH: waits for repeated drops", colors.black, colors.gray)
  end

  local nextY = 18
  if #warnings > 0 then
    warningButtons[screen] = {}
    for i = 1, math.min(#warnings, 3) do
      clearLine(nextY, colors.black)
      local buttonX = math.max(1, w - 5)
      local nameW = math.max(8, w - 31)
      writeAt(1, nextY, string.sub(warnings[i].name, 1, nameW), colors.red, colors.black, nameW)
      writeAt(math.max(1, w - 24), nextY, "-" .. fmt(warnings[i].drop) .. " left " .. fmt(warnings[i].left), colors.yellow, colors.black, 18)
      fillRect(buttonX, nextY, 6, 1, colors.gray)
      writeAt(buttonX + 1, nextY, "IGN", colors.white, colors.gray, 3)
      warningButtons[screen][#warningButtons[screen] + 1] = {x = buttonX, x2 = w, y = nextY, key = warnings[i].key, name = warnings[i].name}
      nextY = nextY + 1
    end
  elseif #recent > 0 then
    warningButtons[screen] = {}
    for i = 1, math.min(#recent, 3) do
      clearLine(nextY, colors.black)
      local nameW = math.max(8, w - 22)
      writeAt(1, nextY, string.sub(recent[i].name, 1, nameW), colors.orange, colors.black, nameW)
      writeAt(math.max(1, w - 19), nextY, "-" .. fmt(recent[i].drop) .. " left " .. fmt(recent[i].left), colors.yellow, colors.black, 19)
      nextY = nextY + 1
    end
  else
    warningButtons[screen] = {}
    clearLine(nextY, colors.black)
    writeAt(1, nextY, "Warns after real count drops; resets if you delete " .. STATE_FILE, colors.lightGray, colors.black, w)
    nextY = nextY + 1
  end

  nextY = nextY + 1
  clearLine(nextY, colors.lightGray)
  writeAt(2, nextY, "TOP STORED ITEMS", colors.black, colors.lightGray)
  nextY = nextY + 1

  local maxAmt = top[1] and top[1].amount or 1
  local y = nextY
  local listRows = math.max(0, h - y + 1)
  for i = 1, math.min(#top, listRows) do
    local rowColor = colors.lime
    if i > 3 then rowColor = colors.green end
    if i > 8 then rowColor = colors.gray end
    local amount = top[i].amount
    local nameW = math.max(12, math.floor(w * 0.42))
    local miniW = math.max(8, w - nameW - 12)
    clearLine(y, colors.black)
    writeAt(1, y, string.sub(top[i].name, 1, nameW), colors.white, colors.black, nameW)
    fillRect(nameW + 2, y, miniW, 1, colors.gray)
    fillRect(nameW + 2, y, math.max(1, math.floor((amount / maxAmt) * miniW + 0.5)), 1, rowColor)
    writeAt(w - 7, y, fmt(amount), colors.white, colors.black, 8)
    y = y + 1
  end
  end

  local timer = os.startTimer(3)
  while true do
    local event, a, b, c = os.pullEvent()
    if event == "timer" and a == timer then
      break
    elseif event == "monitor_touch" and handleTouch(a, b, c) then
      break
    elseif event == "mouse_click" and handleTouch("terminal", b, c) then
      break
    end
  end
end
