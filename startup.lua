-- AE2 Crafting Monitor for CC:Tweaked + Advanced Peripherals
-- Requires an Advanced Peripherals ME Bridge on the AE2 network.
-- Install as startup.lua on the ComputerCraft computer.

local bridge = peripheral.find("me_bridge")
if not bridge then error("No me_bridge found. Attach an Advanced Peripherals ME Bridge.") end

local VERSION = "2026-07-09.1"
local POLL_SECONDS = 3
local STALL_SECONDS = 90
local DONE_GRACE_SECONDS = 20
local MAX_PROCESSING_ROWS = 7

local monitorTargets = {}
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "monitor" then
    local device = peripheral.wrap(name)
    if device then
      if device.setTextScale then
        device.setTextScale(1)
        local mw, mh = device.getSize()
        if mw < 48 or mh < 16 then device.setTextScale(0.5) end
      end
      monitorTargets[#monitorTargets + 1] = {name = name, device = device}
    end
  end
end

if #monitorTargets == 0 then
  monitorTargets[1] = {name = "terminal", device = term.current()}
end

local mon = monitorTargets[1].device

local function now()
  return os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
end

local function n(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) or 0 end
  return 0
end

local function countTable(value)
  local count = 0
  for _ in pairs(value or {}) do count = count + 1 end
  return count
end

local function callAny(names, default)
  for _, name in ipairs(names) do
    local fn = bridge[name]
    if type(fn) == "function" then
      local ok, result = pcall(fn)
      if ok and result ~= nil then return result end
    end
  end
  return default
end

local function fmtAmount(value)
  value = n(value)
  if value >= 1000000000 then return string.format("%.1fB", value / 1000000000) end
  if value >= 1000000 then return string.format("%.1fM", value / 1000000) end
  if value >= 10000 then return string.format("%.0fk", value / 1000) end
  if value >= 1000 then return string.format("%.1fk", value / 1000) end
  return tostring(math.floor(value))
end

local function fmtRate(value)
  value = n(value)
  if value <= 0 then return "?" end
  if value >= 100 then return string.format("%.0f/s", value) end
  if value >= 10 then return string.format("%.1f/s", value) end
  return string.format("%.2f/s", value)
end

local function fmtDuration(seconds)
  seconds = math.max(0, math.floor(n(seconds) + 0.5))
  if seconds <= 0 then return "now" end
  local days = math.floor(seconds / 86400)
  seconds = seconds % 86400
  local hours = math.floor(seconds / 3600)
  seconds = seconds % 3600
  local minutes = math.floor(seconds / 60)
  seconds = seconds % 60
  if days > 0 then return string.format("%dd %02dh", days, hours) end
  if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
  if minutes > 0 then return string.format("%dm %02ds", minutes, seconds) end
  return tostring(seconds) .. "s"
end

local function titleCase(text)
  return string.gsub(text, "(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. string.lower(rest)
  end)
end

local function cleanLabel(text)
  text = tostring(text or "unknown")
  text = string.gsub(text, "^item%.", "")
  text = string.gsub(text, "^block%.", "")
  text = string.gsub(text, "^fluid%.", "")
  if string.find(text, ":", 1, true) and not string.find(text, " ", 1, true) then
    text = string.match(text, ":(.+)$") or text
  end
  text = string.gsub(text, "[_%.]+", " ")
  text = string.gsub(text, "%s+", " ")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then text = "unknown" end
  if not string.find(text, "%u") then text = titleCase(text) end
  return text
end

local function setColors(fg, bg)
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
end

local function clearLine(y, bg)
  local w = mon.getSize()
  mon.setCursorPos(1, y)
  setColors(colors.white, bg or colors.black)
  mon.write(string.rep(" ", w))
end

local function writeAt(x, y, text, fg, bg, maxLen)
  local w = mon.getSize()
  if x > w then return end
  text = tostring(text or "")
  if maxLen then text = string.sub(text, 1, maxLen) end
  mon.setCursorPos(x, y)
  setColors(fg, bg)
  mon.write(string.sub(text, 1, math.max(0, w - x + 1)))
end

local function fillRect(x, y, rw, rh, bg)
  local w, h = mon.getSize()
  setColors(colors.white, bg)
  for yy = y, math.min(h, y + rh - 1) do
    if yy >= 1 then
      mon.setCursorPos(x, yy)
      mon.write(string.rep(" ", math.max(0, math.min(rw, w - x + 1))))
    end
  end
end

local function firstString(value, keys)
  if type(value) ~= "table" then return nil end
  for _, key in ipairs(keys) do
    local found = value[key]
    if type(found) == "string" and found ~= "" then return found end
    if type(found) == "table" then
      local nested = firstString(found, keys)
      if nested then return nested end
    end
  end
  return nil
end

local function firstNumber(value, keys)
  if type(value) ~= "table" then return 0 end
  for _, key in ipairs(keys) do
    local found = value[key]
    if n(found) > 0 then return n(found) end
    if type(found) == "table" then
      local nested = firstNumber(found, keys)
      if nested > 0 then return nested end
    end
  end
  return 0
end

local function flattenTasks(tasks)
  local flat = {}
  for key, task in pairs(tasks or {}) do
    if type(task) == "table" then
      local id = tostring(
        task.id or task.name or task.displayName or task.fingerprint or task.item or
        task.output or task.result or task.toCraft or key
      )
      local label = firstString(task, {
        "displayName", "display_name", "label", "name", "id", "fingerprint"
      }) or id
      local amount = firstNumber(task, {
        "remaining", "amount", "count", "qty", "quantity", "requested",
        "toCraft", "missing", "needed", "total"
      })
      flat[#flat + 1] = {
        id = id,
        label = cleanLabel(label),
        amount = amount,
        raw = task
      }
    elseif type(task) == "string" then
      flat[#flat + 1] = {id = task, label = cleanLabel(task), amount = 0, raw = task}
    end
  end
  return flat
end

local function flattenCpus(cpus)
  local flat = {}
  for key, cpu in pairs(cpus or {}) do
    if type(cpu) == "table" then
      local busy = cpu.busy or cpu.isBusy or cpu.active or cpu.crafting
      if busy == nil then busy = cpu.finalOutput or cpu.output or cpu.item end
      local label = firstString(cpu, {
        "displayName", "name", "finalOutput", "output", "item", "id"
      }) or ("CPU " .. tostring(key))
      flat[#flat + 1] = {
        id = tostring(cpu.name or cpu.id or key),
        label = cleanLabel(label),
        busy = busy and true or false
      }
    end
  end
  return flat
end

local state = {
  tasks = {},
  selectedId = nil,
  selectedDoneAt = 0,
  lastProgressAt = now()
}

local function updateState(tasks, sampleTime)
  local active = {}

  for _, task in ipairs(tasks) do
    local id = task.id
    active[id] = true
    local old = state.tasks[id]
    if not old then
      old = {
        firstSeen = sampleTime,
        lastSeen = sampleTime,
        lastAmount = task.amount,
        lastProgress = sampleTime,
        rate = 0,
        maxAmount = task.amount
      }
    else
      local delta = n(old.lastAmount) - n(task.amount)
      local elapsed = math.max(1, sampleTime - n(old.lastSeen))
      if delta > 0 then
        local instant = delta / elapsed
        if n(old.rate) > 0 then
          old.rate = (old.rate * 0.65) + (instant * 0.35)
        else
          old.rate = instant
        end
        old.lastProgress = sampleTime
        state.lastProgressAt = sampleTime
      elseif task.amount > n(old.maxAmount) then
        old.maxAmount = task.amount
      end
      old.lastAmount = task.amount
      old.lastSeen = sampleTime
    end
    old.label = task.label
    old.amount = task.amount
    state.tasks[id] = old
  end

  for id, tracked in pairs(state.tasks) do
    if not active[id] and sampleTime - n(tracked.lastSeen) > DONE_GRACE_SECONDS then
      state.tasks[id] = nil
      if state.selectedId == id then
        state.selectedId = nil
        state.selectedDoneAt = sampleTime
      end
    end
  end
end

local function taskRows()
  local rows = {}
  for id, task in pairs(state.tasks) do
    rows[#rows + 1] = {
      id = id,
      label = task.label or id,
      amount = n(task.amount),
      rate = n(task.rate),
      firstSeen = n(task.firstSeen),
      lastProgress = n(task.lastProgress)
    }
  end
  table.sort(rows, function(a, b)
    if a.firstSeen ~= b.firstSeen then return a.firstSeen < b.firstSeen end
    return a.label < b.label
  end)
  return rows
end

local function selectOldest(rows)
  if state.selectedId then
    for _, row in ipairs(rows) do
      if row.id == state.selectedId then return row end
    end
  end
  local selected = rows[1]
  state.selectedId = selected and selected.id or nil
  return selected
end

local function etaFor(selected, rows)
  if not selected then return nil, 0, 0 end
  local dependencySeconds = 0
  local dependencyRemaining = 0
  local selectedSeconds = nil

  for _, row in ipairs(rows) do
    if row.id == selected.id then
      if row.amount > 0 and row.rate > 0 then selectedSeconds = row.amount / row.rate end
    elseif row.amount > 0 then
      dependencyRemaining = dependencyRemaining + row.amount
      if row.rate > 0 then dependencySeconds = dependencySeconds + (row.amount / row.rate) end
    end
  end

  if selectedSeconds then
    return dependencySeconds + selectedSeconds, dependencySeconds, dependencyRemaining
  end
  if dependencySeconds > 0 then
    return dependencySeconds, dependencySeconds, dependencyRemaining
  end
  return nil, dependencySeconds, dependencyRemaining
end

local function progressRows(rows)
  local moving = {}
  for _, row in ipairs(rows) do
    if row.rate > 0 then moving[#moving + 1] = row end
  end
  table.sort(moving, function(a, b) return a.rate > b.rate end)
  return moving
end

local function draw(selected, rows, moving, cpus, sampleTime)
  for _, target in ipairs(monitorTargets) do
    mon = target.device
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local w, h = mon.getSize()
    local busyCpus = 0
    for _, cpu in ipairs(cpus) do if cpu.busy then busyCpus = busyCpus + 1 end end

    clearLine(1, colors.cyan)
    writeAt(2, 1, "AE2 CRAFTING MONITOR", colors.black, colors.cyan, w - 20)
    writeAt(math.max(1, w - 11), 1, "v" .. VERSION, colors.black, colors.cyan, 11)

    if not selected then
      clearLine(3, colors.gray)
      writeAt(2, 3, "No active crafting task", colors.black, colors.gray, w - 2)
      writeAt(2, 5, "CPUs busy: " .. busyCpus .. "/" .. countTable(cpus), colors.lightGray, colors.black, w - 2)
      writeAt(2, 7, "Waiting for AE2 crafting tasks...", colors.gray, colors.black, w - 2)
    else

    local eta, dependencySeconds, dependencyRemaining = etaFor(selected, rows)
    local stalled = sampleTime - n(state.lastProgressAt) >= STALL_SECONDS
    local age = sampleTime - selected.firstSeen
    local statusColor = stalled and colors.red or colors.green
    local statusText = stalled and ("POSSIBLE STALL " .. fmtDuration(sampleTime - state.lastProgressAt)) or "CRAFTING"

    clearLine(3, statusColor)
    writeAt(2, 3, statusText, stalled and colors.white or colors.black, statusColor, w - 2)

    writeAt(2, 5, "Task", colors.lightGray, colors.black, 10)
    writeAt(13, 5, selected.label, colors.white, colors.black, w - 13)

    writeAt(2, 6, "Left", colors.lightGray, colors.black, 10)
    writeAt(13, 6, fmtAmount(selected.amount), colors.white, colors.black, 16)
    writeAt(31, 6, "Rate", colors.lightGray, colors.black, 6)
    writeAt(38, 6, fmtRate(selected.rate), colors.white, colors.black, 14)

    writeAt(2, 7, "ETA", colors.lightGray, colors.black, 10)
    if eta then
      writeAt(13, 7, fmtDuration(eta), colors.yellow, colors.black, 16)
      if dependencyRemaining > 0 and dependencySeconds > 0 then
        writeAt(31, 7, "includes " .. fmtDuration(dependencySeconds) .. " before task", colors.orange, colors.black, w - 31)
      end
    else
      writeAt(13, 7, "learning...", colors.yellow, colors.black, 16)
      if dependencyRemaining > 0 then
        writeAt(31, 7, fmtAmount(dependencyRemaining) .. " items ahead/alongside", colors.orange, colors.black, w - 31)
      end
    end

    writeAt(2, 8, "Age", colors.lightGray, colors.black, 10)
    writeAt(13, 8, fmtDuration(age), colors.white, colors.black, 16)
    writeAt(31, 8, "CPUs " .. busyCpus .. "/" .. countTable(cpus) .. "  Jobs " .. #rows, colors.lightGray, colors.black, w - 31)

    fillRect(1, 10, w, 1, colors.gray)
    writeAt(2, 10, "CURRENTLY PROCESSING", colors.black, colors.gray, w - 2)

    local y = 11
    if #moving == 0 then
      clearLine(y, colors.black)
      writeAt(2, y, stalled and "No measured progress from AE task counts" or "Waiting for count movement...", colors.lightGray, colors.black, w - 2)
      y = y + 1
    else
      for i = 1, math.min(#moving, MAX_PROCESSING_ROWS, h - y + 1) do
        local row = moving[i]
        clearLine(y, colors.black)
        writeAt(2, y, row.label, row.id == selected.id and colors.white or colors.lightGray, colors.black, math.max(8, w - 27))
        writeAt(math.max(1, w - 24), y, fmtAmount(row.amount), colors.yellow, colors.black, 10)
        writeAt(math.max(1, w - 12), y, fmtRate(row.rate), colors.cyan, colors.black, 12)
        y = y + 1
      end
    end

    if y <= h then
      fillRect(1, y, w, 1, colors.gray)
      writeAt(2, y, "ACTIVE CRAFTING CPUS", colors.black, colors.gray, w - 2)
      y = y + 1
      local shown = 0
      for _, cpu in ipairs(cpus) do
        if cpu.busy and y <= h then
          clearLine(y, colors.black)
          writeAt(2, y, cpu.label, colors.lightGray, colors.black, w - 2)
          y = y + 1
          shown = shown + 1
        end
      end
      if shown == 0 and y <= h then
        clearLine(y, colors.black)
        writeAt(2, y, "No busy CPU detail exposed", colors.gray, colors.black, w - 2)
      end
    end
    end
  end
end

while true do
  local sampleTime = now()
  local tasks = flattenTasks(callAny({"getCraftingTasks", "listCraftingTasks"}, {}) or {})
  local cpus = flattenCpus(callAny({"getCraftingCPUs", "listCraftingCPUs"}, {}) or {})
  updateState(tasks, sampleTime)
  local rows = taskRows()
  local selected = selectOldest(rows)
  draw(selected, rows, progressRows(rows), cpus, sampleTime)
  sleep(POLL_SECONDS)
end
