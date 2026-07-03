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
      if device.setTextScale then
        device.setTextScale(1)
        local mw, mh = device.getSize()
        if mw < 42 or mh < 18 then device.setTextScale(0.5) end
      end
      monitorTargets[#monitorTargets + 1] = {name = name, device = device}
    end
  end
end
if #monitorTargets == 0 then
  monitorTargets[1] = {name = "terminal", device = term.current()}
end

local mon = monitorTargets[1].device

local VERSION = "2026-07-02.2"
local STATE_VERSION = 6
local UPDATE_URL = "https://raw.githubusercontent.com/crameep/ae2-cc-monitor/main/startup.lua"
local STATE_FILE = ".ae2_usage_state"
local BULK_HINTS_FILE = ".ae2_bulk_items"
local SAMPLE_SECONDS = 90
local WARMUP_SAMPLES = 3
local MIN_REAL_DROP = 512
local RECENT_DROP = 64
local RECENT_EVENTS_REQUIRED = 2
local RECENT_CONFIRM_SECONDS = 1800
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
  return n(item.amount or item.count or item.qty)
end

local function itemKey(item)
  return tostring(item.name or item.id or item.displayName or "unknown")
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
  return cleanLabel(item.displayName or item.name or item.id or "unknown")
end

local function norm(text)
  text = string.lower(tostring(text or ""))
  text = string.gsub(text, "^item%.", "")
  text = string.gsub(text, "^block%.", "")
  text = string.gsub(text, "^fluid%.", "")
  text = string.gsub(text, "[_%.]+", " ")
  text = string.gsub(text, "%s+", " ")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  return text
end

local function gatherText(value, depth)
  depth = depth or 0
  if depth > 4 then return "" end
  local tv = type(value)
  if tv == "string" or tv == "number" or tv == "boolean" then
    return " " .. tostring(value)
  elseif tv ~= "table" then
    return ""
  end

  local parts = {}
  for k, v in pairs(value) do
    parts[#parts + 1] = gatherText(k, depth + 1)
    parts[#parts + 1] = gatherText(v, depth + 1)
  end
  return table.concat(parts, " ")
end

local function loadBulkHints()
  local hints = {}
  if not fs.exists(BULK_HINTS_FILE) then return hints end
  local h = fs.open(BULK_HINTS_FILE, "r")
  if not h then return hints end
  local raw = h.readAll() or ""
  h.close()
  for line in string.gmatch(raw, "[^\r\n]+") do
    line = string.gsub(line, "#.*$", "")
    line = string.gsub(line, "^%s+", "")
    line = string.gsub(line, "%s+$", "")
    if line ~= "" then
      hints[norm(line)] = true
      hints[line] = true
    end
  end
  return hints
end

local function loadBulkHintLines()
  local lines = {}
  if not fs.exists(BULK_HINTS_FILE) then return lines end
  local h = fs.open(BULK_HINTS_FILE, "r")
  if not h then return lines end
  local raw = h.readAll() or ""
  h.close()
  for line in string.gmatch(raw, "[^\r\n]+") do
    local trimmed = string.gsub(line, "^%s+", "")
    trimmed = string.gsub(trimmed, "%s+$", "")
    if trimmed ~= "" then lines[#lines + 1] = trimmed end
  end
  return lines
end

local function saveBulkHintLines(lines)
  local h = fs.open(BULK_HINTS_FILE, "w")
  if not h then return false end
  for _, line in ipairs(lines or {}) do
    h.write(line .. "\n")
  end
  h.close()
  return true
end

local function toggleBulkHint(key, label)
  key = tostring(key or "")
  label = tostring(label or key)
  local keyNorm = norm(key)
  local labelNorm = norm(label)
  local lines = loadBulkHintLines()
  local kept = {}
  local removed = false

  for _, line in ipairs(lines) do
    local raw = string.gsub(line, "#.*$", "")
    raw = string.gsub(raw, "^%s+", "")
    raw = string.gsub(raw, "%s+$", "")
    local rawNorm = norm(raw)
    if rawNorm ~= "" and (rawNorm == keyNorm or rawNorm == labelNorm) then
      removed = true
    else
      kept[#kept + 1] = line
    end
  end

  if not removed then kept[#kept + 1] = key ~= "" and key or label end
  if not saveBulkHintLines(kept) then return nil end
  return not removed
end

local function isBulkCell(cell)
  local text = norm(gatherText(cell))
  return string.find(text, "bulk", 1, true)
    or string.find(text, "mega item cell", 1, true)
    or string.find(text, "mega bulk", 1, true)
    or string.find(text, "megacells:bulk", 1, true)
end

local function cellMatchesItem(cellText, item)
  local key = itemKey(item)
  local label = itemLabel(item)
  if key ~= "unknown" and string.find(cellText, norm(key), 1, true) then return true end
  local name = tostring(item.name or item.id or "")
  if name ~= "" and string.find(cellText, norm(name), 1, true) then return true end
  local fingerprint = tostring(item.fingerprint or "")
  if fingerprint ~= "" and string.find(cellText, norm(fingerprint), 1, true) then return true end
  if label ~= "unknown" and #label >= 6 and string.find(cellText, norm(label), 1, true) then return true end
  return false
end

local function buildBulkIndex(cells, items)
  local index = {}
  local bulkCells = 0
  local matched = 0
  local hints = loadBulkHints()

  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local label = itemLabel(item)
    if hints[norm(key)] or hints[key] or hints[norm(label)] then
      index[key] = "hint"
      matched = matched + 1
    end
  end

  for _, cell in pairs(cells or {}) do
    if isBulkCell(cell) then
      bulkCells = bulkCells + 1
      local text = norm(gatherText(cell))
      for _, item in pairs(items or {}) do
        local key = itemKey(item)
        if not index[key] and cellMatchesItem(text, item) then
          index[key] = "auto"
          matched = matched + 1
        end
      end
    end
  end

  return index, bulkCells, matched
end

local function shouldWatchItem(key, label)
  local text = string.lower(tostring(label or "") .. " " .. tostring(key or ""))
  if string.find(text, "spatial", 1, true) then return false end
  if string.find(text, "storage cell", 1, true) then return false end
  if string.find(text, "cell component", 1, true) then return false end
  if string.find(text, "crafting storage", 1, true) then return false end
  if string.find(text, "encoded pattern", 1, true) then return false end
  if string.find(text, "blank pattern", 1, true) then return false end
  if string.find(text, "pattern provider", 1, true) then return false end
  if string.find(text, "annihilation plane", 1, true) then return false end
  if string.find(text, "formation plane", 1, true) then return false end
  if string.find(text, "upgrade card", 1, true) then return false end
  return true
end

local function containsAny(text, needles)
  for _, needle in ipairs(needles) do
    if string.find(text, needle, 1, true) then return true end
  end
  return false
end

local function atm10StockRule(key, label, amount)
  if amount <= 0 then return nil end
  local text = string.lower(tostring(label or "") .. " " .. tostring(key or ""))
  if not shouldWatchItem(key, label) then return false end

  local rules = {
    {
      label = "ATM metals",
      max = 512,
      priority = 100,
      needles = {
        "allthemodium", "vibranium", "unobtainium", "piglich heart",
        "patrick star", "atm star", "star shard", "alloy block"
      }
    },
    {
      label = "ATM alloys",
      max = 1024,
      priority = 95,
      needles = {
        "vibranium allthemodium", "unobtainium vibranium",
        "unobtainium allthemodium", "awakened"
      }
    },
    {
      label = "Mystical tiers",
      max = 4096,
      priority = 90,
      needles = {
        "inferium", "prudentium", "tertium", "imperium", "supremium",
        "insanium", "prosperity shard", "soulium", "master infusion crystal"
      }
    },
    {
      label = "Mekanism chain",
      max = 2048,
      priority = 85,
      needles = {
        "osmium", "refined obsidian", "refined glowstone", "fluorite",
        "sulfur", "substrate", "hdpe", "polonium", "plutonium",
        "pellet antimatter", "antimatter", "fissile", "ultimate control circuit"
      }
    },
    {
      label = "AE2 crafting",
      max = 4096,
      priority = 80,
      needles = {
        "certus", "fluix", "sky stone", "charged certus", "quartz glass",
        "logic processor", "calculation processor", "engineering processor",
        "printed logic", "printed calculation", "printed engineering",
        "printed silicon", "annihilation core", "formation core", "singularity"
      }
    },
    {
      label = "Productive Bees",
      max = 2048,
      priority = 75,
      needles = {
        "honey treat", "gene sample", "gene", "bee cage",
        "configurable honeycomb", "honeycomb", "productivity upgrade"
      }
    },
    {
      label = "Powah",
      max = 2048,
      priority = 70,
      needles = {
        "uraninite", "dielectric paste", "blazing crystal", "niotic crystal",
        "spirited crystal", "nitro crystal", "energizing rod", "energizing orb",
        "capacitor"
      }
    },
    {
      label = "Occultism",
      max = 1024,
      priority = 65,
      needles = {
        "iesnium", "spirit attuned", "otherstone", "datura", "chalk",
        "soul gem", "infused pickaxe", "dark gem"
      }
    },
    {
      label = "Ars Nouveau",
      max = 1024,
      priority = 60,
      needles = {
        "source gem", "source jar", "magebloom", "archwood", "wilden horn",
        "wilden wing", "wilden spike", "blank glyph", "spell parchment"
      }
    },
    {
      label = "Create",
      max = 2048,
      priority = 55,
      needles = {
        "andesite alloy", "brass", "precision mechanism", "electron tube",
        "sturdy sheet", "chromatic compound", "shaft", "cogwheel", "belt connector"
      }
    },
    {
      label = "Industrial",
      max = 2048,
      priority = 50,
      needles = {
        "modern industrialization", "stainless steel", "titanium", "tungsten",
        "platinum", "iridium", "kanthal", "cupronickel", "electrum",
        "invar", "constantan"
      }
    },
    {
      label = "Pack utility",
      max = 512,
      priority = 45,
      needles = {
        "eternal stella", "nether star crux", "dragon egg", "wither skeleton skull",
        "nether star"
      }
    }
  }

  for _, rule in ipairs(rules) do
    if amount <= rule.max and containsAny(text, rule.needles) then
      return rule
    end
  end
  return nil
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
  local sw = mon.getSize()
  local labelW = math.min(20, math.max(10, math.floor(sw * 0.34)))
  local barX = x + labelW + 1
  local pctW = 4
  local actualW = math.max(6, sw - barX - pctW)
  local fill = math.floor((p / 100) * actualW + 0.5)
  local totalText = total > 0 and fmt(total) or "?"
  writeAt(x, y, label .. " " .. fmt(used) .. "/" .. totalText, colors.white, colors.black, labelW)
  fillRect(barX, y, actualW, 1, colors.gray)
  fillRect(barX, y, fill, 1, color)
  writeAt(sw - 3, y, string.format("%3d%%", math.floor(p + 0.5)), colors.white, colors.black, 4)
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
    data.recentCandidates = data.recentCandidates or {}
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
local bulkButtons = {}
local statusMessage = nil
local statusUntil = 0
local setStatus

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

local function toggleBulkAt(screen, x, y)
  for _, button in ipairs(bulkButtons[screen] or {}) do
    if y == button.y and x >= button.x and x <= button.x2 then
      local marked = toggleBulkHint(button.key, button.name)
      if marked == nil then
        setStatus("Could not save bulk marker")
      elseif marked then
        setStatus("Bulk marker added: " .. button.name)
      else
        setStatus("Bulk marker removed: " .. button.name)
      end
      return true
    end
  end
  return false
end

function setStatus(message)
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
  if toggleBulkAt(screen, x, y) then return true end
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
  usageState.recentCandidates = usageState.recentCandidates or {}
  for _, item in pairs(items or {}) do
    local key = itemKey(item)
    local amount = amountOf(item)
    if amount > 0 then
      current[key] = amount
      local prior = usageState.last[key]
      local label = itemLabel(item)
      local watchable = shouldWatchItem(key, label)
      if prior and not usageState.ignored[key] and watchable then
        local tracked = usageState.tracked[key] or {name = label, consumed = 0, lastDrop = 0, left = amount, samples = 0, dropEvents = 0}
        tracked.name = label
        tracked.samples = n(tracked.samples) + 1
        tracked.left = amount
        tracked.lastSeen = now

        if amount < prior then
          local drop = prior - amount
          if drop >= RECENT_DROP then
            local candidate = usageState.recentCandidates[key] or {name = label, firstSeen = now, totalDrop = 0, dropEvents = 0}
            if now - n(candidate.firstSeen) > RECENT_CONFIRM_SECONDS then
              candidate = {name = label, firstSeen = now, totalDrop = 0, dropEvents = 0}
            end
            candidate.name = label
            candidate.totalDrop = n(candidate.totalDrop) + drop
            candidate.dropEvents = n(candidate.dropEvents) + 1
            candidate.lastDrop = drop
            candidate.left = amount
            candidate.lastSeen = now
            usageState.recentCandidates[key] = candidate
            if n(candidate.dropEvents) >= RECENT_EVENTS_REQUIRED then
              recent[#recent + 1] = {
                key = key,
                name = label,
                drop = candidate.totalDrop,
                left = amount,
                score = candidate.totalDrop
              }
            end
          end
          if drop >= MIN_REAL_DROP then
            tracked.consumed = n(tracked.consumed) + drop
            tracked.dropEvents = n(tracked.dropEvents) + 1
            tracked.lastDrop = drop
          else
            tracked.lastDrop = 0
          end
        elseif amount > prior then
          usageState.recentCandidates[key] = nil
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
  end

  for key, tracked in pairs(usageState.tracked or {}) do
    if tracked.lastSeen and now - tracked.lastSeen > 86400 then
      usageState.tracked[key] = nil
    end
  end
  for key, candidate in pairs(usageState.recentCandidates or {}) do
    if candidate.lastSeen and now - candidate.lastSeen > RECENT_CONFIRM_SECONDS then
      usageState.recentCandidates[key] = nil
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
  local bulkIndex, bulkCellCount, bulkItemMatches = buildBulkIndex(cells, items)
  local top = {}
  local lowStock = {}
  for _, item in pairs(items) do
    local a = amountOf(item)
    if a > 0 then
      itemTypes = itemTypes + 1
      itemCount = itemCount + a
      local label = itemLabel(item)
      local key = itemKey(item)
      if shouldWatchItem(key, label) then
        top[#top + 1] = {key = key, name = label, amount = a, bulk = bulkIndex[key]}
      end
      local stockRule = atm10StockRule(key, label, a)
      if stockRule then
        lowStock[#lowStock + 1] = {name = label, amount = a, priority = stockRule.priority, group = stockRule.label}
      end
    end
  end
  table.sort(top, function(a, b) return a.amount > b.amount end)
  table.sort(lowStock, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return a.amount < b.amount
  end)
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
  local itemPct = pct(itemUsed, itemTotal)
  local typePct = pct(itemTypes, itemTypeTotal)
  local fluidPct = pct(fluidUsed, fluidTotal)
  local fluidTypePct = pct(fluidTypes, fluidTypeTotal)
  local powerPct = pct(energy, energyCap)
  local jobs = countTable(tasks)
  local health = "OK"
  local healthColor = colors.green
  local healthDetail = "storage stable"
  if itemPct >= 90 then
    health, healthColor, healthDetail = "ITEMS FULL", colors.red, "add item storage"
  elseif typePct >= 85 then
    health, healthColor, healthDetail = "TYPES FULL", colors.red, "add type capacity"
  elseif powerPct > 0 and powerPct < 20 then
    health, healthColor, healthDetail = "LOW POWER", colors.red, "check energy input"
  elseif input > 0 and usage > input * 1.10 then
    health, healthColor, healthDetail = "POWER DRAIN", colors.orange, fmt(usage) .. "/t use > " .. fmt(input) .. "/t in"
  elseif fluidPct >= 90 then
    health, healthColor, healthDetail = "FLUIDS FULL", colors.orange, "add fluid storage"
  elseif fluidTypePct >= 85 then
    health, healthColor, healthDetail = "FLUID TYPES", colors.orange, "add fluid type capacity"
  elseif #warnings > 0 then
    health, healthColor, healthDetail = "MATERIAL DROP", colors.red, warnings[1].name
  elseif #recent > 0 then
    health, healthColor, healthDetail = "MATERIAL MOVING", colors.orange, recent[1].name
  elseif jobs > 0 then
    health, healthColor, healthDetail = "CRAFTING", colors.cyan, tostring(jobs) .. " job(s)"
  end

  for _, target in ipairs(monitorTargets) do
    mon = target.device
    local screen = target.name
    bulkButtons[screen] = {}
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

  clearLine(15, healthColor)
  writeAt(2, 15, health, colors.black, healthColor, 14)
  writeAt(17, 15, healthDetail, colors.black, healthColor, w - 18)

  clearLine(16, colors.gray)
  local now = os.epoch and math.floor(os.epoch("utc") / 1000) or os.time()
  if statusMessage and now < statusUntil then
    writeAt(2, 16, statusMessage, colors.black, colors.gray, w - 2)
  else
    writeAt(2, 16, "v" .. VERSION .. "  CELLS " .. countTable(cells) .. "  DRIVES " .. countTable(drives) .. "  CPUs " .. countTable(cpus) .. "  JOBS " .. jobs .. "  FLUID CELLS " .. fluidCellCount, colors.black, colors.gray)
  end

  local watchColor = colors.gray
  if #warnings > 0 then watchColor = colors.red elseif #recent > 0 then watchColor = colors.orange end
  clearLine(17, watchColor)
  if #warnings > 0 then
    writeAt(2, 17, "CONFIRMED MATERIAL DROPS", colors.white, colors.red)
  elseif #recent > 0 then
    writeAt(2, 17, "MATERIALS MOVING - confirmed samples", colors.black, colors.orange)
  else
    writeAt(2, 17, "WATCH: repeated real count drops only", colors.black, colors.gray)
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
  end

  clearLine(nextY, colors.lightGray)
  writeAt(2, nextY, "ATM10 WATCH STOCK", colors.black, colors.lightGray)
  nextY = nextY + 1

  if #lowStock == 0 then
    clearLine(nextY, colors.black)
    writeAt(1, nextY, "No watched ATM10 bottlenecks low", colors.lightGray, colors.black, w)
    nextY = nextY + 1
  else
    local lowRows = h < 25 and 3 or 4
    for i = 1, math.min(#lowStock, lowRows) do
      local amountText = fmt(lowStock[i].amount)
      local amountW = math.max(8, #amountText)
      local nameW = math.max(8, w - amountW - 2)
      clearLine(nextY, colors.black)
      writeAt(1, nextY, string.sub(lowStock[i].name, 1, nameW), colors.yellow, colors.black, nameW)
      writeAt(w - amountW + 1, nextY, amountText, colors.white, colors.black, amountW)
      nextY = nextY + 1
    end
  end

  if nextY + 2 <= h then
    nextY = nextY + 1
    clearLine(nextY, colors.lightGray)
    local bulkTitle = bulkCellCount > 0 and ("BIGGEST STORED ITEMS  BULK " .. bulkItemMatches .. " CELLS " .. bulkCellCount) or "BIGGEST STORED ITEMS"
    writeAt(2, nextY, bulkTitle, colors.black, colors.lightGray, w - 2)
    nextY = nextY + 1

    local y = nextY
    local listRows = math.max(0, h - y + 1)
    for i = 1, math.min(#top, listRows) do
      local amount = top[i].amount
      local amountText = fmt(amount)
      local marker = top[i].bulk and "BULK" or "B+"
      local markerW = 5
      local amountW = math.max(8, #amountText)
      local nameW = math.max(8, w - amountW - markerW - 2)
      local nameColor = colors.white
      if i > 8 then nameColor = colors.lightGray end
      clearLine(y, colors.black)
      writeAt(1, y, string.sub(top[i].name, 1, nameW), nameColor, colors.black, nameW)
      local markerX = math.max(1, w - amountW - markerW + 1)
      local markerColor = colors.gray
      if top[i].bulk == "auto" then markerColor = colors.lime elseif top[i].bulk == "hint" then markerColor = colors.cyan end
      writeAt(markerX, y, marker, markerColor, colors.black, markerW)
      bulkButtons[screen][#bulkButtons[screen] + 1] = {x = markerX, x2 = markerX + markerW - 1, y = y, key = top[i].key, name = top[i].name}
      writeAt(w - amountW + 1, y, amountText, colors.white, colors.black, amountW)
      y = y + 1
    end
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
