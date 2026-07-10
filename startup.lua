-- AE2 Crafting Monitor for CC:Tweaked + Advanced Peripherals
-- Requires an Advanced Peripherals ME Bridge on the AE2 network.
-- Install as startup.lua on the ComputerCraft computer.

local bridge = peripheral.find("me_bridge")
if not bridge then error("No me_bridge found. Attach an Advanced Peripherals ME Bridge.") end

local VERSION = "2026-07-10.4"
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
if #monitorTargets == 0 then monitorTargets[1] = {name = "terminal", device = term.current()} end

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

local function bridgeCall(name, default, ...)
  local fn = bridge[name]
  if type(fn) ~= "function" then return default end
  local ok, result = pcall(fn, ...)
  if ok and result ~= nil then return result end
  return default
end

local function callAny(names, default, ...)
  for _, name in ipairs(names) do
    local fn = bridge[name]
    if type(fn) == "function" then
      local ok, result = pcall(fn, ...)
      if ok and result ~= nil then return result end
    end
  end
  return default
end

local function method(obj, names, default)
  if type(obj) ~= "table" then return default end
  for _, name in ipairs(names) do
    local fn = obj[name]
    if type(fn) == "function" then
      local ok, result = pcall(fn)
      if ok and result ~= nil then return result end
      ok, result = pcall(fn, obj)
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

local function itemLabel(item)
  if type(item) ~= "table" then return nil end
  return item.displayName or item.display_name or item.label or item.name or item.id or item.fingerprint
end

local function itemCount(item)
  if type(item) ~= "table" then return 0 end
  return n(item.amount or item.count or item.qty or item.quantity)
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

local function fieldString(value, keys)
  if type(value) ~= "table" then return nil end
  for _, key in ipairs(keys) do
    local found = value[key]
    if type(found) == "string" and found ~= "" then return found end
    if type(found) == "table" then
      local nested = itemLabel(found) or fieldString(found, keys)
      if nested then return nested end
    end
  end
  return nil
end

local function fieldNumber(value, keys)
  if type(value) ~= "table" then return 0 end
  for _, key in ipairs(keys) do
    local found = value[key]
    if n(found) > 0 then return n(found) end
    if type(found) == "table" then
      local nested = fieldNumber(found, keys)
      if nested > 0 then return nested end
    end
  end
  return 0
end

local function resourceFor(task, job)
  if type(task) == "table" then
    if type(task.resource) == "table" then return task.resource end
    if type(task.finalOutput) == "table" then return task.finalOutput end
    if type(task.output) == "table" then return task.output end
    if type(task.item) == "table" then return task.item end
  end
  local fromJob = method(job, {"getFinalOutput", "getRequestedItem"}, nil)
  if type(fromJob) == "table" then return fromJob end
  return nil
end

local function stackLabel(stack)
  if type(stack) ~= "table" then return nil end
  return itemLabel(stack) or fieldString(stack, {"displayName", "display_name", "label", "name", "id", "fingerprint"}) or nil
end

local function stackAmount(stack)
  if type(stack) ~= "table" then return 0 end
  return n(stack.amount or stack.count or stack.qty or stack.quantity or stack.size or stack.total or stack.remaining)
end

local function completionFractionFor(job, parentRow)
  if type(parentRow) == "table" then
    local completion = n(parentRow.completion)
    if completion > 0 and completion <= 1 then return completion end
    local total = n(parentRow.total)
    local progress = n(parentRow.progress)
    if total > 0 and progress > 0 then
      return math.max(0, math.min(1, progress / total))
    end
  end
  local total = n(method(job, {"getTotalItems"}, 0))
  if total > 0 then
    local progress = n(method(job, {"getItemProgress"}, 0))
    if progress > 0 then return math.max(0, math.min(1, progress / total)) end
  end
  return 0
end

local function addDetailRows(job, parentRow, rows, seen, source)
  if type(job) ~= "table" then return end
  local detailMethods = {{"getUsedItems", "used"}, {"getMissingItems", "missing"}, {"getEmittedItems", "emitted"}}
  for _, entry in ipairs(detailMethods) do
    local methodName, kind = entry[1], entry[2]
    local detail = method(job, {methodName}, nil)
    if type(detail) == "table" then
      for _, stack in pairs(detail) do
        local label = stackLabel(stack)
        local amount = stackAmount(stack)
        if label and amount > 0 then
          local completion = completionFractionFor(job, parentRow)
          local remaining = math.max(0, amount * (1 - completion))
          local progress = math.max(0, amount * completion)
          local itemId = tostring((parentRow and parentRow.id or "job") .. ":" .. (stack.fingerprint or stack.name or stack.id or label) .. ":" .. kind)
          if not seen[itemId] then
            seen[itemId] = true
            rows[#rows + 1] = {
              id = itemId,
              label = cleanLabel(label),
              amount = remaining,
              total = amount,
              progress = progress,
              completion = completion,
              source = source or kind
            }
          end
        end
      end
    end
  end
end

local function buildTaskRowsForTask(key, task, source)
  if task == nil then return {} end
  local job = type(task) == "table" and (task.craftingJob or task.job or task.craftJob) or nil
  if not job and type(task) == "table" then job = task end

  local baseRow = taskFromObject(key, task, source)
  if not baseRow then return {} end

  local rows = {baseRow}
  local seen = {[baseRow.id] = true}
  addDetailRows(job, baseRow, rows, seen, source)
  return rows
end

local function taskFromObject(key, task, source)
  if task == nil then return nil end
  local job = type(task) == "table" and (task.craftingJob or task.job or task.craftJob) or nil
  if not job and type(task) == "table" then job = task end

  local total = fieldNumber(task, {"quantity", "total", "totalItems", "requested", "amount", "count"})
  local progress = fieldNumber(task, {"crafted", "progress", "itemProgress", "emitted"})
  local completion = type(task) == "table" and n(task.completion) or 0

  local jobTotal = n(method(job, {"getTotalItems"}, 0))
  local jobProgress = n(method(job, {"getItemProgress"}, 0))
  if jobTotal > 0 then total = jobTotal end
  if jobProgress > 0 then progress = jobProgress end

  local remaining = fieldNumber(task, {"remaining", "missing", "needed", "toCraft"})
  if remaining <= 0 and total > 0 then
    if progress > 0 then
      remaining = math.max(0, total - progress)
    elseif completion > 0 and completion <= 1 then
      remaining = math.max(0, total * (1 - completion))
    else
      remaining = total
    end
  end

  local resource = resourceFor(task, job)
  local label = itemLabel(resource) or fieldString(task, {
    "displayName", "display_name", "label", "name", "id", "fingerprint"
  }) or tostring(key)
  local id = tostring(
    (type(task) == "table" and (task.bridge_id or task.id)) or
    method(job, {"getId"}, nil) or
    (type(resource) == "table" and (resource.fingerprint or resource.name or resource.id)) or
    key
  )

  if method(job, {"isDone"}, false) or method(job, {"isCanceled"}, false) then return nil end
  if type(task) == "number" or type(task) == "string" then
    local fetched = bridgeCall("getCraftingTask", nil, task) or bridgeCall("getCraftingJob", nil, task)
    if fetched then return taskFromObject(task, fetched, source) end
  end

  return {
    id = id,
    label = cleanLabel(label),
    amount = remaining,
    total = total,
    progress = progress,
    completion = completion,
    source = source or "task"
  }
end

local function flattenTasks(tasks, cpus)
  local flat = {}
  local seen = {}

  for key, task in pairs(tasks or {}) do
    for _, row in ipairs(buildTaskRowsForTask(key, task, "task")) do
      if row and not seen[row.id] then
        seen[row.id] = true
        flat[#flat + 1] = row
      end
    end
  end

  for key, cpu in pairs(cpus or {}) do
    if type(cpu) == "table" and (cpu.isBusy or cpu.busy or cpu.active or cpu.crafting) and type(cpu.craftingJob) == "table" then
      for _, row in ipairs(buildTaskRowsForTask(key, cpu.craftingJob, "cpu")) do
        if row and not seen[row.id] then
          seen[row.id] = true
          flat[#flat + 1] = row
        end
      end
    end
  end

  return flat
end

local function flattenCpus(cpus)
  local flat = {}
  for key, cpu in pairs(cpus or {}) do
    if type(cpu) == "table" then
      local busy = cpu.isBusy or cpu.busy or cpu.active or cpu.crafting
      if busy == nil then busy = cpu.craftingJob end
      local resource = type(cpu.craftingJob) == "table" and resourceFor(cpu.craftingJob, cpu.craftingJob) or nil
      local label = itemLabel(resource) or fieldString(cpu, {"displayName", "name", "finalOutput", "output", "item", "id"}) or ("CPU " .. tostring(key))
      flat[#flat + 1] = {
        id = tostring(cpu.name or cpu.id or key),
        label = cleanLabel(label),
        busy = busy and true or false
      }
    end
  end
  return flat
end

local state = {tasks = {}, selectedId = nil, lastProgressAt = now()}

local function updateState(tasks, sampleTime)
  local active = {}
  for _, task in ipairs(tasks or {}) do
    if type(task) == "table" then
      local id = task.id
      active[id] = true
      local old = state.tasks[id]
    if not old then
      old = {firstSeen = sampleTime, lastSeen = sampleTime, lastAmount = task.amount, lastProgress = sampleTime, rate = 0}
    else
      local delta = n(old.lastAmount) - n(task.amount)
      local elapsed = math.max(1, sampleTime - n(old.lastSeen))
      if delta > 0 then
        local instant = delta / elapsed
        old.rate = n(old.rate) > 0 and ((old.rate * 0.65) + (instant * 0.35)) or instant
        old.lastProgress = sampleTime
        state.lastProgressAt = sampleTime
      elseif n(task.progress) > n(old.lastProgressValue) then
        local instant = (n(task.progress) - n(old.lastProgressValue)) / elapsed
        old.rate = n(old.rate) > 0 and ((old.rate * 0.65) + (instant * 0.35)) or instant
        old.lastProgress = sampleTime
        state.lastProgressAt = sampleTime
      end
      old.lastAmount = task.amount
      old.lastSeen = sampleTime
    end
      old.label = task.label
      old.amount = task.amount
      old.total = task.total
      old.progress = task.progress
      old.completion = task.completion
      old.source = task.source
      old.lastProgressValue = task.progress
      state.tasks[id] = old
    end
  end

  for id, tracked in pairs(state.tasks) do
    if not active[id] and sampleTime - n(tracked.lastSeen) > DONE_GRACE_SECONDS then
      state.tasks[id] = nil
      if state.selectedId == id then state.selectedId = nil end
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
      total = n(task.total),
      progress = n(task.progress),
      completion = n(task.completion),
      rate = n(task.rate),
      firstSeen = n(task.firstSeen),
      lastProgress = n(task.lastProgress),
      source = task.source or "task"
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
    for _, row in ipairs(rows) do if row.id == state.selectedId then return row end end
  end
  local selected = rows[1]
  state.selectedId = selected and selected.id or nil
  return selected
end

local function etaFor(row, sampleTime)
  if not row then return nil end
  if row.amount and row.amount > 0 and row.rate and row.rate > 0 then
    return row.amount / row.rate
  end
  local elapsed = sampleTime and math.max(1, sampleTime - n(row.firstSeen)) or nil
  local progress = n(row.progress)
  local total = n(row.total)
  if elapsed and elapsed > 0 and progress > 0 and total > 0 and progress < total then
    local rate = progress / elapsed
    if rate > 0 then
      return math.max(0, (total - progress) / rate)
    end
  end
  if elapsed and elapsed > 0 and row.amount and row.amount > 0 and row.progress and row.progress > 0 then
    local rate = row.progress / elapsed
    if rate > 0 then
      return row.amount / rate
    end
  end
  return nil
end

local function bestEta(rows, sampleTime)
  if not rows then return nil end
  for _, row in ipairs(rows) do
    local eta = etaFor(row, sampleTime)
    if eta then return eta, row end
  end
  return nil
end

local function progressRows(rows)
  local moving = {}
  for _, row in ipairs(rows) do if row.rate > 0 then moving[#moving + 1] = row end end
  table.sort(moving, function(a, b) return a.rate > b.rate end)
  return moving
end

local function draw(selected, rows, moving, cpus, rawTaskCount, sampleTime)
  for _, target in ipairs(monitorTargets) do
    mon = target.device
    mon.setBackgroundColor(colors.black)
    mon.clear()
    local w, h = mon.getSize()
    local busyCpus = 0
    for _, cpu in ipairs(cpus or {}) do if type(cpu) == "table" and cpu.busy then busyCpus = busyCpus + 1 end end

    clearLine(1, colors.cyan)
    writeAt(2, 1, "AE2 CRAFTING MONITOR", colors.black, colors.cyan, w - 20)
    writeAt(math.max(1, w - 11), 1, "v" .. VERSION, colors.black, colors.cyan, 11)

    if not selected then
      clearLine(3, colors.gray)
      writeAt(2, 3, "No active crafting task", colors.black, colors.gray, w - 2)
      writeAt(2, 5, "Raw tasks " .. rawTaskCount .. "  CPUs " .. busyCpus .. "/" .. #cpus, colors.lightGray, colors.black, w - 2)
      writeAt(2, 7, "If a craft is running, check bridge API version", colors.gray, colors.black, w - 2)
    else
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
      writeAt(31, 6, "TP/s", colors.lightGray, colors.black, 6)
      writeAt(38, 6, fmtRate(selected.rate), colors.white, colors.black, 14)

      writeAt(2, 7, "Age", colors.lightGray, colors.black, 10)
      writeAt(13, 7, fmtDuration(age), colors.white, colors.black, 16)
      writeAt(31, 7, "CPUs " .. busyCpus .. "/" .. #cpus .. "  Jobs " .. #rows .. "  Raw " .. rawTaskCount, colors.lightGray, colors.black, w - 31)

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
          writeAt(2, y, row.label, row.id == selected.id and colors.white or colors.lightGray, colors.black, math.max(8, w - 36))
          writeAt(math.max(1, w - 32), y, fmtAmount(row.amount), colors.yellow, colors.black, 8)
          writeAt(math.max(1, w - 20), y, fmtRate(row.rate), colors.cyan, colors.black, 10)
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
  local rawTasks = callAny({"getCraftingTasks", "listCraftingTasks"}, {}) or {}
  local rawCpus = callAny({"getCraftingCPUs", "listCraftingCPUs"}, {}) or {}
  local cpus = flattenCpus(rawCpus)
  local tasks = flattenTasks(rawTasks, rawCpus)
  updateState(tasks, sampleTime)
  local rows = taskRows()
  local selected = selectOldest(rows)
  draw(selected, rows, progressRows(rows), cpus, countTable(rawTasks), sampleTime)
  sleep(POLL_SECONDS)
end
