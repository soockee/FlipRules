--[[ FlipRules scanning: how prices get into FlipRulesDB.live (see docs/adr/0001).
  1. Full scan: on opening the AH, at most every 15 minutes (the server's limit), every listing of
     the whole house is read over several frames and kept for the items FlipRules knows. Your own
     auctions are left out of the price. Listings that vanish between two full scans give the own
     sold-a-day estimate.
  2. Check all: when no full scan is allowed, a few browse queries by item class price many items
     at once; items left over (or with your auction in the cheapest variant) get a single search.
  3. Single searches (Core.lua: Check / Pump) stay for Check prices and right before posting.
]]

local ADDON, ns = ...

local FULL_EVERY = 15 * 60 -- seconds between full scans: the server refuses more
local REPLY_WAIT = 180     -- seconds to wait for the full listing before giving up
local SLICE_MS = 8         -- milliseconds of reading per frame, so the game doesn't stutter
local QUERY_WAIT = 10      -- seconds to wait for one class query's answer

---------------------------------------------------------------- pure helpers

-- Every item FlipRules knows: rule items (down the chains), sealed writs, intermediates, stations,
-- scanned recipes. A set { [id] = true }.
function ns.KnownItems()
  local set = {}
  for _, r in ipairs(ns.rules) do
    if r.use then set[r.use] = true end
    for _, id in ipairs(ns.RuleItems(r)) do set[id] = true end
  end
  for id, rec in pairs(ns.recipes) do
    set[id] = true
    for rid in pairs(rec.reagents or {}) do set[rid] = true end
  end
  for id in pairs(ns.stations) do set[id] = true end
  for _, r in ipairs(ns.craft or {}) do
    for id in pairs(r.inputs or {}) do set[id] = true end
    for id in pairs(r.outputs or {}) do set[id] = true end
  end
  return set
end

-- Is `owner` (as the AH names a seller: "Name" or "Name-Realm") one of your characters? Pure.
function ns.IsMine(owner, names)
  if not owner then return false end
  for name in pairs(names) do
    if owner == name or owner:sub(1, #name + 1) == name .. "-" then return true end
  end
  return false
end

-- Adds one listing to acc[id] = { n = units listed, own = your units, min = cheapest unit price
-- not yours, ownMin = your cheapest, keys = { ["seller:unit:stack"] = { c = auctions, short = of
-- them about to expire } } }. buyout is for the whole stack. Pure.
function ns.ScanAdd(acc, id, stack, buyout, owner, mine, short)
  if not (stack and stack > 0) then return end
  local a = acc[id]
  if not a then a = { n = 0, own = 0, keys = {} }; acc[id] = a end
  a.n = a.n + stack
  local unit = buyout and buyout > 0 and math.floor(buyout / stack) or nil
  if mine then
    a.own = a.own + stack
    if unit and (not a.ownMin or unit < a.ownMin) then a.ownMin = unit end
  elseif unit and (not a.min or unit < a.min) then
    a.min = unit
  end
  local k = ("%s:%d:%d"):format(owner or "?", unit or 0, stack)
  local e = a.keys[k]
  if not e then e = { c = 0, short = 0 }; a.keys[k] = e end
  e.c = e.c + 1
  if short then e.short = e.short + 1 end
end

-- Units sold a day between two full scans `hours` apart: auctions in `prev` gone from `cur`, not
-- counting the ones that were about to expire anyway. Reads high: a cancelled auction counts as
-- sold. nil when the gap is too short or too long to say. Pure.
function ns.Vanished(prev, cur, hours)
  if not prev or not hours or hours < 0.25 or hours > 48 then return nil end
  local units = 0
  for k, e in pairs(prev) do
    local gone = e.c - (cur and cur[k] and cur[k].c or 0) - e.short
    if gone > 0 then units = units + gone * (tonumber(k:match(":(%d+)$")) or 1) end
  end
  return units / hours * 24
end

-- Groups item ids by AH class for browse queries. info(id) -> classID, subClassID (nil: unknown).
-- Returns { { classID, subClassID, ids = { ... } }, ... } and the ids with no class. Pure.
function ns.GroupByClass(ids, info)
  local groups, byKey, rest = {}, {}, {}
  for _, id in ipairs(ids) do
    local c, sc = info(id)
    if c then
      local k = c .. ":" .. (sc or -1)
      local g = byKey[k]
      if not g then g = { classID = c, subClassID = sc, ids = {} }; byKey[k] = g; groups[#groups + 1] = g end
      g.ids[#g.ids + 1] = id
    else
      rest[#rest + 1] = id
    end
  end
  table.sort(groups, function(a, b) return #a.ids > #b.ids end)
  return groups, rest
end

---------------------------------------------------------------- 1. full scan

local full = nil -- { state = "wait" | "read", ... } while a full scan runs
local warned = false

local function AHledgerScans() return AHledgerDB and AHledgerDB.settings and AHledgerDB.settings.autoScan end

local function FullAllowed()
  local AH = C_AuctionHouse
  return AH and AH.ReplicateItems and AH.GetNumReplicateItems and AH.GetReplicateItemInfo
    and not full and not AHledgerScans() and time() - (FlipRulesDB.scan.last or 0) >= FULL_EVERY
end

local function Ago(t) local m = math.floor((time() - t) / 60) return m < 60 and (m .. " min ago") or (math.floor(m / 60) .. " h ago") end

function ns.ScanStatus()
  local sc = FlipRulesDB and FlipRulesDB.scan or {}
  if full then return full.state == "wait" and "Full scan: waiting for the auction house..." or
    ("Full scan: reading %d%%"):format(100 * full.i / math.max(1, full.count)) end
  if AHledgerScans() then return "No full scans while AHledger's auto-scan is on: type /ahl auto off." end
  local last = sc.at and ("Last full scan " .. Ago(sc.at) .. ".") or "No full scan yet."
  local wait = FULL_EVERY - (time() - (sc.last or 0))
  return last .. (wait > 0 and (" Next one allowed in %d min."):format(math.ceil(wait / 60)) or " Next one when the AH opens.")
end

local function FinishFull()
  local db, t, f = FlipRulesDB, time(), full
  local prev, hours = db.scan.keys, db.scan.at and (t - db.scan.at) / 3600
  local keys, seen = {}, 0
  for id in pairs(f.wanted) do
    local a = f.acc[id] or { n = 0, own = 0, keys = {} }
    if a.n > 0 then seen = seen + 1 end
    db.live[id] = { min = a.min, n = a.n - a.own, own = a.ownMin, t = t, v = ns.LIVE_V, full = true }
    local op = ns.Vanished(prev and prev[id], a.keys, hours)
    -- shortcut: one history point per item per hour, ~300 items; trim the item set if saved data grows too big
    if a.n > 0 or op then ns.Hist(db.hist, id, t, a.min, a.n - a.own, op and { op = op }) end
    keys[id] = a.keys
  end
  db.scan.keys, db.scan.at, db.scan.count = keys, t, f.count
  full = nil
  ns.Say(("full scan done: %d listings read, %d of your items listed."):format(f.count, seen))
  ns.Pump()
  ns.RefreshAll()
end

local function ReadStep()
  local f = full
  if not (f and f.state == "read") then return end
  local AH = C_AuctionHouse
  local live = AH.GetNumReplicateItems() or 0
  if live ~= f.count then -- the listing was replaced or cleared meanwhile
    if live <= 0 then full = nil; ns.Say("the full scan was cleared before it was read.") return ns.RefreshAll() end
    f.i, f.count, f.acc = 0, live, {}
  end
  local short = Enum and Enum.AuctionHouseTimeLeftBand and Enum.AuctionHouseTimeLeftBand.Short or 0
  local stop = debugprofilestop() + SLICE_MS
  while f.i < f.count and debugprofilestop() < stop do
    local _, _, stack, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFull, _, itemID = AH.GetReplicateItemInfo(f.i)
    if itemID and f.wanted[itemID] then
      local who = ownerFull or owner
      -- shortcut: a seller the client hasn't loaded yet (owner nil) counts as not you
      ns.ScanAdd(f.acc, itemID, stack, buyout, who, ns.IsMine(who, f.mine), AH.GetReplicateItemTimeLeft(f.i) == short)
    end
    f.i = f.i + 1
  end
  if f.i >= f.count then return FinishFull() end
  C_Timer.After(0, ReadStep)
end

local function StartFull()
  if not FullAllowed() then return false end
  FlipRulesDB.scan.last = time() -- the server counts the request, answered or not
  if not pcall(C_AuctionHouse.ReplicateItems) then return false end
  local f = { state = "wait", sent = GetTime() }
  full = f
  ns.Say("scanning the whole auction house, about a minute...")
  C_Timer.After(REPLY_WAIT, function()
    if full ~= f or f.state ~= "wait" then return end
    full = nil
    ns.Say("the auction house didn't answer the full scan; the next try is in 15 minutes.")
    ns.RefreshAll()
  end)
  ns.RefreshAll()
  return true
end

local function OnReplicate()
  if not (full and full.state == "wait") then return end -- someone else's full scan
  local mine = {}
  for name in pairs(FlipRulesDB.chars or {}) do mine[name] = true end
  for name in (FlipRulesDB.mailChars or ""):gmatch("[^,]+") do mine[strtrim(name)] = true end
  full.state, full.i, full.count, full.acc = "read", 0, C_AuctionHouse.GetNumReplicateItems() or 0, {}
  full.wanted, full.mine = ns.KnownItems(), mine
  ReadStep()
end

---------------------------------------------------------------- 2. check all: browse by item class

local batch = nil -- { groups, i, cur, after = ids for single searches, done = n } while it runs
local sending = false

-- true while a Check all batch owns the browse results (single searches wait); with `orFull`, also
-- while a full scan runs.
function ns.ScanBusy(orFull) return batch ~= nil or (orFull and full ~= nil) or false end

local function Info(id)
  local _, _, _, _, _, c, sc = (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant)(id)
  return c, sc
end

local function EndBatch(note)
  local b = batch
  batch = nil
  if note then ns.Say(note) end
  ns.Say(("checked %d items in %d class queries%s."):format(b.done, b.i, #b.after > 0 and
    (", %d more one at a time"):format(#b.after) or ""))
  ns.Check(b.after)
  ns.RefreshAll()
end

local SendNext

local function FinishGroup(results)
  local b, g = batch, batch.cur
  local t = time()
  for _, id in ipairs(g.ids) do
    local best, n, mins, variants, ownKey = ns.CheapestVariant(results, id)
    if ownKey then
      b.after[#b.after + 1] = id -- your auction holds the cheapest variant: a single search sees past it
    else
      FlipRulesDB.live[id] = { min = best, n = n or 0, top = mins, variants = variants, t = t, v = ns.LIVE_V }
      if best then ns.Hist(FlipRulesDB.hist, id, t, best, n) end
      b.done = b.done + 1
    end
  end
  b.cur = nil
  SendNext()
end

local function OnBrowse()
  local b = batch
  if not (b and b.cur) then return end
  local AH = C_AuctionHouse
  b.cur.last = GetTime() -- each page of answers restarts the wait
  if AH.HasFullBrowseResults and not AH.HasFullBrowseResults() then
    if not pcall(AH.RequestMoreBrowseResults) then FinishGroup(AH.GetBrowseResults() or {}) end
    return
  end
  local ok, results = pcall(AH.GetBrowseResults)
  FinishGroup(ok and type(results) == "table" and results or {})
end

SendNext = function()
  local b = batch
  if not b or b.cur then return end
  local AH = C_AuctionHouse
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end -- THROTTLED_SYSTEM_READY sends
  local g = table.remove(b.groups, 1)
  if not g then return EndBatch() end
  b.cur, b.i = g, b.i + 1
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  sending = true
  local ok = pcall(AH.SendBrowseQuery, { searchString = "", sorts = { { sortOrder = order, reverseSort = false } },
    filters = {}, itemClassFilters = { { classID = g.classID, subClassID = g.subClassID } } })
  sending = false
  if not ok then -- this client won't browse by class: everything one at a time
    for _, rest in ipairs(b.groups) do for _, id in ipairs(rest.ids) do b.after[#b.after + 1] = id end end
    for _, id in ipairs(g.ids) do b.after[#b.after + 1] = id end
    b.groups = {}
    return EndBatch()
  end
  g.last = GetTime()
  local function Watch()
    if batch ~= b or b.cur ~= g then return end
    if GetTime() - g.last < QUERY_WAIT then return C_Timer.After(1, Watch) end
    for _, id in ipairs(g.ids) do b.after[#b.after + 1] = id end -- no (more) answers: search these singly
    b.cur = nil
    SendNext()
  end
  C_Timer.After(1, Watch)
end

-- Check all: a full scan if one is allowed now, else class queries for `ids`.
function ns.CheckAll(ids)
  if batch or full then return ns.Say("a scan is already running.") end
  if StartFull() then return end
  if ns.SearchesLeft() > 0 then return C_Timer.After(1, function() ns.CheckAll(ids) end) end -- let the queued single searches finish
  local set, list = {}, {}
  for _, id in ipairs(ids) do if not set[id] then set[id] = true; list[#list + 1] = id end end
  local groups, rest = ns.GroupByClass(list, Info)
  batch = { groups = groups, i = 0, after = rest, done = 0 }
  SendNext()
  ns.RefreshAll()
end

---------------------------------------------------------------- events

if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
  -- the browse results are shared: a search anyone else sends ends the batch
  hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function()
    if batch and not sending then
      local b = batch
      for _, g in ipairs(b.groups) do for _, id in ipairs(g.ids) do b.after[#b.after + 1] = id end end
      if b.cur then for _, id in ipairs(b.cur.ids) do b.after[#b.after + 1] = id end end
      b.groups, b.cur = {}, nil
      EndBatch("another search used the auction house, so the rest is checked one at a time.")
    end
  end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event)
  if not FlipRulesDB or not FlipRulesDB.scan then return end
  if event == "AUCTION_HOUSE_SHOW" then
    if AHledgerScans() and not warned then
      warned = true
      ns.Say("AHledger's auto-scan is on, so FlipRules runs no full scans of its own: type /ahl auto off.")
    end
    C_Timer.After(1, StartFull) -- after the AH UI's own first queries
  elseif event == "AUCTION_HOUSE_CLOSED" then
    if batch then batch.groups, batch.cur = {}, nil; EndBatch() end
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    OnReplicate()
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    OnBrowse()
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    SendNext()
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" and full and full.state == "wait" then
    full = nil
    ns.Say("the server refused the full scan; the next try is in 15 minutes.")
    ns.RefreshAll()
  end
end)
