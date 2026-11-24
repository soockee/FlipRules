local ADDON, ns = ...

-- This client moved several globals into C_Item / C_Container.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local NumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local SlotInfo = (C_Container and C_Container.GetContainerItemInfo) or GetContainerItemInfo

local AH_CUT = 0.05
local MIN_OBSERVED = 30 -- opens before your own drop counts replace uniform odds
local MAX_ROWS = 25     -- shortcut: no scrolling, only the top 25 rules show; add a ScrollFrame if lists grow

ns.rules, ns.craft = {}, {}

-- Public API used by Rules.lua (and any other addon).
FlipRules = {}
function FlipRules.Add(rule) ns.rules[#ns.rules + 1] = rule end
function FlipRules.Range(a, b, skip)
  local t = {}
  for id = a, b do if not (skip and skip[id]) then t[#t + 1] = id end end
  return t
end
-- Recipes you can make yourself, so a reagent costs the cheaper of buying and crafting it:
-- ns.recipes[item] = { makes = n, reagents = { [id] = qty } }. Vendor items: ns.vendor[id] = copper.
ns.recipes, ns.vendor, ns.stations = {}, {}, {}
function FlipRules.Recipe(id, makes, reagents) ns.recipes[id] = { makes = makes, reagents = reagents } end
function FlipRules.Vendor(prices) for id, c in pairs(prices) do ns.vendor[id] = c end end
-- A camp station a craft rule needs (placing one uses it up); reagents = its own recipe, or nil.
function FlipRules.Station(id, reagents)
  ns.stations[id] = true
  if reagents then FlipRules.Recipe(id, 1, reagents) end
end
-- { Label = { firstID, lastID }, ... } -> { [itemID] = "Label" }
function FlipRules.Categories(spec)
  local t = {}
  for label, r in pairs(spec) do for id = r[1], r[2] do t[id] = label end end
  return t
end

---------------------------------------------------------------- prices

-- What a vendor charges: the rules' own vendor list first (FlipRules.Vendor), else what AHledger
-- players saw vendors sell for lately.
local vendor
local function VendorPrice(id)
  if ns.vendor[id] then return ns.vendor[id] end
  if not vendor then
    vendor = {}
    local text = AHledgerVendor and AHledgerVendor.text or ""
    for k, v in text:gmatch("(%d+):(%d+)") do vendor[tonumber(k)] = tonumber(v) end
  end
  return vendor[id]
end

-- The market moves fast this early in the game, so nothing looks further back than 7 days.
local WEEK = 7 * 24 -- hours

-- Lowest and highest cheapest-listing of `id` over the last 7 days of the price history, and how many
-- points that is. Pure.
function ns.WeekRange(hist, id, now)
  local lo, hi, n = nil, nil, 0
  for k, x in pairs(hist and hist[id] or {}) do
    local p = x.lo or x.min
    if p and k >= now - WEEK then
      n = n + 1
      if not lo or p < lo then lo = p end
      if not hi or p > hi then hi = p end
    end
  end
  return lo, hi, n
end

-- Sell price per basis. "safe" = the lower of today's and the 7-day median, so one spike can't inflate
-- the profit; "low"/"high" = the week's lowest / highest cheapest listing (your history, 2+ points),
-- else the lower / higher of today's and the 7-day median.
local function SellFrom(r, basis)
  local m, m7 = r.median, r.median7d
  local a, b = math.min(m or m7 or math.huge, m7 or m or math.huge), math.max(m or m7 or 0, m7 or m or 0)
  if a == math.huge then a, b = nil, nil end
  if basis == "low" or basis == "high" then
    local lo, hi, n = ns.WeekRange(FlipRulesDB and FlipRulesDB.hist, r.itemID, math.floor(time() / 3600))
    if n >= 2 then return basis == "low" and lo or hi end
    return (basis == "low" and a or b) or r.minBuyout
  end
  if basis == "now" then return r.liveMin or m or r.minBuyout end -- live: what you'd list at now
  if basis == "safe" then return a or r.minBuyout end
  return m7 or m or r.minBuyout -- "7d", the default
end

local function Basis()
  local b = FlipRulesDB and FlipRulesDB.basis
  return (b == "now" or b == "safe") and b or "7d" -- "30d" was removed (2026-11-23)
end

-- FlipRulesDB.live[id] = { min = cheapest listing not yours (nil: none), n = listed, t = time() },
-- from auction house searches (ours or yours). Account-wide, so every character sees it.
local LIVE_FRESH = 3600 -- a live price older than this falls back to AHledger's table
local LIVE_V = 2 -- entries from before the per-item price fix (no v) are ignored
local function Live(id, maxAge)
  local l = FlipRulesDB and FlipRulesDB.live and FlipRulesDB.live[id]
  return l and l.v == LIVE_V and time() - l.t <= (maxAge or LIVE_FRESH) and l or nil
end

-- AHledger's row, with its lowest listing replaced by a fresh live one.
local function AHRow(id)
  local r = AHledgerAPI and AHledgerAPI.GetPrice(id)
  local l = Live(id)
  if not l then return r end
  local c = {}
  for k, v in pairs(r or {}) do c[k] = v end
  c.minBuyout, c.liveMin, c.itemID = l.min, l.min, id
  return c
end

-- buy: what you pay now (cheapest of vendor / AH min buyout). sell: AH price per basis.
local function MarketPrice(id, buy, basis)
  local p
  local r = AHRow(id)
  if r then p = buy and (r.minBuyout or r.median) or SellFrom(r, basis or Basis()) end
  if not p and Auctionator and Auctionator.API and Auctionator.API.v1 then
    p = Auctionator.API.v1.GetAuctionPriceByItemID(ADDON, id)
  end
  if buy and not p then p = VendorPrice(id) end
  return p
end

-- Buying one: a vendor item at its stable vendor price, anything else at the AH. Returns price, "vendor"/"AH".
local function BuyPrice(id)
  local v = VendorPrice(id)
  if v then return v, "vendor" end
  return MarketPrice(id, true), "AH"
end

-- Cheapest way to get one `id`: buy it (buyFn), or craft it from `recipes`, each reagent again the
-- cheapest way. Returns cost, how ("vendor", "AH" or "craft"), buy cost, craft cost. Pure.
function ns.BestCost(id, buyFn, recipes, depth)
  depth = depth or 0
  local buy, how = buyFn(id)
  local rec, craft = depth < 8 and how ~= "vendor" and recipes[id], nil
  if rec then
    craft = 0
    for rid, n in pairs(rec.reagents) do
      local c = ns.BestCost(rid, buyFn, recipes, depth + 1)
      if not c then craft = nil break end
      craft = craft + c * n
    end
    if craft then craft = craft / rec.makes end
  end
  if craft and (not buy or craft < buy) then return craft, "craft", buy, craft end
  return buy, buy and how or nil, buy, craft
end

local function Cost(id) return ns.BestCost(id, BuyPrice, ns.recipes) end

-- A station costs the cheaper of buying one and crafting it; second value: true when crafted.
local function StationCost(id)
  local c, how = Cost(id)
  return c, how == "craft"
end

local function PriceFor(rule, basis)
  return function(id, buy)
    if rule.price and rule.price[id] then return rule.price[id] end
    if buy then return (Cost(id)) end
    return MarketPrice(id, buy, basis)
  end
end

local function CraftsPerStation() return math.max(1, tonumber(FlipRulesDB and FlipRulesDB.craftsPerStation) or 10) end

local function PerDay(id)
  local r = AHRow(id)
  return r and r.soldPerDay
end

---------------------------------------------------------------- math (pure)

-- Returns cost, value (after AH cut), profit, unpricedOutputs. cost/profit are nil when an input
-- has no price. Unpriced outputs count as 0: if nobody lists it, you probably can't sell it.
function ns.Evaluate(rule, price, weights)
  local cost = 0
  for id, n in pairs(rule.inputs or {}) do
    local p = price(id, true)
    if not p then cost = nil break end
    cost = cost + p * n
  end

  local value, unpriced = 0, 0
  if rule.pool then
    local total = 0
    for _, id in ipairs(rule.pool) do total = total + (weights and (weights[id] or 0) or 1) end
    for _, id in ipairs(rule.pool) do
      local w = (weights and (weights[id] or 0) or 1) / total
      local p = price(id, false)
      if p then value = value + w * p * (rule.poolQty or 1) else unpriced = unpriced + 1 end
    end
  end
  for id, n in pairs(rule.outputs or {}) do
    local p = price(id, false)
    if p then value = value + p * n else unpriced = unpriced + 1 end
  end
  value = value * (1 - AH_CUT)
  return cost, value, cost and (value - cost), unpriced
end

-- What appeared in the bags: { [itemID] = gained } for every item whose count went up, minus `skip`.
function ns.Gains(prev, now, skip)
  local g, any = {}, false
  for id, n in pairs(now) do
    local d = n - (prev[id] or 0)
    if d > 0 and id ~= skip then g[id] = d; any = true end
  end
  return any and g or nil
end

local function SelfTest()
  local r = { inputs = { [1] = 2 }, pool = { 10, 11 }, outputs = { [12] = 1 } }
  local pr = { [1] = 100, [10] = 1000, [12] = 500 }
  local f = function(id) return pr[id] end
  local c, v, p, u = ns.Evaluate(r, f)
  assert(c == 200 and u == 1 and math.abs(v - 950) < 1e-6 and math.abs(p - 750) < 1e-6, "uniform")
  c, v, p = ns.Evaluate(r, f, { [10] = 3, [11] = 1 })
  assert(math.abs(v - 1187.5) < 1e-6, "weighted") -- (0.75*1000 + 500) * 0.95
  pr[1] = nil
  c, v, p = ns.Evaluate(r, f)
  assert(c == nil and p == nil, "unpriced input")
  local g = ns.Gains({ [5] = 3, [7] = 1 }, { [5] = 2, [7] = 2, [9] = 1 }, 5)
  assert(g[7] == 1 and g[9] == 1 and g[5] == nil, "gains")
  assert(ns.Gains({ [5] = 3 }, { [5] = 2 }, 5) == nil, "no gains")
  local inPool = function(id) return id == 10 or id == 11 end
  local function M() return { uses = {}, items = {} } end
  local st = M()                                                     -- use first, item later
  assert(#ns.Match(st, 1, nil, 0, inPool, 30) == 0 and ns.Match(st, 0, { [10] = 1 }, 1, inPool, 30)[1] == 10, "use then item")
  st = M()                                                           -- item first, use later
  assert(#ns.Match(st, 0, { [10] = 1 }, 0, inPool, 30) == 0 and ns.Match(st, 1, nil, 2, inPool, 30)[1] == 10, "item then use")
  st = M()                                                           -- unrelated loot alongside
  local cr = ns.Match(st, 1, { [99] = 1, [10] = 1 }, 0, inPool, 30)
  assert(#cr == 1 and cr[1] == 10, "pool item preferred")
  assert(#ns.Match(st, 0, nil, 40, inPool, 30) == 0, "unrelated loot forgotten")
  st = M()                                                           -- two quick opens
  ns.Match(st, 2, nil, 0, inPool, 30)
  assert(#ns.Match(st, 0, { [10] = 1, [11] = 1 }, 1, inPool, 30) == 2, "two opens")
  st = M()                                                           -- sold, not opened
  ns.Match(st, 1, nil, 0, inPool, 30)
  local c2, lost = ns.Match(st, 0, nil, 31, inPool, 30)
  assert(#c2 == 0 and lost == 1, "lost use")
  st = M()                                                           -- drop outside the pool
  ns.Match(st, 1, { [99] = 1 }, 0, inPool, 30)
  assert(ns.Match(st, 0, nil, 31, inPool, 30)[1] == 99, "not-in-pool drop")
  local base = { rule = { pool = { 1 } }, safe = 100, worst = 50, perDay = 5, unpricedShare = 0, observed = true, opens = 40 }
  local function V(over) local e = {} for k, x in pairs(base) do e[k] = x end for k, x in pairs(over) do e[k] = x end return (ns.Verdict(e)) end
  assert(V({}) == "YES", "verdict yes")
  assert(V({ safe = -1 }) == "NO", "verdict no")
  assert(V({ worst = -1 }) == "RISKY" and V({ perDay = 0.2 }) == "RISKY" and V({ observed = false }) == "RISKY", "verdict risky")
  assert(ns.PostPrice(50050) == 50049, "undercut by 1 copper")
  assert(ns.PostPrice(nil, 12345) == 12345 and ns.PostPrice(nil, nil) == nil, "fallback price")
  local lo, n, top = ns.Lowest({ { price = 500, qty = 2, own = 2 }, { price = 900, qty = 1, own = 0 }, { price = 700.6, qty = 3, own = 0 } })
  assert(lo == 700 and n == 4 and top[2] == 900 and #top == 2, "lowest skips own listings")
  local many = {}
  for i = 1, 8 do many[i] = { price = 100 * (9 - i), qty = 1, own = 0 } end
  assert(#select(3, ns.Lowest(many)) == 5 and select(3, ns.Lowest(many))[5] == 500, "keeps the 5 cheapest")
  assert(ns.Lowest({}) == nil, "no listings")
  assert(ns.MailKind("Auction successful: Craftsman's Writ: Soul Pouch") == "sold", "mail sold")
  assert(ns.MailKind("Auction won: Sealed Artisan's Writ") == "won" and ns.MailKind("Hello") == nil, "mail won / other")
  assert(ns.MailTarget("Milchiger Abgang, Wealth Peon", "Wealth Peon") == "Milchiger Abgang", "mail the other character")
  assert(ns.MailTarget("Milchiger Abgang, Wealth Peon", "Someone") == "Milchiger Abgang", "mail the first one")
  assert(ns.MailTarget(" , Wealth Peon ", "wealth peon") == "" and ns.MailTarget(nil, "x") == "", "no one left to mail")
  local cs = ns.CheapStacks({ { id = 1 }, { id = 2 }, { id = 3 }, { id = 4 } },
    function(id) return ({ [1] = 99, [2] = 100, [3] = nil, [4] = 5 })[id] end, 100)
  assert(#cs == 2 and cs[1].id == 1 and cs[2].id == 4, "delete only checked writs under 1 silver")
  local su = ns.Supply({ { id = 1, odds = 0.5, stock = 2, perDay = 2 }, { id = 2, odds = 0.5, stock = 10, perDay = 1 },
    { id = 3, odds = 0, stock = 0 } }, 10)
  assert(su.rows[1].id == 2 and su.rows[1].after == 15 and su.rows[2].after == 3.5, "supply days after buying")
  assert(su.fastShare == 0.5 and su.stock == 12 and su.perDay == 3 and su.after == 22 / 3, "supply totals")
  assert(su.rows[3].after == 0 and ns.Supply({}, 0).fastShare == 1, "supply edge cases")
  local tr = {}
  ns.Track(tr, "post", 7, 2, 0, 10000, 6000)
  ns.Track(tr, "post", 7, 1, 3600, 12000, nil)
  ns.Track(tr, "sold", 7, 1, 7200, 9500)    -- the oldest post sells after 2 h
  ns.Track(tr, "expired", 7, 1, 9000)
  local ts = ns.TrackSummary(tr[7])
  assert(ts.through == 0.5 and ts.open == 1 and ts.each == 9500 and ts.ofList == 0.95, "track sell-through, price")
  assert(ts.hours == 2 and ts.profit == 3500 and tr[7].open[1].price == 12000, "track hours, profit, oldest first")
  ns.Track(tr, "sold", 8, 1, 0, 500) -- posted before tracking: counted, no time or cost
  local t8 = ns.TrackSummary(tr[8])
  assert(t8.through == 1 and t8.hours == nil and t8.profit == nil, "track sale without a post")
  local hi, T = {}, 1795392000 -- an hour boundary
  local K = ns.Slot(T)
  ns.Hist(hi, 7, T + 5, 900, 4)
  ns.Hist(hi, 7, T + 99, 1100, 3)       -- same hour: merges, keeps the low
  ns.Hist(hi, 7, T + 3600 * 2 + 60, 800, 1) -- two hours later: its own point
  assert(hi[7][K].lo == 900 and hi[7][K].min == 1100 and hi[7][K].n == 3 and hi[7][K + 2].lo == 800, "history: a point an hour")
  ns.Hist(hi, 7, T + 3600 * 2 + 10, 600, 9) -- an older source in the same hour: lowers the low, not the latest
  assert(hi[7][K + 1] == nil and hi[7][K + 2].lo == 600 and hi[7][K + 2].n == 1, "history: newest source wins")
  hi[7][20774] = { lo = 50, t = T - 3600 * 5 } -- a day key from the old format
  ns.PruneHist(hi, T + 3600 * 2)
  assert(hi[7][20774] == nil and hi[7][K - 5].lo == 50, "history: old day keys move to their hour")
  ns.PruneHist(hi, T + 86400 * 31)
  assert(hi[7] == nil, "history drops points after 30 days")
  ns.Hist(hi, 9, T, 500, 4, { md = 700, pd = 2.5 })
  ns.Hist(hi, 9, T + 7200, 450, 6)
  assert(ns.HistField(hi, 9, K + 2, "pd") == 2.5 and hi[9][K].md == 700 and ns.HistField(hi, 9, K - 1, "pd") == nil,
    "history keeps AHledger's median and pace")
  local acc, data = {}, "5:2:300:0:3;9:1:50:0:1;5:1:120:0:2;5:4:0:0:1;12:1:7:0:1"
  local pos = ns.ScanStep(data, 1, { [5] = true, [9] = true }, acc, 2)
  assert(pos and acc[5].n == 2 and acc[5].min == 150 and acc[9].min == 50, "scan read in steps")
  assert(ns.ScanStep(data, pos, { [5] = true, [9] = true }, acc, 100) == nil, "scan read to the end")
  assert(acc[5].n == 7 and acc[5].min == 120 and acc[12] == nil, "scan: unit price, bid-only counted, others ignored")
  local S = ns.Subject
  assert(ns.MailKind(S("AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s", "Wild Leather Helmet")) == "expired", "mail expired")
  assert(ns.MailKind(S("AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s", "Wild Leather Helmet")) == "cancelled", "mail cancelled")
  assert(ns.MailKind(S("AUCTION_SOLD_MAIL_SUBJECT", "Auction successful: %s", "Wild Leather Helmet")) == "sold", "mail sold, client text")
  local dh = { [5] = { [10] = { lo = 100, min = 120 }, [12] = { lo = 90 } }, [6] = { [11] = { lo = 40 } }, [7] = { [12] = { lo = 1000 } } }
  assert(ns.DayPrice(dh, 5, 11) == 100 and ns.DayPrice(dh, 5, 12) == 90 and ns.DayPrice(dh, 5, 9) == nil, "day price carries forward")
  local on = ns.PriceOn(dh, 12, function(x) return x == 8 and 7 or nil end, { [5] = { makes = 1, reagents = { [6] = 2 } } })
  assert(on(5, true) == 80 and on(5, false) == 90 and on(8, true) == 7 and on(7, false) == 1000, "price on a day: craft, sell, vendor")
  local earn = {}
  ns.Earn(earn, "sold", "x", 2, 500)
  local ee = ns.Earn(earn, "won", "x", 1, 200)
  assert(ee.sold == 2 and ee.revenue == 500 and ee.bought == 1 and ee.spent == 200, "earn totals")
  assert(SellFrom({ liveMin = 900, median = 1000 }, "now") == 900 and SellFrom({ median = 1000 }, "now") == 1000, "now uses live")
  assert(SellFrom({ liveMin = 1, median = 1000, median7d = 1100 }, "safe") == 1000, "safe ignores live")
  assert(SellFrom({ median = 1200, median7d = 1100, median30d = 500 }, "safe") == 1100, "safe ignores the 30-day median")
  assert(SellFrom({ median = 1200, median7d = 1100, low30d = 100 }, "low") == 1100
    and SellFrom({ median = 1200, median7d = 1100, high30d = 9000 }, "high") == 1200, "week range without history")
  local wh = { [3] = { [1000] = { lo = 500 }, [1100] = { lo = 700 }, [1150] = { min = 600 } } }
  local wl, wu, wn = ns.WeekRange(wh, 3, 1200)
  assert(wl == 600 and wu == 700 and wn == 2, "week range: only the last 7 days")
  local sc, sv, sp = ns.Evaluate({ inputs = { [1] = 2, [9] = 0.1 }, outputs = { [12] = 1 } }, function(id) return ({ [1] = 100, [9] = 1000, [12] = 1000 })[id] end)
  assert(math.abs(sc - 300) < 1e-6 and math.abs(sp - 650) < 1e-6, "station share in cost") -- 2*100 + 1000/10; 950 - 300
  -- chain: 1 hide (AH 500) + 1 salt (vendor 50) makes 2 cured; leather: AH 100 or craft from 5 scraps at 10
  local rec = { [7] = { makes = 2, reagents = { [5] = 1, [6] = 1 } }, [8] = { makes = 1, reagents = { [4] = 5 } } }
  local buyT = { [4] = { 10, "AH" }, [5] = { 500, "AH" }, [6] = { 50, "vendor" }, [7] = { 400, "AH" }, [8] = { 100, "AH" } }
  local bf = function(id) local b = buyT[id] if b then return b[1], b[2] end end
  local c7, h7 = ns.BestCost(7, bf, rec)
  assert(c7 == 275 and h7 == "craft", "craft cheaper than AH") -- (500 + 50) / 2
  local c8, h8 = ns.BestCost(8, bf, rec)
  assert(c8 == 50 and h8 == "craft", "leather from scraps")
  buyT[4] = { 30, "AH" }
  assert(select(2, ns.BestCost(8, bf, rec)) == "AH", "buy when crafting costs more")
  buyT[4] = { 10, "AH" }
  local lv = ns.Leaves(7, 4, {}, function(id) return ns.BestCost(id, bf, rec) end, rec)
  assert(lv[5] == 2 and lv[6] == 2 and lv[7] == nil, "shopping list follows the chain")
  -- variants: "of the Monkey" 9000, "of the Bear" 7000, plain 8000 (yours), another item 100
  local br = {
    { itemKey = { itemID = 8210, itemSuffix = 1 }, minPrice = 9000, totalQuantity = 2 },
    { itemKey = { itemID = 8210, itemSuffix = 2 }, minPrice = 7000, totalQuantity = 1 },
    { itemKey = { itemID = 8210 }, minPrice = 8000, totalQuantity = 3, containsOwnerItem = true },
    { itemKey = { itemID = 99 }, minPrice = 100, totalQuantity = 5 },
  }
  local vb, vn, vm, vv, vk = ns.CheapestVariant(br, 8210)
  assert(vb == 7000 and vn == 6 and vv == 3 and vm[1] == 7000 and vk == nil, "cheapest variant, other items ignored")
  br[3].minPrice = 5000
  assert(select(5, ns.CheapestVariant(br, 8210)) == br[3].itemKey, "your variant cheapest: search it")
  assert(ns.CheapestVariant({}, 8210) == nil, "no variants listed")
  print("|cff33ff99FlipRules|r self-test passed")
end

---------------------------------------------------------------- stats: what opening really gives

-- FlipRulesDB.stats[rule.name] = { opens = n, items = { [itemID] = count } }
local function Stats(rule)
  local s = FlipRulesDB.stats[rule.name]
  if not s then s = { opens = 0, items = {} }; FlipRulesDB.stats[rule.name] = s end
  return s
end

local function Cat(rule, id) return rule.category and rule.category[id] or "Other" end

local function BagCounts()
  local c = {}
  for bag = 0, 4 do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and info.itemID then c[info.itemID] = (c[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return c
end

local function Money(c)
  if not c then return "|cff999999?|r" end
  local v = math.floor(math.abs(c) + 0.5)
  local g, sv, cp = math.floor(v / 10000), math.floor(v / 100) % 100, v % 100
  local s = g > 0 and ("%d|cffffd700g|r %02d|cffc7c7cfs|r"):format(g, sv)
    or sv > 0 and ("%d|cffc7c7cfs|r %02d|cffeda55fc|r"):format(sv, cp)
    or ("%d|cffeda55fc|r"):format(cp)
  return c < 0 and ("|cffff4040-|r" .. s) or s
end

local function Name(id) return (GetItemInfo(id)) or ("item:" .. id) end
local function Link(id) return select(2, GetItemInfo(id)) or Name(id) end

local function InPool(rule, id)
  for _, p in ipairs(rule.pool or {}) do if p == id then return true end end
  return false
end

-- A use and the item it gives can show up in either order and in different bag updates (loot
-- window, server lag). Uses and new items both wait up to PENDING_SECONDS to be paired.
local PENDING_SECONDS = 30

-- Pure pairing step. st = { uses = { time... }, items = { {id, t}... } } persists between calls.
-- used / gains: what this bag update consumed / added. isExpected(id): true for pool items.
-- Returns the item IDs credited as drops, and how many uses got nothing within the window.
function ns.Match(st, used, gains, t, isExpected, window)
  for _ = 1, used do st.uses[#st.uses + 1] = t end
  for id, d in pairs(gains or {}) do
    for _ = 1, d do st.items[#st.items + 1] = { id = id, t = t } end
  end
  local credited, lost = {}, 0
  local function take(pred)
    for i, it in ipairs(st.items) do
      if pred(it.id) then table.remove(st.items, i) return it.id end
    end
  end
  -- pair the oldest uses with expected items first, so unrelated loot isn't taken for a drop
  while #st.uses > 0 do
    local id = take(isExpected)
    if not id then break end
    table.remove(st.uses, 1)
    credited[#credited + 1] = id
  end
  -- a use that waited the whole window takes any other new item (a drop outside the pool),
  -- or is lost: the item was sold, mailed or deleted rather than opened
  while #st.uses > 0 and t - st.uses[1] > window do
    table.remove(st.uses, 1)
    local id = take(function() return true end)
    if id then credited[#credited + 1] = id else lost = lost + 1 end
  end
  for i = #st.items, 1, -1 do
    if t - st.items[i].t > window then table.remove(st.items, i) end
  end
  return credited, lost
end

local lastBags
local matching = {} -- [rule.name] = pairing state for ns.Match
local TrackOpens
TrackOpens = function()
  local now = BagCounts()
  local prev = lastBags
  lastBags = now
  if not prev then return end
  local t = GetTime()
  for _, r in ipairs(ns.rules) do
    if r.use then
      local st = matching[r.name] or { uses = {}, items = {} }
      matching[r.name] = st
      local used = math.max(0, (prev[r.use] or 0) - (now[r.use] or 0))
      local expected = r.pool and function(id) return InPool(r, id) end or function() return true end
      local credited, lost = ns.Match(st, used, ns.Gains(prev, now, r.use), t, expected, PENDING_SECONDS)
      -- bag updates may stop after the use, so look again once the wait is over
      if used > 0 then C_Timer.After(PENDING_SECONDS + 1, function() TrackOpens() end) end
      local s = Stats(r)
      for _, id in ipairs(credited) do
        s.opens = s.opens + 1
        s.items[id] = (s.items[id] or 0) + 1
        print(("|cff33ff99FlipRules|r %s -> %s |cff999999[%s]|r %s  |cff999999seen %d/%d (%.1f%%)%s|r"):format(
          Name(r.use), Link(id), Cat(r, id), Money(PriceFor(r)(id, false)), s.items[id], s.opens,
          100 * s.items[id] / s.opens, (r.pool and not InPool(r, id)) and " NOT IN POOL" or ""))
      end
      if lost > 0 then
        print(("|cff33ff99FlipRules|r %d %s left your bags but nothing new arrived within %ds: not counted (sold, mailed or deleted?)"):format(
          lost, Name(r.use), PENDING_SECONDS))
      end
    end
  end
end

---------------------------------------------------------------- profession scan

local function ItemID(link) return link and tonumber(link:match("item:(%d+)")) end

-- Modern recipe API (what AHledger tries first on this client).
local function ScanModern(craft)
  local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
  if not ok or not ids then return end
  for _, rid in ipairs(ids) do
    local ok2, info = pcall(C_TradeSkillUI.GetRecipeInfo, rid)
    local ok3, s = pcall(C_TradeSkillUI.GetRecipeSchematic, rid, false)
    if ok2 and info and info.learned ~= false and ok3 and s and s.outputItemID then
      local r = { name = s.name or Name(s.outputItemID), inputs = {}, recipe = true,
        outputs = { [s.outputItemID] = ((s.quantityMin or 1) + (s.quantityMax or s.quantityMin or 1)) / 2 } }
      local any = false
      for _, slot in ipairs(s.reagentSlotSchematics or {}) do
        local basic = not slot.reagentType or (Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
        local g = slot.reagents and slot.reagents[1]
        if basic and g and g.itemID then r.inputs[g.itemID] = slot.quantityRequired or 1; any = true end
      end
      if any then craft[#craft + 1] = r end
    end
  end
end

local function ScanTradeSkill()
  local craft = {}
  if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeSchematic then ScanModern(craft) end
  if #craft > 0 or not GetNumTradeSkills then ns.craft = craft return end
  for i = 1, GetNumTradeSkills() do
    local name, kind = GetTradeSkillInfo(i)
    local out = kind ~= "header" and ItemID(GetTradeSkillItemLink(i))
    if out then
      local lo, hi = GetTradeSkillNumMade(i)
      local r = { name = name, inputs = {}, outputs = { [out] = ((lo or 1) + (hi or 1)) / 2 }, recipe = true }
      for j = 1, GetTradeSkillNumReagents(i) do
        local _, _, count = GetTradeSkillReagentInfo(i, j)
        local rid = ItemID(GetTradeSkillReagentItemLink(i, j))
        if rid then r.inputs[rid] = count end
      end
      craft[#craft + 1] = r
    end
  end
  ns.craft = craft
end

---------------------------------------------------------------- evaluation

-- With enough opens, value the pool by what you actually got (including items outside the pool).
local function Evaluated(r)
  local s = r.use and Stats(r)
  local observed = r.pool and s and s.opens >= MIN_OBSERVED
  local rule, weights = r, nil
  if observed then
    local pool = {}
    for id in pairs(s.items) do pool[#pool + 1] = id end
    rule = { inputs = r.inputs, outputs = r.outputs, pool = pool, poolQty = r.poolQty, price = r.price }
    weights = s.items
  end
  if r.station then -- each craft carries its share of the station
    local inputs = { [r.station] = 1 / CraftsPerStation() }
    for id, n in pairs(r.inputs) do inputs[id] = n end
    rule = { inputs = inputs, outputs = rule.outputs, pool = rule.pool, poolQty = rule.poolQty, price = r.price }
  end
  local cost, value, profit, unpriced = ns.Evaluate(rule, PriceFor(r), weights)
  local _, _, worst = ns.Evaluate(rule, PriceFor(r, "low"), weights)
  local _, _, best = ns.Evaluate(rule, PriceFor(r, "high"), weights)
  local _, safeValue, safe = ns.Evaluate(rule, PriceFor(r, "safe"), weights)

  -- expected units of output sold per day on the whole market (pool: weighted by odds)
  local perDay, outs, wsum = 0, 0, 0
  for _, id in ipairs(rule.pool or {}) do
    local w = weights and (weights[id] or 0) or 1
    perDay, wsum = perDay + w * (PerDay(id) or 0), wsum + w
  end
  if wsum > 0 then perDay, outs = perDay / wsum, 1 end
  for id in pairs(rule.outputs or {}) do
    local pd = PerDay(id) or 0
    perDay = outs == 0 and pd or math.min(perDay, pd); outs = outs + 1
  end

  -- most you can pay for the (single) input and still break even at safe prices
  local maxBuy, only = nil, nil
  for id, n in pairs(r.inputs or {}) do
    if only then only = false break end
    only = { id = id, n = n }
  end
  if only then maxBuy = safeValue / only.n end

  local nPriced = #(rule.pool or {})
  for _ in pairs(rule.outputs or {}) do nPriced = nPriced + 1 end
  return { rule = r, cost = cost, value = value, profit = profit, worst = worst, best = best, safe = safe,
    maxBuy = maxBuy, perDay = perDay, unpriced = unpriced, unpricedShare = nPriced > 0 and unpriced / nPriced or 0,
    opens = s and s.opens or 0, observed = observed, safeValue = safeValue, evalRule = rule, weights = weights }
end

-- The checks behind the verdict, { pass, text } each; the first one is the hard requirement.
function ns.Checks(e)
  local c = {
    { (e.safe or 0) > 0, ("Makes money at cautious prices: %s a run"):format(Money(e.safe)) },
    { not (e.worst and e.worst < 0), ("Still makes money at the week's lowest price: %s a run"):format(Money(e.worst)) },
    { e.perDay >= 1, ("Sells often enough: ~%.1f a day on the AH (want 1+)"):format(e.perDay) },
    { e.unpricedShare <= 0.25, ("Prices known for %d%% of the results (want 75%%+)"):format(100 - 100 * e.unpricedShare) },
  }
  if e.rule.pool then c[#c + 1] = { e.observed, ("Odds are your own: %d of %d opens recorded"):format(e.opens, MIN_OBSERVED) } end
  return c
end

-- Go / no-go: profit must survive "safe" prices; the other checks turn YES into RISKY.
-- Returns label, colour code, reasons{}.
function ns.Verdict(e)
  if not e.safe then return "?", "|cff999999", { "an input has no price" } end
  local checks = ns.Checks(e)
  if not checks[1][1] then return "NO", "|cffff4040", { "loses money even at cautious prices" } end
  local why = {}
  local SHORT = { "", "loses money at the week's lowest price", "sells slowly", "many results have no price", "odds not yours yet" }
  for i = 2, #checks do if not checks[i][1] then why[#why + 1] = SHORT[i] end end
  if #why == 0 then return "YES", "|cff40ff40", { "makes money and every check passes" } end
  return "RISKY", "|cffffd100", why
end

-- The list filter: "all", "writs" (rules you open), or a rule group such as "Leatherworking".
-- Specializations you can craft; recipes of the others are hidden. Default: Dragonscale only.
local SPECS = { "Dragonscale", "Elemental", "Tribal" }
local function HasSpec(spec)
  local s = FlipRulesDB and FlipRulesDB.specs
  if not s then return spec == "Dragonscale" end
  return s[spec] and true or false
end

local function Shown(r)
  if r.spec and not HasSpec(r.spec) then return false end
  local f = FlipRulesDB and FlipRulesDB.filter or "all"
  if f == "all" then return true end
  if f == "writs" then return r.use ~= nil end
  return r.group == f
end

local function Results()
  local list = {}
  for _, r in ipairs(ns.rules) do if Shown(r) then list[#list + 1] = Evaluated(r) end end
  for _, r in ipairs(ns.craft) do if Shown(r) then list[#list + 1] = Evaluated(r) end end
  table.sort(list, function(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end)
  return list
end

---------------------------------------------------------------- the window: rules | drop stats | verdict graph

local W, H = 1040, 664
local LX, LW = 12, 500   -- left column: rules list on top, drop statistics below
local RX, VW = 542, 470  -- right column: verdict graph of the selected rule
local N_ROWS = 13        -- visible rows; the mouse wheel scrolls the rest

local selected   -- the rule shown in the stats and the verdict graph
local listOffset = 0

local frame = CreateFrame("Frame", "FlipRulesFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(W, H)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()
tinsert(UISpecialFrames, "FlipRulesFrame")
frame.TitleText:SetText("FlipRules")

local divider = frame:CreateTexture(nil, "ARTWORK")
divider:SetColorTexture(1, 1, 1, 0.12)
divider:SetPoint("TOPLEFT", RX - 16, -28)
divider:SetPoint("BOTTOMLEFT", RX - 16, 8)
divider:SetWidth(1)

local function Text(y, font, x, w)
  local fs = frame:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", x or RX, y)
  if w then fs:SetWidth(w); fs:SetWordWrap(false) end
  fs:SetJustifyH("LEFT")
  return fs
end

---------------------------------------------------------------- left top: rules list

local function ShowBreakdown(row, e)
  local r, price = e.rule, PriceFor(e.rule)
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(r.name)
  GameTooltip:AddLine("Buy", 1, 0.82, 0)
  for id, n in pairs(e.evalRule.inputs or {}) do
    GameTooltip:AddDoubleLine((n < 1 and ("1/%d"):format(math.floor(1 / n + 0.5)) or n) .. "x " .. Name(id),
      Money(price(id, true) and price(id, true) * n), 1, 1, 1)
  end
  if r.pool then GameTooltip:AddLine(("Pool of %d, odds: %s (%d opened)"):format(#r.pool, e.observed and "yours" or "uniform", e.opens), 1, 0.82, 0) end
  for id, n in pairs(r.outputs or {}) do GameTooltip:AddDoubleLine("Sell " .. n .. "x " .. Name(id), Money(price(id, false) and price(id, false) * n), 1, 1, 1) end
  GameTooltip:AddDoubleLine("Value after 5% AH cut", Money(e.value))
  GameTooltip:AddDoubleLine("Profit per run (sell at " .. Basis() .. ")", Money(e.profit))
  if e.unpriced > 0 then GameTooltip:AddLine(e.unpriced .. " output(s) have no price, counted as 0", 1, 0.4, 0.4) end
  GameTooltip:AddLine("Click: show verdict and statistics", 0.4, 1, 0.4)
  if not r.use and Auctionator then GameTooltip:AddLine("At the auction house, the click also searches the reagents in Auctionator", 0.4, 1, 0.4) end
  if AHledgerAPI then GameTooltip:AddLine(AHledgerAPI.CREDIT, 0.5, 0.5, 0.5) end
  GameTooltip:Show()
end

local COLS = { { "Rule", 0, 240, "LEFT" }, { "Cost", 245, 80, "RIGHT" }, { "Value", 330, 80, "RIGHT" }, { "Profit", 415, 85, "RIGHT" } }
for _, c in ipairs(COLS) do
  local h = Text(-30, "GameFontNormalSmall", LX + c[2], c[3])
  h:SetJustifyH(c[4]); h:SetText(c[1])
end

local RefreshAll

-- mouse wheel over the list scrolls it (rows don't take the wheel, so it reaches this frame)
local listArea = CreateFrame("Frame", nil, frame)
listArea:SetPoint("TOPLEFT", LX, -46)
listArea:SetSize(LW, N_ROWS * 18)
listArea:EnableMouseWheel(true)
listArea:SetScript("OnMouseWheel", function(_, delta) listOffset = listOffset - delta * 3; RefreshAll() end)

-- list filter, in the title bar
local FILTERS = { { "all", "All" }, { "writs", "Writs" }, { "Leatherworking", "Leatherworking" } }
local filterBtns, fprev = {}, nil
for _, f in ipairs(FILTERS) do
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(f[1] == "Leatherworking" and 100 or 56, 18)
  if fprev then b:SetPoint("LEFT", fprev, "RIGHT", 2, 0) else b:SetPoint("TOPLEFT", 8, -2) end
  b:SetText(f[2])
  b:SetScript("OnClick", function() FlipRulesDB.filter = f[1]; listOffset = 0; selected = nil; RefreshAll() end)
  filterBtns[f[1]] = b
  fprev = b
end

-- your Leatherworking specializations, next to the filter; shown with the Leatherworking filter
local specChecks = {}
for _, spec in ipairs(SPECS) do
  local c = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  c:SetSize(20, 20)
  c:SetPoint("LEFT", fprev, "RIGHT", fprev == filterBtns.Leatherworking and 10 or 70, 0)
  c.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.label:SetPoint("LEFT", c, "RIGHT", 0, 0)
  c.label:SetText(spec)
  c:SetScript("OnClick", function(self)
    if not FlipRulesDB.specs then FlipRulesDB.specs = { Dragonscale = true } end
    FlipRulesDB.specs[spec] = self:GetChecked() and true or false
    selected = nil
    RefreshAll()
  end)
  c:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(spec .. " Leatherworking")
    GameTooltip:AddLine("Tick the specializations you have. Writ items that need one you don't have are hidden.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  c:SetScript("OnLeave", GameTooltip_Hide)
  specChecks[spec] = c
  fprev = c
end

-- What you actually buy for `qty` of `id`, following the cheapest path down the production chain:
-- want[id] = amount. Pure given the cost function.
function ns.Leaves(id, qty, want, best, recipes, depth)
  local _, how = best(id)
  local rec = (depth or 0) < 8 and how == "craft" and recipes[id]
  if not rec then
    want[id] = (want[id] or 0) + qty
    return want
  end
  for rid, n in pairs(rec.reagents) do ns.Leaves(rid, qty * n / rec.makes, want, best, recipes, (depth or 0) + 1) end
  return want
end

-- At the auction house, clicking a craft rule searches its shopping list in Auctionator's Shopping
-- tab: what one station's worth of crafts needs, down the cheapest production chain, plus the
-- station (or what crafting it needs) only when "Shop for station" is ticked: usually you have
-- one already, and its share stays in the cost either way. Reagents a vendor sells are left out.
local SHOP_TRIES = 6 -- name lookups: retry every half second for up to 3 s before searching without them

local function ShopReagents(r, tries)
  if r.use or not (r.inputs and r.outputs) then return end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  local ahShown = (AuctionHouseFrame and AuctionHouseFrame:IsShown()) or (AuctionFrame and AuctionFrame:IsShown())
  if not (api and api.MultiSearchAdvanced and ahShown) then return end
  tries = tries or 1
  local crafts = r.station and CraftsPerStation() or 1
  local want, terms, vendor, missing = {}, {}, {}, {}
  for id, q in pairs(r.inputs) do ns.Leaves(id, q * crafts, want, Cost, ns.recipes) end
  if r.station and FlipRulesDB.shopStation then ns.Leaves(r.station, 1, want, Cost, ns.recipes) end
  for id, q in pairs(want) do
    local name, n = GetItemInfo(id), math.ceil(q - 1e-9)
    if not name then missing[#missing + 1] = id
    elseif VendorPrice(id) then vendor[#vendor + 1] = ("%s x%d"):format(name, n)
    else terms[#terms + 1] = { searchString = name, isExact = true, quantity = n } end
  end
  -- an item the client hasn't loaded has no name to search for: load it and try again shortly,
  -- rather than silently leaving it out (Heavy Hide, deep in a chain, was)
  if #missing > 0 and tries < SHOP_TRIES then
    for _, id in ipairs(missing) do
      if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    end
    return C_Timer.After(0.5, function() ShopReagents(r, tries + 1) end)
  end
  if #terms > 0 then
    local ok, err = pcall(api.MultiSearchAdvanced, ADDON, terms)
    if not ok then return print("|cff33ff99FlipRules|r Auctionator search failed: " .. tostring(err)) end
  end
  local list = {}
  for _, t in ipairs(terms) do list[#list + 1] = ("%s x%d"):format(t.searchString, t.quantity) end
  print(("|cff33ff99FlipRules|r %s, %d crafts: searching %s"):format(r.name, crafts, #list > 0 and table.concat(list, ", ") or "nothing"))
  if #vendor > 0 then print("|cff33ff99FlipRules|r   buy at a vendor: " .. table.concat(vendor, ", ")) end
  if #missing > 0 then
    local ids = {}
    for _, id in ipairs(missing) do ids[#ids + 1] = "item:" .. id end
    print("|cff33ff99FlipRules|r   |cffff4040not searched, the game didn't load their names:|r " .. table.concat(ids, ", "))
  end
end

local rows = {}
for i = 1, N_ROWS do
  local b = CreateFrame("Button", nil, frame)
  b:SetSize(LW, 18)
  b:SetPoint("TOPLEFT", LX, -46 - (i - 1) * 18)
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.sel = b:CreateTexture(nil, "BACKGROUND")
  b.sel:SetAllPoints()
  b.sel:SetColorTexture(1, 0.82, 0, 0.18)
  b.cols = {}
  for k, c in ipairs(COLS) do
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c[2], 0)
    fs:SetWidth(c[3]); fs:SetJustifyH(c[4]); fs:SetWordWrap(false)
    b.cols[k] = fs
  end
  b:SetScript("OnEnter", function(self) if self.entry then ShowBreakdown(self, self.entry) end end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self)
    if not self.entry then return end
    selected = self.entry.rule
    RefreshAll()
    ShopReagents(selected)
  end)
  rows[i] = b
end

local status = Text(-46 - N_ROWS * 18 - 4, "GameFontDisableSmall", LX, LW)

---------------------------------------------------------------- left bottom: drop statistics

local STATS_Y = -46 - N_ROWS * 18 - 28

local openBtn = CreateFrame("Button", "FlipRulesOpenButton", frame, "SecureActionButtonTemplate,UIPanelButtonTemplate")
openBtn:SetSize(230, 22)
openBtn:SetPoint("TOPLEFT", LX, STATS_Y)
openBtn:RegisterForClicks("AnyUp", "AnyDown")
StaticPopupDialogs.FLIPRULES_RESET = {
  text = "Clear all drop statistics for\n%s?",
  button1 = YES, button2 = NO,
  OnAccept = function()
    if selected then FlipRulesDB.stats[selected.name] = nil end
    RefreshAll()
  end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}
local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
resetBtn:SetSize(110, 22)
resetBtn:SetPoint("LEFT", openBtn, "RIGHT", 8, 0)
resetBtn:SetText("Reset stats")
resetBtn:SetScript("OnClick", function() if selected then StaticPopup_Show("FLIPRULES_RESET", selected.name) end end)

-- craft rules: how many crafts one placed station serves, which splits its cost
local perLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
perLabel:SetPoint("TOPLEFT", LX, STATS_Y - 5)
perLabel:SetText("Crafts per station:")
local perBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
perBox:SetSize(50, 20)
perBox:SetPoint("LEFT", perLabel, "RIGHT", 10, 0)
perBox:SetAutoFocus(false)
perBox:SetNumeric(true)
perBox:SetScript("OnEnterPressed", function(self)
  FlipRulesDB.craftsPerStation = math.max(1, tonumber(self:GetText()) or 10)
  self:ClearFocus()
  RefreshAll()
end)
perBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); RefreshAll() end)
perBox:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Crafts per station")
  GameTooltip:AddLine("Placing a camp station uses it up. Its cost is split over this many crafts. "
    .. "Same number for all tiers; press Enter to apply.", 1, 1, 1, true)
  GameTooltip:Show()
end)
perBox:SetScript("OnLeave", GameTooltip_Hide)

-- whether the Auctionator shopping list includes the station; the cost always carries its share
local shopStation = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
shopStation:SetSize(22, 22)
shopStation:SetPoint("LEFT", perBox, "RIGHT", 10, 0)
shopStation.label = shopStation:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
shopStation.label:SetPoint("LEFT", shopStation, "RIGHT", 0, 0)
shopStation.label:SetText("Shop for station")
shopStation:SetScript("OnClick", function(self) FlipRulesDB.shopStation = self:GetChecked() and true or false end)
shopStation:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Shop for station")
  GameTooltip:AddLine("Ticked: clicking an item at the auction house also searches the station (or what crafting it takes) in Auctionator. "
    .. "Leave it off when you already have one. Either way its share stays in the cost, split over the crafts per station.", 1, 1, 1, true)
  GameTooltip:Show()
end)
shopStation:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------- selling: one auction per click

-- The server takes one post per click and needs a moment between posts, so "bulk" is a button you
-- click repeatedly: each click posts the most valuable result of the selected rule still in your bags.
local POST_DURATION = 3 -- the longest the AH offers (24 h or 48 h depending on the client)
local POST_WAIT = 5     -- seconds to wait for the AH to confirm a post
local POST_FRESH = 60   -- re-check an item's price before posting when the last check is older
local SEARCH_WAIT = 5   -- seconds before giving up on a search answer
local ahOpen, posting, postQueue = false, nil, {}

-- Live price checks, one search at a time, the next when the AH says it's ready again.
-- An item with random suffixes ("of the Monkey") is listed once per variant, and an item search
-- finds only one of them; writ turn-ins take any variant, so the price is the cheapest of all.
-- So a check browses by name, which lists every variant with its cheapest price.
local searchQueue, searching, tried = {}, nil, {} -- tried[id] = GetTime() of the last search sent
local Pump

local function Sorts()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  return { { sortOrder = order, reverseSort = false } }
end

-- The search for `s` is done: keep what it found (cheapest not yours across every variant).
local function FinishSearch(s)
  if searching ~= s then return end
  searching = nil
  if FlipRulesDB then
    FlipRulesDB.live[s.id] = { min = s.best, n = s.n or 0, top = s.mins, variants = s.variants, t = time(), v = LIVE_V }
    ns.Hist(FlipRulesDB.hist, s.id, time(), s.best, s.n or 0)
  end
  Pump()
  RefreshAll()
end

-- Pure: from browse results, for item `id`: the cheapest variant price not yours, how many are
-- listed, the cheapest price of each variant (ascending, up to 5), how many variants, and the
-- cheapest variant holding an auction of yours when it is the cheapest of all (its own cheapest
-- may be yours, so it needs an item search to see the others).
function ns.CheapestVariant(results, id)
  local best, n, mins, variants, ownKey, ownMin = nil, 0, {}, 0, nil, nil
  for _, r in ipairs(results or {}) do
    local k = r.itemKey
    if k and k.itemID == id and r.minPrice and r.minPrice > 0 then
      variants = variants + 1
      n = n + (r.totalQuantity or 0)
      mins[#mins + 1] = r.minPrice
      if r.containsOwnerItem then
        if not ownMin or r.minPrice < ownMin then ownKey, ownMin = k, r.minPrice end
      elseif not best or r.minPrice < best then
        best = r.minPrice
      end
    end
  end
  table.sort(mins)
  for x = #mins, 6, -1 do mins[x] = nil end
  if ownMin and best and ownMin >= best then ownKey = nil end
  return best, n, mins, variants, ownKey
end

-- The variant with your auction in it: search it to see the cheapest that isn't yours.
local function SendKey(s, tries)
  if searching ~= s then return end
  local AH = C_AuctionHouse
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then
    if (tries or 0) < 8 then return C_Timer.After(0.5, function() SendKey(s, (tries or 0) + 1) end) end
    return FinishSearch(s)
  end
  if not pcall(AH.SendSearchQuery, s.key, Sorts(), true) then FinishSearch(s) end
end

local function OnBrowse()
  local s = searching
  if not (s and s.browse and not s.key) then return end
  local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
  if not ok or type(results) ~= "table" then return end
  local best, n, mins, variants, ownKey = ns.CheapestVariant(results, s.id)
  s.best, s.n, s.mins, s.variants = best, n, mins, variants
  if ownKey then
    s.key = ownKey
    return SendKey(s)
  end
  FinishSearch(s)
end

Pump = function()
  local AH = C_AuctionHouse
  if searching or not ahOpen or not (AH and AH.SendSearchQuery and AH.MakeItemKey) then return end
  if AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end -- THROTTLED_SYSTEM_READY pumps
  local id = table.remove(searchQueue, 1)
  if not id then return end
  local s = { id = id }
  searching, tried[id] = s, GetTime()
  local name, ok = GetItemInfo(id), false
  if name and AH.SendBrowseQuery then
    s.browse = true
    ok = pcall(AH.SendBrowseQuery, { searchString = name, sorts = Sorts(), filters = {}, itemClassFilters = {} })
  else -- name not loaded yet: an item search still finds the plain variant
    ok = pcall(AH.SendSearchQuery, AH.MakeItemKey(id), Sorts(), true)
  end
  if not ok then
    searching = nil
    return Pump()
  end
  C_Timer.After(SEARCH_WAIT, function()
    if searching ~= s then return end
    if s.variants then return FinishSearch(s) end -- the browse answered, the variant search didn't
    searching = nil
    Pump()
    RefreshAll()
  end)
end

local function Check(ids)
  for _, id in ipairs(ids) do
    local dup = searching and searching.id == id
    for _, q in ipairs(searchQueue) do dup = dup or q == id end
    if not dup then searchQueue[#searchQueue + 1] = id end
  end
  Pump()
end

-- Cheapest unit price not yours, and how many are listed. Pure.
function ns.Lowest(rows)
  local n, top = 0, {}
  for _, r in ipairs(rows) do
    if r.price and r.price > 0 and r.own < r.qty then
      n = n + r.qty - r.own
      top[#top + 1] = math.floor(r.price)
    end
  end
  table.sort(top)
  for i = #top, 6, -1 do top[i] = nil end -- the 5 cheapest auctions, for the sanity check
  return top[1], n, top
end

local function ReadResults(event, arg) -- arg: the item id (commodities) or the item key
  local AH, rows = C_AuctionHouse, {}
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    for i = 1, math.min(40, AH.GetNumCommoditySearchResults(arg) or 0) do
      local r = AH.GetCommoditySearchResultInfo(arg, i)
      if r then rows[#rows + 1] = { price = r.unitPrice, qty = r.quantity or 1, own = r.numOwnerItems or 0 } end
    end
    return arg, rows
  end
  for i = 1, math.min(40, AH.GetNumItemSearchResults(arg) or 0) do -- sorted cheapest first
    local r = AH.GetItemSearchResultInfo(arg, i)
    if r and r.buyoutAmount then
      -- buyoutAmount is already per item on this client: dividing by the stack size read a
      -- 20-stack at 3s each as 15c (saved data, 2026-11-22). shortcut: inferred, not documented.
      local q = math.max(1, r.quantity or 1)
      rows[#rows + 1] = { price = r.buyoutAmount, qty = q, own = r.containsOwnerItem and q or 0 }
    end
  end
  return arg.itemID, rows
end

local function OnResults(event, arg)
  local ok, id, rows = pcall(ReadResults, event, arg)
  if not ok or not id or not FlipRulesDB then return end
  local min, n, top = ns.Lowest(rows)
  local s = searching
  if s and s.id == id and s.key then -- the variant holding your auction: its cheapest not yours
    if min and (not s.best or min < s.best) then s.best = min end
    return FinishSearch(s)
  end
  if s and s.id == id and not s.browse then -- plain item search (name wasn't loaded)
    s.best, s.n, s.mins, s.variants = min, n, top, nil
    return FinishSearch(s)
  end
  -- a search you did yourself: one variant only, so it can't replace an all-variant check
  local l = FlipRulesDB.live[id]
  if l and l.variants and l.variants > 1 and time() - l.t <= LIVE_FRESH then return end
  FlipRulesDB.live[id] = { min = min, n = n, top = top, t = time(), v = LIVE_V }
  ns.Hist(FlipRulesDB.hist, id, time(), min, n)
end

local function RuleItems(r)
  local ids = {}
  for id in pairs(r.inputs or {}) do ids[#ids + 1] = id end
  for _, id in ipairs(r.pool or {}) do ids[#ids + 1] = id end
  for id in pairs(r.outputs or {}) do ids[#ids + 1] = id end
  if r.station then ids[#ids + 1] = r.station end
  -- and everything down the production chains of the inputs and the station
  local seen = {}
  for _, id in ipairs(ids) do seen[id] = true end
  local i = 1
  while ids[i] do
    local rec = r.inputs and ns.recipes[ids[i]]
    for rid in pairs(rec and rec.reagents or {}) do
      if not seen[rid] then seen[rid] = true; ids[#ids + 1] = rid end
    end
    i = i + 1
  end
  return ids
end

-- Cheapest listing minus 1 copper (no listing: `fallback`). Pure.
function ns.PostPrice(min, fallback)
  local p = min and min - 1 or fallback
  return p and p >= 1 and math.floor(p) or nil
end

local function PostQueue(r)
  local ids, q, bags, price = {}, {}, BagCounts(), PriceFor(r)
  for _, id in ipairs(r.pool or {}) do ids[#ids + 1] = id end
  for id in pairs(r.outputs or {}) do ids[#ids + 1] = id end
  for _, id in ipairs(ids) do
    local n = bags[id] or 0
    if n > 0 then
      local row = AHRow(id)
      q[#q + 1] = { id = id, n = n, cur = row and row.minBuyout, price = ns.PostPrice(row and row.minBuyout, price(id, false)) }
    end
  end
  -- most valuable first; unpriced ones last (shown, never posted)
  table.sort(q, function(a, b) return (a.price or -1) * a.n > (b.price or -1) * b.n end)
  return q
end

local function NextPost()
  for _, it in ipairs(postQueue) do if it.price then return it end end
end

local function FindSlot(id)
  for bag = 0, 4 do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and info.itemID == id and not info.isLocked then return bag, slot, info.stackCount or 1 end
    end
  end
end

local function Say(s) print("|cff33ff99FlipRules|r " .. s) end

-- No confirmation or error from the AH is not a success: say so instead of claiming "posted".
local function WaitPost(p)
  C_Timer.After(POST_WAIT, function()
    if posting ~= p then return end
    posting = nil
    Say(("no answer from the auction house for %s, check your auctions."):format(Link(p.id)))
    RefreshAll()
  end)
end

local function PostDone()
  if not posting then return end
  Say(("posted %d x %s at %s each"):format(posting.qty, Link(posting.id), Money(posting.price)))
  posting = nil
end

local function CallPost(p, confirm)
  local AH = C_AuctionHouse
  if p.commodity then
    return pcall(confirm and AH.ConfirmPostCommodity or AH.PostCommodity, p.loc, POST_DURATION, p.qty, p.price)
  end
  return pcall(confirm and AH.ConfirmPostItem or AH.PostItem, p.loc, POST_DURATION, p.qty, nil, p.price)
end

local function Post(item)
  local AH = C_AuctionHouse
  if not (ahOpen and AH and AH.PostItem and ItemLocation) then return Say("open the auction house first.") end
  if posting or (AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady()) then
    return Say("the auction house is still busy with the last post, click again in a moment.")
  end
  if not Live(item.id, POST_FRESH) then -- posting needs a fresh click, so this click only checks
    Check({ item.id })
    return Say(("checking the current price of %s, click again in a moment."):format(Link(item.id)))
  end
  local bag, slot, stack = FindSlot(item.id)
  if not bag then return end
  local p = { id = item.id, price = item.price, loc = ItemLocation:CreateFromBagAndSlot(bag, slot) }
  if AH.GetItemCommodityStatus and AH.PostCommodity then
    local ok, s = pcall(AH.GetItemCommodityStatus, p.loc)
    p.commodity = ok and s == (Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2)
  end
  p.qty = p.commodity and item.n or stack -- commodities go up in one post; other items one stack per post
  local ok, needs = CallPost(p)
  if not ok then return Say("couldn't post: " .. tostring(needs)) end
  posting = p
  if needs then
    p.asking = true
    StaticPopup_Show("FLIPRULES_POST_CONFIRM", ("%d x %s at %s each"):format(p.qty, Name(p.id), Money(p.price)), nil, p)
  else
    WaitPost(p)
  end
end

-- The game's own confirm box doesn't work for addon posts, so ours replaces it (see POST_WARNING).
StaticPopupDialogs.FLIPRULES_POST_CONFIRM = {
  text = "The auction house asks you to confirm this post:\n%s",
  button1 = YES, button2 = NO,
  OnAccept = function(_, p)
    if posting ~= p then return end
    p.asking = nil
    local ok, err = CallPost(p, true)
    if ok then return WaitPost(p) end
    posting = nil
    Say("couldn't post: " .. tostring(err))
  end,
  OnCancel = function(_, p) if posting == p then posting = nil end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local postBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
postBtn:SetSize(140, 22)
postBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
postBtn:SetScript("OnClick", function() local it = NextPost() if it then Post(it) end end)
postBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Post results on the auction house")
  GameTooltip:AddLine("One click posts one auction. Click again for the next.", 1, 1, 1, true)
  GameTooltip:AddLine("Price: cheapest listing minus 1 copper, checked live right before each post (your own auctions left out).", 0.7, 0.7, 0.7, true)
  GameTooltip:AddLine("The list below shows what goes up next, at which price.", 0.7, 0.7, 0.7, true)
  GameTooltip:Show()
end)
postBtn:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------- mailing: writs to your selling character

-- One click = one mail of up to 12 stacks. Sends every item a rule can drop (the opened writs);
-- the sealed writs stay, since a low-level character can't open them.
local MAIL_MAX = ATTACHMENTS_MAX_SEND or 12
local mailOpen, mailing = false, nil
local Pickup = (C_Container and C_Container.PickupContainerItem) or PickupContainerItem

-- Your mail characters, comma separated: mail goes to the first one you aren't logged in as. Pure.
function ns.MailTarget(chars, me)
  for name in (chars or ""):gmatch("[^,]+") do
    name = strtrim(name)
    if name ~= "" and name:lower() ~= (me or ""):lower() then return name end
  end
  return ""
end
local MAIL_CHARS = "Milchiger Abgang, Wealth Peon"
local function MailTo() return ns.MailTarget(FlipRulesDB.mailChars or MAIL_CHARS, UnitName("player")) end

-- What the mail button sends: Leatherworking tab = the reagents of its rules (down the chains,
-- stations too); anywhere else = every item a rule can drop (the opened writs).
local function MailWhat() return FlipRulesDB.filter == "Leatherworking" and "reagents" or "writs" end
local function MailIDs()
  local ids = {}
  if MailWhat() == "writs" then
    for _, r in ipairs(ns.rules) do for _, id in ipairs(r.pool or {}) do ids[id] = true end end
    return ids
  end
  for _, r in ipairs(ns.rules) do
    if r.group == "Leatherworking" then
      local out = r.outputs or {}
      for _, id in ipairs(RuleItems(r)) do if not out[id] then ids[id] = true end end
    end
  end
  return ids
end

local function MailSlots()
  local ids, slots = MailIDs(), {}
  for bag = 0, 4 do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and ids[info.itemID] and not info.isLocked and not info.isBound then
        slots[#slots + 1] = { bag = bag, slot = slot }
      end
    end
  end
  return slots
end

local function SendBatch()
  local to = MailTo()
  if not mailOpen then return Say("open a mailbox first.") end
  if mailing then return Say("still sending the last mail, click again in a moment.") end
  if to == "" then return Say("type your characters in the 'Mail between' box first.") end
  for i = 1, MAIL_MAX do
    if GetSendMailItem(i) then return Say("the Send Mail tab already has attachments: clear them first.") end
  end
  if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end -- attaching needs the Send Mail tab
  local slots = MailSlots()
  local n = math.min(MAIL_MAX, #slots)
  local kind = MailWhat()
  if n == 0 then return Say(("no %s in your bags."):format(kind)) end
  for i = 1, n do
    ClearCursor()
    Pickup(slots[i].bag, slots[i].slot)
    ClickSendMailItemButton(i)
  end
  ClearCursor()
  mailing = { to = to, n = n, kind = kind }
  SendMail(to, ("%s (%d)"):format(kind == "writs" and "Writs" or "LW reagents", n), "")
end

-- Mail you send by hand: the recipient is your other character, the subject the first item's
-- name, unless you typed them yourself.
local function FillSendMail()
  if not mailOpen or mailing or not SendMailNameEditBox then return end
  if SendMailNameEditBox:GetText() == "" and not SendMailNameEditBox:HasFocus() then SendMailNameEditBox:SetText(MailTo()) end
  if SendMailSubjectEditBox and SendMailSubjectEditBox:GetText() == "" then
    for i = 1, MAIL_MAX do
      local name = GetSendMailItem(i)
      if name then SendMailSubjectEditBox:SetText(name) break end
    end
  end
end

local mailBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
mailBtn:SetSize(140, 22)
mailBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
mailBtn:SetScript("OnClick", SendBatch)
mailBtn:SetScript("OnEnter", function(self)
  local stacks = #MailSlots()
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine(("Mail %s to %s"):format(MailWhat(), MailTo()))
  GameTooltip:AddLine(("One click sends one mail of up to %d stacks. %d stacks in your bags: %d mails."):format(
    MAIL_MAX, stacks, math.ceil(stacks / MAIL_MAX)), 1, 1, 1, true)
  GameTooltip:AddLine(MailWhat() == "writs"
    and "Every Craftsman's Writ the rules know is sent; sealed writs stay. On the Leatherworking tab this sends reagents instead."
    or "Every reagent of the Leatherworking rules is sent: leather, hides, thread, salt, dyes, the stations. Crafted items stay.",
    0.7, 0.7, 0.7, true)
  GameTooltip:AddLine("Postage applies per mail. Your characters are set in the 'Mail between' box at the bottom.", 0.7, 0.7, 0.7, true)
  GameTooltip:Show()
end)
mailBtn:SetScript("OnLeave", GameTooltip_Hide)
mailBtn:Hide()

---------------------------------------------------------------- deleting writs worth less than 1 silver

local delBtn, CheapSlots
do
local CHEAP = 100 -- copper: opened writs whose live price is below this are deleted
local CHEAP_AGE = 24 * 3600 -- your own live check counts this long; AHledger's table is never used here

-- Which bag stacks to delete: only items with a live price under `limit`; an item never checked
-- (or with no listings) is never deleted. Pure: items = { {id, ...}, ... }, price(id) -> copper|nil.
function ns.CheapStacks(items, price, limit)
  local out = {}
  for _, it in ipairs(items) do
    local p = price(it.id)
    if p and p < limit then it.price = p; out[#out + 1] = it end
  end
  return out
end

CheapSlots = function()
  local ids, items = {}, {}
  for _, r in ipairs(ns.rules) do for _, id in ipairs(r.pool or {}) do ids[id] = true end end
  for bag = 0, 4 do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and ids[info.itemID] and not info.isLocked then
        items[#items + 1] = { id = info.itemID, bag = bag, slot = slot, n = info.stackCount or 1, link = info.hyperlink }
      end
    end
  end
  local list = ns.CheapStacks(items, function(id) local l = Live(id, CHEAP_AGE) return l and l.min end, CHEAP)
  for _, it in ipairs(list) do it.t = Live(it.id, CHEAP_AGE).t end
  return list
end

local function Ago(t)
  local m = math.floor((time() - t) / 60)
  return m < 60 and ("%dm ago"):format(m) or ("%dh ago"):format(math.floor(m / 60))
end

delBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
delBtn:SetSize(140, 22)
delBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
delBtn:SetScript("OnClick", function() -- one stack per click, the one named in the tooltip
  local it = CheapSlots()[1]
  if not it then return end
  ClearCursor()
  Pickup(it.bag, it.slot)
  if CursorHasItem() then
    DeleteCursorItem()
    Say(("deleted %s x%d (cheapest listing %s, checked %s)"):format(it.link or it.id, it.n, Money(it.price), Ago(it.t)))
  end
  ClearCursor()
end)
delBtn:SetScript("OnEnter", function(self)
  local list = CheapSlots()
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Delete writs worth less than " .. Money(CHEAP))
  GameTooltip:AddLine("One click deletes one stack, the first below. This can't be undone.", 1, 0.3, 0.3, true)
  GameTooltip:AddLine("Price = the cheapest listing from your own Check prices in the last 24 hours "
    .. "(not AHledger). Writs you haven't checked are kept.", 0.7, 0.7, 0.7, true)
  for i, it in ipairs(list) do
    if i > 15 then GameTooltip:AddLine(("... and %d more"):format(#list - 15)) break end
    GameTooltip:AddDoubleLine(("%s x%d"):format(it.link or it.id, it.n),
      ("%s  (%s)"):format(Money(it.price), Ago(it.t)), 1, 1, 1, 1, 1, 1)
  end
  GameTooltip:Show()
end)
delBtn:SetScript("OnLeave", GameTooltip_Hide)
delBtn:Hide()
end

---------------------------------------------------------------- earnings: auction mail you take

-- FlipRulesDB.earn[rule.name] = { sold, revenue, bought, spent }, from auction mail taken on any
-- character: "Auction successful" money (after the AH cut) for a rule's drops counts as revenue,
-- "Auction won" for its inputs (a sealed writ you bought) as spent.
local function SubjectPattern(global, english)
  local s = type(_G[global]) == "string" and _G[global] or english
  -- the item name can sit anywhere in the client's text ("%s" or "%1$s"): match the whole subject
  s = s:gsub("%%%d?%$?s", "\1"):gsub("%p", "%%%0"):gsub("\1", ".+")
  return "^" .. s .. "$"
end
function ns.Subject(global, english, item) -- the subject the client writes, for the self-test
  return ((type(_G[global]) == "string" and _G[global] or english):gsub("%%%d?%$?s", item))
end

local SOLD_SUBJECT, WON_SUBJECT, EXPIRED_SUBJECT, CANCELLED_SUBJECT
function ns.MailKind(subject)
  SOLD_SUBJECT = SOLD_SUBJECT or SubjectPattern("AUCTION_SOLD_MAIL_SUBJECT", "Auction successful: %s")
  WON_SUBJECT = WON_SUBJECT or SubjectPattern("AUCTION_WON_MAIL_SUBJECT", "Auction won: %s")
  EXPIRED_SUBJECT = EXPIRED_SUBJECT or SubjectPattern("AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired: %s")
  CANCELLED_SUBJECT = CANCELLED_SUBJECT or SubjectPattern("AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled: %s")
  subject = tostring(subject or "")
  return subject:find(SOLD_SUBJECT) and "sold" or subject:find(WON_SUBJECT) and "won"
    or subject:find(EXPIRED_SUBJECT) and "expired" or subject:find(CANCELLED_SUBJECT) and "cancelled" or nil
end

---------------------------------------------------------------- your own record: price history, posts and how they end

-- FlipRulesDB.hist[id][hour] = { lo = lowest cheapest-listing seen that hour, min = newest one, n = newest
-- listed count, t = when }, hour = time() / 3600: one point per scan or live check (checks within the
-- same hour merge), from your live checks and AHledger's scans and table, kept 30 days. Pure.
do
local KEEP = 30 * 24
function ns.Slot(t) return math.floor(t / 3600) end
-- extra (optional, AHledger's table): { md = median, pd = sold per day } at that update
function ns.Hist(hist, id, t, min, n, extra)
  if not hist then return end
  local h = hist[id] or {}
  hist[id] = h
  local d = h[ns.Slot(t)] or {}
  h[ns.Slot(t)] = d
  if t >= (d.t or 0) then d.min, d.n, d.t = min, n, t end -- sources arrive out of order: newest wins
  if min and (not d.lo or min < d.lo) then d.lo = min end
  if extra then d.md, d.pd = extra.md or d.md, extra.pd or d.pd end
end
function ns.PruneHist(hist, t)
  for id, h in pairs(hist) do
    local old = {} -- day keys from before 2026-11-23 move to the hour they were seen (no new keys mid-pairs)
    for k in pairs(h) do if k < 100000 then old[#old + 1] = k end end
    for _, k in ipairs(old) do
      local d = h[k]
      h[k] = nil
      local slot = ns.Slot(d.t or (k * 86400 + 43200))
      if not h[slot] then h[slot] = d end
    end
    for k in pairs(h) do if k < ns.Slot(t) - KEEP then h[k] = nil end end
    if not next(h) then hist[id] = nil end
  end
end
end

-- FlipRulesDB.track[id] = { posted, sold, expired, cancelled, revenue (after cut), soldListed (your
-- list price of what sold), cost (production cost of what sold, when known), costN, hours, timed,
-- open = { { t, price, qty, cost } } oldest first }. A sale, expiry or cancel closes the oldest open
-- posts first. kind: "post" / "sold" / "expired" / "cancelled". Pure.
function ns.Track(track, kind, id, qty, t, price, cost)
  local r = track[id] or { posted = 0, sold = 0, expired = 0, cancelled = 0, revenue = 0, soldListed = 0,
    cost = 0, costN = 0, hours = 0, timed = 0, open = {} }
  track[id] = r
  if kind == "post" then
    r.posted = r.posted + qty
    r.open[#r.open + 1] = { t = t, price = price, qty = qty, cost = cost }
    return r
  end
  r[kind] = r[kind] + qty
  if kind == "sold" then r.revenue = r.revenue + (price or 0) end -- price: the mail's money for all of them
  local left = qty
  while left > 0 and r.open[1] do
    local o = r.open[1]
    local k = math.min(left, o.qty)
    if kind == "sold" then
      r.soldListed = r.soldListed + k * (o.price or 0)
      r.hours, r.timed = r.hours + k * (t - o.t) / 3600, r.timed + k
      if o.cost then r.cost, r.costN = r.cost + k * o.cost, r.costN + k end
    end
    o.qty, left = o.qty - k, left - k
    if o.qty <= 0 then table.remove(r.open, 1) end
  end
  return r
end

-- What your record says: sell-through, realized price, hours to sell, profit per sold item. Pure.
function ns.TrackSummary(r)
  if not r then return nil end
  local ended = r.sold + r.expired + r.cancelled
  local open = 0
  for _, o in ipairs(r.open) do open = open + o.qty end
  return {
    ended = ended, open = open,
    through = ended > 0 and r.sold / ended or nil, -- share of ended posts that sold
    each = r.sold > 0 and r.revenue / r.sold or nil, -- after the AH cut
    ofList = r.soldListed > 0 and r.revenue / r.soldListed or nil, -- what you got / what you asked (cut included)
    hours = r.timed > 0 and r.hours / r.timed or nil,
    profit = r.costN > 0 and (r.revenue / r.sold - r.cost / r.costN) or nil,
  }
end

-- Pure: adds one mail to the per-rule totals.
function ns.Earn(earn, kind, rname, qty, money)
  local e = earn[rname] or { sold = 0, revenue = 0, bought = 0, spent = 0 }
  earn[rname] = e
  if kind == "sold" then
    e.sold, e.revenue = e.sold + qty, e.revenue + money
  else
    e.bought, e.spent = e.bought + qty, e.spent + money
  end
  return e
end

local takenMail = {} -- shortcut: a take that fails (full bags) and is retried after a reload counts twice; rare
local function RecordMail(index)
  if not (GetInboxHeaderInfo and FlipRulesDB) then return end
  local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(index)
  local kind = ns.MailKind(subject)
  if not kind then return end
  local key = table.concat({ tostring(subject), tostring(money), tostring(daysLeft) }, "|")
  if takenMail[key] then return end
  local itemName, bid, buyout, count, id, _
  if GetInboxInvoiceInfo then _, itemName, _, bid, buyout, _, _, _, _, _, count = GetInboxInvoiceInfo(index) end
  if GetInboxItem then
    local c
    _, id, _, c = GetInboxItem(index, 1)
    count = count or c
  end
  itemName = itemName or tostring(subject):match(":%s*(.+)$")
  local rule, known
  for _, r in ipairs(ns.rules) do
    for _, x in ipairs(RuleItems(r)) do
      if not id and Name(x) == itemName then id = x end
      known = known or x == id
    end
    if id and (kind == "sold" and InPool(r, id) or kind == "won" and r.inputs and r.inputs[id]) then rule = r break end
  end
  if id and (known or rule) and kind ~= "won" then -- your record of how each post ended
    takenMail[key] = true
    ns.Track(FlipRulesDB.track, kind, id, count or 1, time(), money)
  end
  if not rule or kind == "expired" or kind == "cancelled" then return RefreshAll() end
  takenMail[key] = true
  local paid = kind == "sold" and (money or 0) or (buyout and buyout > 0 and buyout or bid or 0)
  local e = ns.Earn(FlipRulesDB.earn, kind, rule.name, count or 1, paid)
  Say(("%s %s %s: %s net so far"):format(kind == "sold" and "sold" or "bought", Link(id), Money(paid),
    Money(e.revenue - e.spent)))
  RefreshAll()
end
for _, fn in ipairs({ "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem" }) do
  if _G[fn] then hooksecurefunc(fn, function(index) pcall(RecordMail, index) end) end
end

-- Every post of a rule's item, yours or by hand, with its production cost at that moment (craft rules).
-- The AH confirms with AUCTION_HOUSE_AUCTION_CREATED, which names nothing: remember what was sent.
do
local pendingPost
local function PostCost(id)
  for _, r in ipairs(ns.rules) do
    if r.group and r.outputs and r.outputs[id] then
      local c = Evaluated(r).cost
      return c and c / r.outputs[id]
    end
  end
end
local function NotePost(loc, qty, price)
  local id = loc and C_Item and C_Item.GetItemID and C_Item.GetItemID(loc)
  pendingPost = id and { id = id, qty = qty or 1, price = price } or nil
end
function ns.PostCreated()
  local p = pendingPost
  pendingPost = nil
  if not (p and FlipRulesDB and FlipRulesDB.track) then return end
  for _, r in ipairs(ns.rules) do
    for _, x in ipairs(RuleItems(r)) do
      if x == p.id then return ns.Track(FlipRulesDB.track, "post", p.id, p.qty, time(), p.price, PostCost(p.id)) end
    end
  end
end
if C_AuctionHouse then
  for _, fn in ipairs({ "PostItem", "ConfirmPostItem" }) do
    if C_AuctionHouse[fn] then
      hooksecurefunc(C_AuctionHouse, fn, function(loc, _, qty, bid, buyout) pcall(NotePost, loc, qty, buyout or bid) end)
    end
  end
  for _, fn in ipairs({ "PostCommodity", "ConfirmPostCommodity" }) do
    if C_AuctionHouse[fn] then
      hooksecurefunc(C_AuctionHouse, fn, function(loc, _, qty, unit) pcall(NotePost, loc, qty, unit) end)
    end
  end
end

end

-- AHledger as a second source for the price history: its price table (one point per update) and the
-- full scans it keeps (AHledgerDB.scans, "id:stack:buyout:bid:time;..."), read once each, only
-- for items the rules use and only scans of your own server.

-- Reads up to `max` listings of `data` from `pos` into acc[id] = { min = unit price, n = listed }
-- for ids in `wanted`. Returns where to go on, or nil when done. Pure.
function ns.ScanStep(data, pos, wanted, acc, max)
  for _ = 1, max do
    local s, e, id, stack, buyout = data:find("(%d+):(%d+):(%d+):%d+:%d+", pos)
    if not s then return nil end
    pos = e + 1
    id = tonumber(id)
    if wanted[id] then
      stack, buyout = tonumber(stack), tonumber(buyout)
      if stack > 0 then
        local a = acc[id] or { n = 0 }
        acc[id] = a
        a.n = a.n + stack
        local unit = buyout / stack -- scans store the stack's buyout (AHledger divides it too)
        if buyout > 0 and (not a.min or unit < a.min) then a.min = math.floor(unit + 0.5) end
      end
    end
  end
  return pos
end

do
local STEP = 20000 -- listings a frame
local function Server() return tonumber((UnitGUID("player") or ""):match("^Player%-(%d+)%-")) end
local function Wanted()
  local w = {}
  for _, r in ipairs(ns.rules) do for _, id in ipairs(RuleItems(r)) do w[id] = true end end
  return w
end
local busy = false
ns.ImportAHledger = function()
  if busy or not FlipRulesDB then return end
  local H, done, wanted = FlipRulesDB.hist, FlipRulesDB.histScans or {}, Wanted()
  FlipRulesDB.histScans = done
  if AHledgerAPI and AHledgerAPI.GetPrice then -- the price table: lowest listing and count at its update
    for id in pairs(wanted) do
      local p = AHledgerAPI.GetPrice(id)
      if p and p.updated and not p.snapshot then
        ns.Hist(H, id, p.updated, p.minBuyout, p.quantity, { md = p.median, pd = p.soldPerDay })
      end
    end
  end
  local me, faction, oldest, todo = Server(), UnitFactionGroup("player"), time() - 30 * 86400, {}
  for _, sc in ipairs(type(AHledgerDB) == "table" and type(AHledgerDB.scans) == "table" and AHledgerDB.scans or {}) do
    local key = ("%s:%s"):format(tostring(sc.ts), tostring(sc.server))
    -- WoW Forever is one mega server: every scan of your faction is your auction house. A scan with
    -- another server number is still skipped. shortcut: assumes one account playing; revisit if realms split
    local here = sc.faction == faction and (sc.server == nil or sc.server == me)
    if sc.full and type(sc.data) == "string" and sc.ts and sc.ts > oldest and here and not done[key] then
      todo[#todo + 1] = { sc = sc, key = key }
    end
  end
  if #todo == 0 then return end
  busy = true
  local i, pos, acc = 1, 1, {}
  local function step()
    local job = todo[i]
    pos = ns.ScanStep(job.sc.data, pos, wanted, acc, STEP)
    if not pos then
      for id in pairs(wanted) do
        local a = acc[id]
        ns.Hist(H, id, job.sc.ts, a and a.min, a and a.n or 0) -- not in a full scan: none listed
      end
      done[job.key] = true
      i, pos, acc = i + 1, 1, {}
      if not todo[i] then
        busy = false
        Say(("added %d AHledger scan%s to the price history."):format(#todo, #todo == 1 and "" or "s"))
        return RefreshAll()
      end
    end
    C_Timer.After(0, step)
  end
  C_Timer.After(0, step)
end
end

-- Your own record of an item: how your posts ended and the cheapest listing by day.
local function RecordLines(id, L, pad)
  local t = FlipRulesDB.track and FlipRulesDB.track[id]
  local s = ns.TrackSummary(t)
  if s then
    L[#L + 1] = ("%sPosted %d: |cff40ff40sold %d|r, |cffff6060expired %d|r, cancelled %d, %d still up"):format(
      pad, t.posted, t.sold, t.expired, t.cancelled, s.open)
    if s.through then
      L[#L + 1] = ("%s%s%.0f%%|r of ended posts sold%s"):format(pad, s.through >= 0.6 and "|cff40ff40" or "|cffff6060",
        100 * s.through, s.hours and (", after %.0f h on average"):format(s.hours) or "")
    end
    if s.each then
      L[#L + 1] = ("%sYou got %s each after the cut%s%s"):format(pad, Money(s.each),
        s.ofList and (" |cff999999(%.0f%% of your list price)|r"):format(100 * s.ofList) or "",
        s.profit and ("; profit %s per sold craft"):format(Money(s.profit)) or "")
    end
  else
    L[#L + 1] = pad .. "|cff999999No posts recorded yet: counted from now on, ended by the auction mail you take.|r"
  end
  local h = FlipRulesDB.hist and FlipRulesDB.hist[id]
  if h then
    local byDay, days = {}, {}
    local slots = {}
    for k in pairs(h) do slots[#slots + 1] = k end
    table.sort(slots)
    for _, k in ipairs(slots) do -- the day's low, and the count of its last point
      local x, dk = h[k], date("%m-%d", k * 3600)
      local d = byDay[dk]
      if not d then d = {}; byDay[dk] = d; days[#days + 1] = dk end
      if (x.lo or x.min) and (not d.lo or (x.lo or x.min) < d.lo) then d.lo = x.lo or x.min end
      d.n = x.n
    end
    local parts = {}
    for i = math.max(1, #days - 6), #days do
      local x = byDay[days[i]]
      parts[#parts + 1] = ("%s %s |cff999999(%d)|r"):format(days[i], Money(x.lo), x.n or 0)
    end
    L[#L + 1] = pad .. "Cheapest listing by day (listed): " .. table.concat(parts, ",  ")
    local tr = {}
    for _, k in ipairs(slots) do
      local x = h[k]
      if x.pd or x.md then tr[#tr + 1] = ("%s %s, %s/day"):format(date("%m-%d", k * 3600), Money(x.md), x.pd and ("%.1f"):format(x.pd) or "?") end
    end
    for i = 1, #tr - 5 do table.remove(tr, 1) end
    if #tr > 0 then L[#L + 1] = pad .. "AHledger median, sold/day by update: " .. table.concat(tr, ",  ") end
  end
end

-- Sell list: replaces the drop statistics while the auction house is open, so you can check every
-- price before it goes up. Hover the icon for the item and where its prices come from.
local SELL_ROWS, SELL_H = 11, 22
local sellArea = CreateFrame("Frame", nil, frame)
sellArea:SetPoint("TOPLEFT", frame, "TOPLEFT", LX, STATS_Y - 30)
sellArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LX + LW, 40)
sellArea:EnableMouseWheel(true)
local sellOffset = 0
local SELL_COLS = { { "Item", 24, 236, "LEFT" }, { "Qty", 262, 34, "RIGHT" }, { "Cheapest now", 300, 95, "RIGHT" }, { "You list at", 400, 95, "RIGHT" } }
for _, c in ipairs(SELL_COLS) do
  local h = sellArea:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h:SetPoint("TOPLEFT", c[2], 0)
  h:SetWidth(c[3])
  h:SetJustifyH(c[4])
  h:SetText(c[1])
end
local sellEmpty = sellArea:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
sellEmpty:SetPoint("TOPLEFT", 0, -22)
sellEmpty:SetText("None of this rule's results are in your bags.")

local function SellTooltip(self)
  local it = self.item
  if not it then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  GameTooltip:SetItemByID(it.id)
  GameTooltip:AddLine(" ")
  local l, r = Live(it.id), AHledgerAPI and AHledgerAPI.GetPrice(it.id)
  if l then
    GameTooltip:AddDoubleLine("Cheapest now (live)", l.min and Money(l.min) or "none listed", 1, 0.82, 0, 1, 1, 1)
    local top = {}
    for i, p in ipairs(l.top or {}) do top[i] = Money(p) end
    local many = (l.variants or 0) > 1
    if #top > 0 then
      GameTooltip:AddLine((many and ("Cheapest per variant (%d variants, any one counts): ") or "Cheapest auctions: "):format(l.variants)
        .. table.concat(top, ", "), 0.8, 0.8, 0.8, true)
    end
    GameTooltip:AddLine(("%d listed by others, checked %d s ago"):format(l.n or 0, time() - l.t), 0.6, 0.6, 0.6)
  else
    GameTooltip:AddLine("Not checked live yet: prices are AHledger's.", 1, 0.5, 0.25)
  end
  if r then
    GameTooltip:AddDoubleLine("AHledger lowest", Money(r.minBuyout), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("AHledger median today / 7d", Money(r.median) .. " / " .. Money(r.median7d), 0.8, 0.8, 0.8, 1, 1, 1)
  end
  GameTooltip:AddDoubleLine("You list at", it.price and Money(it.price) or "not posted (no price)", 0.2, 1, 0.6, 1, 1, 1)
  local rec = {}
  RecordLines(it.id, rec, "")
  GameTooltip:AddLine("Your record", 1, 0.82, 0)
  for _, line in ipairs(rec) do GameTooltip:AddLine(line, 1, 1, 1, true) end
  GameTooltip:AddLine(AHledgerAPI and AHledgerAPI.CREDIT or "", 0.5, 0.5, 0.5)
  GameTooltip:Show()
end

local sellRows = {}
for i = 1, SELL_ROWS do
  local row = CreateFrame("Frame", nil, sellArea)
  row:SetSize(LW, SELL_H)
  row:SetPoint("TOPLEFT", 0, -16 - (i - 1) * SELL_H)
  row.next = row:CreateTexture(nil, "BACKGROUND")
  row.next:SetAllPoints()
  row.next:SetColorTexture(1, 0.82, 0, 0.15)
  row.icon = CreateFrame("Button", nil, row)
  row.icon:SetSize(20, 20)
  row.icon:SetPoint("LEFT", 0, 0)
  row.icon.tex = row.icon:CreateTexture(nil, "ARTWORK")
  row.icon.tex:SetAllPoints()
  row.icon:SetScript("OnEnter", SellTooltip)
  row.icon:SetScript("OnLeave", GameTooltip_Hide)
  row.cols = {}
  for c, col in ipairs(SELL_COLS) do
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", col[2], 0)
    fs:SetWidth(col[3])
    fs:SetJustifyH(col[4])
    fs:SetWordWrap(false)
    row.cols[c] = fs
  end
  sellRows[i] = row
end

local function RefreshSell()
  sellOffset = math.max(0, math.min(sellOffset, #postQueue - SELL_ROWS))
  local nxt = NextPost()
  sellEmpty:SetShown(#postQueue == 0)
  for i, row in ipairs(sellRows) do
    local it = postQueue[sellOffset + i]
    row.item = it
    row.icon.item = it
    if it then
      row.icon.tex:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(it.id))
      row.cols[1]:SetText(Link(it.id))
      row.cols[2]:SetText(it.n)
      local live = Live(it.id)
      row.cols[3]:SetText(live and (live.min and Money(live.min) or "none") or ("|cff999999%s ?|r"):format(it.cur and Money(it.cur) or ""))
      row.cols[4]:SetText(it.price and Money(it.price) or "|cff999999-|r")
      row.next:SetShown(it == nxt)
      row:Show()
    else
      row:Hide()
    end
  end
end
sellArea:SetScript("OnMouseWheel", function(_, delta) sellOffset = sellOffset - delta * 3; RefreshSell() end)

local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", LX, STATS_Y - 30)
scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LX + LW - 22, 40)
local child = CreateFrame("Frame", nil, scroll)
child:SetSize(LW - 30, 1)
scroll:SetScrollChild(child)
local body = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
body:SetPoint("TOPLEFT")
body:SetWidth(LW - 30)
body:SetJustifyH("LEFT")
body:SetSpacing(2)

-- 95% margin of error for a share p seen in n tries (normal approximation).
local function Margin(p, n) return n > 0 and 1.96 * math.sqrt(p * (1 - p) / n) or 0 end

-- Production cost table for a craft rule: each reagent, the station share, and what it sells for.
local HOW = { vendor = "|cff80c0ffvendor|r", AH = "|cffffd100AH|r", craft = "|cff40ff40craft|r" }
local function Qty(q) return q == math.floor(q) and ("x%d"):format(q) or ("x%.2f"):format(q) end

-- One line per item of the production chain, indented by depth; an item you can make lists what
-- making it takes below it, greyed out when buying it is the cheaper way.
local function ChainLines(L, id, qty, depth, dim)
  local c, how, buy, craft = Cost(id)
  local alt = craft and how ~= "craft" and ("  |cff999999craft %s|r"):format(Money(craft))
    or how == "craft" and buy and ("  |cff999999AH %s|r"):format(Money(buy)) or ""
  local line = ("%s%s %s  %s  %s  %s%s"):format(("    "):rep(depth), Link(id), Qty(qty), HOW[how] or "|cffff4040no price|r",
    Money(c), Money(c and c * qty), alt)
  L[#L + 1] = dim and ("|cff777777" .. line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r") or line
  local rec = depth < 8 and ns.recipes[id]
  if rec then
    for rid, n in pairs(rec.reagents) do ChainLines(L, rid, qty * n / rec.makes, depth + 1, dim or how ~= "craft") end
  end
end

local function CraftText(r)
  local e, price = Evaluated(r), PriceFor(r)
  local L = {}
  if r.writ then
    L[#L + 1] = ("Asked for by %s |cff999999(%s writ%s)|r\n"):format(Link(r.writ), r.tier or "?",
      r.spec and (", needs " .. r.spec .. " Leatherworking") or "")
  end
  L[#L + 1] = "|cffffd100Production chain|r   qty   how   each   total"
  for id, n in pairs(r.inputs) do ChainLines(L, id, n, 1) end
  if r.station then
    L[#L + 1] = ("  |cff999999station, shared by %d crafts:|r"):format(CraftsPerStation())
    ChainLines(L, r.station, 1 / CraftsPerStation(), 1)
  end
  L[#L + 1] = ("  |cffffffffTotal per craft|r   %s"):format(Money(e.cost))
  L[#L + 1] = "\n|cffffd100Selling|r"
  for id, n in pairs(r.outputs) do
    local pd = PerDay(id)
    L[#L + 1] = ("  %s x%d at %s (%s)   |cff999999%s sold/day|r"):format(Link(id), n, Money(price(id, false)), Basis(),
      pd and ("%.0f"):format(pd) or "?")
    local l = Live(id)
    if l and (l.variants or 0) > 1 then
      L[#L + 1] = ("  |cff999999%d variants on the AH (any one counts for the writ): cheapest %s|r"):format(l.variants, Money(l.min))
    elseif not l then
      L[#L + 1] = "  |cff999999not checked live: Check prices at the AH finds every variant|r"
    end
  end
  L[#L + 1] = ("  After 5%% AH cut   %s"):format(Money(e.value))
  L[#L + 1] = ("  |cffffffffProfit per craft|r   %s"):format(Money(e.profit))
  L[#L + 1] = "\n|cffffd100Your record|r"
  for id in pairs(r.outputs) do RecordLines(id, L, "  ") end
  L[#L + 1] = "\n|cff999999Vendor items at their vendor price; anything you can make costs the cheaper of the AH "
    .. "and crafting it (indented: what crafting it takes, grey when buying is cheaper)"
    .. (r.station and "; the station is shared over the crafts per station set above.|r" or ".|r")
  return table.concat(L, "\n")
end

function ns.StatsText(r)
  if r.inputs and r.outputs and not r.use then return CraftText(r) end
  if not r.use then return "|cff999999No drop statistics: this rule has no item to open.|r" end
  local s, price = Stats(r), PriceFor(r)
  local n = s.opens
  local L = {}
  local e = FlipRulesDB.earn and FlipRulesDB.earn[r.name]
  if e then
    local net = e.revenue - e.spent
    L[#L + 1] = ("|cffffd100Earned|r  %s net   |cff999999sold %d for %s (after AH cut), bought %d for %s|r"):format(
      Money(net), e.sold, Money(e.revenue), e.bought, Money(e.spent))
  else
    L[#L + 1] = "|cffffd100Earned|r  |cff999999nothing yet: counted when you take auction mail for this rule|r"
  end
  local all = 0
  for _, x in pairs(FlipRulesDB.earn or {}) do all = all + x.revenue - x.spent end
  L[#L + 1] = ("|cff999999All rules together: %s net|r\n"):format(Money(all))
  L[#L + 1] = ("Opened |cffffffff%d|r"):format(n)
  if n < MIN_OBSERVED then L[#L + 1] = ("|cff999999Profit uses uniform odds until %d opens.|r"):format(MIN_OBSERVED) end

  -- every item that can or did drop
  local ids, seen = {}, {}
  for _, id in ipairs(r.pool or {}) do ids[#ids + 1] = id; seen[id] = true end
  for id in pairs(s.items) do if not seen[id] then ids[#ids + 1] = id end end
  local poolSize = #(r.pool or {})

  local cats, catPool, value = {}, {}, 0
  for _, id in ipairs(ids) do
    local c = Cat(r, id)
    cats[c] = (cats[c] or 0) + (s.items[id] or 0)
    if seen[id] then catPool[c] = (catPool[c] or 0) + 1 end
    value = value + (s.items[id] or 0) * (price(id, false) or 0)
  end
  if n > 0 then L[#L + 1] = ("Average value you got per open: %s (before 5%% cut)"):format(Money(value / n)) end

  L[#L + 1] = "\n|cffffd100By category|r   count  share  (uniform would be)"
  local cl = {}
  for c in pairs(cats) do cl[#cl + 1] = c end
  table.sort(cl, function(a, b) return cats[a] > cats[b] or (cats[a] == cats[b] and a < b) end)
  for _, c in ipairs(cl) do
    local p = n > 0 and cats[c] / n or 0
    L[#L + 1] = ("  %-16s %4d   %5.1f%% ±%.1f   (%.1f%%)"):format(c, cats[c], 100 * p, 100 * Margin(p, n),
      poolSize > 0 and 100 * (catPool[c] or 0) / poolSize or 0)
  end

  L[#L + 1] = "\n|cffffd100By item|r   count  drop chance  price (" .. Basis() .. ")  sold/day"
  table.sort(ids, function(a, b)
    local ca, cb = s.items[a] or 0, s.items[b] or 0
    if ca ~= cb then return ca > cb end
    return (price(a, false) or 0) > (price(b, false) or 0)
  end)
  for _, id in ipairs(ids) do
    local k = s.items[id] or 0
    local p = n > 0 and k / n or 0
    local pd = PerDay(id)
    L[#L + 1] = ("  %s |cff999999[%s]|r%s  |cffffffff%d|r  %.1f%% ±%.1f  %s  |cff999999%s|r"):format(Name(id), Cat(r, id),
      seen[id] and "" or " |cffff4040not in pool|r", k, 100 * p, 100 * Margin(p, n), Money(price(id, false)),
      pd and ("%.1f"):format(pd) or "?")
  end
  return table.concat(L, "\n")
end

local function RefreshStats()
  resetBtn:SetShown(selected and selected.use and true or false)
  local station = selected and selected.station and true or false
  perLabel:SetShown(station)
  perBox:SetShown(station)
  shopStation:SetShown(station)
  shopStation:SetChecked(FlipRulesDB.shopStation and true or false)
  if station and not perBox:HasFocus() then perBox:SetText(CraftsPerStation()) end
  body:SetText(selected and ns.StatsText(selected) or "")
  child:SetHeight(body:GetStringHeight() + 10)
  postQueue = ahOpen and selected and PostQueue(selected) or {}
  local items = 0
  for _, it in ipairs(postQueue) do if it.price then items = items + it.n end end
  local selling = ahOpen and selected and true or false
  postBtn:SetShown(selling)
  local stacks = mailOpen and #MailSlots() or 0
  mailBtn:SetShown(mailOpen and not selling)
  mailBtn:SetEnabled(stacks > 0 and not mailing)
  mailBtn:SetText(mailing and "Sending..." or stacks > 0 and ("Mail %s (%d)"):format(MailWhat(), stacks)
    or ("No %s to mail"):format(MailWhat()))
  local cheap = (not selling and not mailOpen) and #CheapSlots() or 0
  delBtn:SetShown(cheap > 0)
  delBtn:SetText(("Delete writs <1s (%d)"):format(cheap))
  sellArea:SetShown(selling)
  scroll:SetShown(not selling)
  if selling then RefreshSell() end
  local head = NextPost()
  local fresh = head and Live(head.id, POST_FRESH)
  -- look the next one up before you click; at most once a minute, so an unanswered search doesn't loop
  if head and not fresh and GetTime() - (tried[head.id] or -POST_FRESH) >= POST_FRESH then Check({ head.id }) end
  postBtn:SetEnabled(items > 0 and not posting and (fresh or not searching) and true or false)
  postBtn:SetText(items == 0 and "Nothing to post" or fresh and ("Post next (%d left)"):format(items)
    or searching and "Checking price..." or "Check price")
  if selected and selected.use then
    openBtn:SetText(("Open %s (%d)"):format(Name(selected.use), BagCounts()[selected.use] or 0))
  end
  if InCombatLockdown() then return end -- secure attributes wait for PLAYER_REGEN_ENABLED
  if selected and selected.use then
    openBtn:SetAttribute("type", "item")
    openBtn:SetAttribute("item", "item:" .. selected.use)
    openBtn:Show()
  else
    openBtn:Hide()
  end
end

---------------------------------------------------------------- right: verdict graph

-- A horizontal axis with coloured spans and labelled markers.
local function Axis(y)
  local a = { spans = {}, marks = {} }
  a.track = frame:CreateTexture(nil, "ARTWORK")
  a.track:SetColorTexture(0.15, 0.15, 0.15, 1)
  a.track:SetPoint("TOPLEFT", RX, y)
  a.track:SetSize(VW, 12)
  function a:Scale(lo, hi)
    if hi <= lo then hi = lo + 1 end
    local pad = (hi - lo) * 0.08
    lo, hi = lo - pad, hi + pad
    self.map = function(v) return (math.max(lo, math.min(hi, v)) - lo) / (hi - lo) * VW end
    for _, t in pairs(self.spans) do t:Hide() end
    for _, m in pairs(self.marks) do m.t:Hide(); m.fs:Hide() end
  end
  function a:Span(i, from, to, r, g, b, al)
    if not (from and to) then return end
    local t = self.spans[i] or frame:CreateTexture(nil, "ARTWORK", nil, i)
    self.spans[i] = t
    local x1, x2 = self.map(from), self.map(to)
    if x2 < x1 then x1, x2 = x2, x1 end
    t:SetColorTexture(r, g, b, al)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", self.track, "TOPLEFT", x1, 0)
    t:SetSize(math.max(2, x2 - x1), 12)
    t:Show()
  end
  function a:Mark(i, v, label, r, g, b, above)
    if not v then return end
    local m = self.marks[i] or { t = frame:CreateTexture(nil, "OVERLAY"), fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") }
    self.marks[i] = m
    local x = self.map(v)
    m.t:SetColorTexture(r, g, b, 1)
    m.t:ClearAllPoints()
    m.t:SetPoint("TOPLEFT", self.track, "TOPLEFT", x - 1, 4)
    m.t:SetSize(2, 20)
    m.fs:ClearAllPoints()
    if above then m.fs:SetPoint("BOTTOM", self.track, "TOPLEFT", x, 6) else m.fs:SetPoint("TOP", self.track, "TOPLEFT", x, -10) end
    m.fs:SetText(label)
    m.fs:SetTextColor(r, g, b)
    m.t:Show(); m.fs:Show()
  end
  return a
end

local vVerdict = Text(-32, "GameFontNormalHuge")
local vName = Text(-60, "GameFontHighlight", nil, VW)
local vWhy = Text(-78, "GameFontDisableSmall", nil, VW)

Text(-104, "GameFontNormal"):SetText("Profit per run")
local profitAxis = Axis(-138)
local vProfitNote = Text(-168, nil, nil, VW)
vProfitNote:SetWordWrap(true)

Text(-192, "GameFontNormal"):SetText("What you pay vs break-even |cff999999(cautious = lower of today's and 7-day median)|r")
local costAxis = Axis(-226)
local vCostNote = Text(-252, nil, nil, VW)
vCostNote:SetWordWrap(true)

Text(-282, "GameFontNormal"):SetText("Checks")
local checkRows = {}
for i = 1, 5 do
  local icon = frame:CreateTexture(nil, "OVERLAY")
  icon:SetSize(14, 14)
  icon:SetPoint("TOPLEFT", RX, -300 - (i - 1) * 18)
  checkRows[i] = { icon = icon, fs = Text(-301 - (i - 1) * 18, nil, RX + 20, VW - 20) }
end

local DRIVER_Y = -416
local vDrivers = Text(DRIVER_Y - 18, "GameFontNormal", nil, VW)
local driverRows = {}
for i = 1, 8 do
  local y = DRIVER_Y - (i - 1) * 18
  local bar = frame:CreateTexture(nil, "ARTWORK")
  bar:SetPoint("TOPLEFT", RX + 170, y - 2)
  bar:SetHeight(12)
  driverRows[i] = { name = Text(y, nil, RX, 165), bar = bar, val = Text(y, nil, RX + 175, 240) }
end
vDrivers:ClearAllPoints()
vDrivers:SetPoint("TOPLEFT", RX, DRIVER_Y + 18)
local vMore = Text(DRIVER_Y - 8 * 18, "GameFontDisableSmall", nil, VW)

local function RefreshView()
  if not selected then return end
  local e = Evaluated(selected)
  local r = e.rule
  local v, col, why = ns.Verdict(e)
  vVerdict:SetText(col .. v .. "|r")
  vName:SetText(r.name)
  vWhy:SetText(table.concat(why, "; "))

  -- 1. profit: red below zero, green above; yellow band = the week's low..high; markers safe / basis
  local vals = { 0 }
  for _, x in ipairs({ e.worst or false, e.best or false, e.safe or false, e.profit or false }) do if x then vals[#vals + 1] = x end end
  local lo, hi = math.min(unpack(vals)), math.max(unpack(vals))
  profitAxis:Scale(lo, hi)
  profitAxis:Span(1, lo - (hi - lo), 0, 0.6, 0.1, 0.1, 0.5)
  profitAxis:Span(2, 0, hi + (hi - lo), 0.1, 0.5, 0.1, 0.5)
  profitAxis:Span(3, e.worst, e.best, 1, 0.82, 0, 0.6)
  profitAxis:Mark(1, 0, "0", 1, 1, 1, false)
  profitAxis:Mark(2, e.safe, "safe " .. Money(e.safe), 0.3, 0.9, 1, true)
  profitAxis:Mark(3, e.profit, Basis() .. " " .. Money(e.profit), 1, 1, 1, false)
  vProfitNote:SetText(("|cffffd100Yellow|r = profit over the last 7 days, from the week's lowest to highest price: %s to %s"):format(Money(e.worst), Money(e.best)))

  -- 2. cost: green up to what the outputs are worth at safe prices, red beyond; marker = cost now
  local cap = math.max(e.cost or 0, e.safeValue or 0)
  costAxis:Scale(0, cap > 0 and cap or 1)
  costAxis:Span(1, 0, e.safeValue, 0.1, 0.5, 0.1, 0.6)
  costAxis:Span(2, e.safeValue, cap * 2, 0.6, 0.1, 0.1, 0.6)
  costAxis:Mark(1, e.safeValue, "break-even " .. Money(e.safeValue), 0.3, 0.9, 1, true)
  costAxis:Mark(2, e.cost, "now " .. Money(e.cost), 1, 1, 1, false)
  if e.cost and e.safeValue and e.safeValue > 0 then
    local pct = 100 * (1 - e.cost / e.safeValue)
    local each = e.maxBuy and ("  -  buy " .. Name(next(r.inputs)) .. " below " .. Money(e.maxBuy) .. " each") or ""
    vCostNote:SetText(("You pay %s now; break-even (the most you can pay at cautious prices) is %s: "):format(Money(e.cost), Money(e.safeValue))
      .. (pct >= 0 and "|cff40ff40%.0f%% to spare|r" or "|cffff4040%.0f%% too much|r"):format(math.abs(pct)) .. each)
  else
    vCostNote:SetText("|cff999999no price for an input|r")
  end

  -- 3. checks
  local checks = ns.Checks(e)
  for i, row in ipairs(checkRows) do
    local c = checks[i]
    if c then
      row.icon:SetTexture(c[1] and "Interface\\RaidFrame\\ReadyCheck-Ready" or "Interface\\RaidFrame\\ReadyCheck-NotReady")
      row.fs:SetText(c[2])
      row.icon:Show(); row.fs:Show()
    else
      row.icon:Hide(); row.fs:Hide()
    end
  end

  -- 4. what the value is made of: odds x price per output
  local price, er, w = PriceFor(r), e.evalRule, e.weights
  local items, total, sum = {}, 0, 0
  for _, id in ipairs(er.pool or {}) do total = total + (w and (w[id] or 0) or 1) end
  for _, id in ipairs(er.pool or {}) do
    local odds = (w and (w[id] or 0) or 1) / total
    items[#items + 1] = { id = id, odds = odds, v = odds * (price(id, false) or 0) * (er.poolQty or 1) }
  end
  for id, n in pairs(er.outputs or {}) do items[#items + 1] = { id = id, odds = 1, v = n * (price(id, false) or 0) } end
  table.sort(items, function(a, b) return a.v > b.v end)
  for _, it in ipairs(items) do sum = sum + it.v end
  vDrivers:SetText(("What the value is made of (%s per run at %s, before cut)"):format(Money(sum), Basis()))
  local top = items[1] and items[1].v or 0
  for i, row in ipairs(driverRows) do
    local it = items[i]
    if it then
      row.name:SetText(("%s |cff999999%.1f%%|r"):format((Name(it.id):gsub("^Craftsman's Writ: ", "")), 100 * it.odds))
      local bw = top > 0 and math.max(1, it.v / top * 150) or 1
      row.bar:SetWidth(bw)
      row.bar:SetColorTexture(1, 0.82, 0, 0.8)
      row.val:ClearAllPoints()
      row.val:SetPoint("TOPLEFT", frame, "TOPLEFT", RX + 175 + bw, DRIVER_Y - (i - 1) * 18)
      row.val:SetText(("%s  |cff999999%.0f%%|r"):format(Money(it.v), sum > 0 and 100 * it.v / sum or 0))
      row.name:Show(); row.bar:Show(); row.val:Show()
    else
      row.name:Hide(); row.bar:Hide(); row.val:Hide()
    end
  end
  local rest = 0
  for i = 9, #items do rest = rest + items[i].v end
  vMore:SetText(#items > 8 and ("... %d more outputs: %s (%.0f%%)"):format(#items - 8, Money(rest), sum > 0 and 100 * rest / sum or 0) or "")
end

---------------------------------------------------------------- stock & demand: would buying all sealed flood the market?

local RefreshStock, stockBtn -- the rest stays inside the block: Lua allows 200 locals per file scope
do

local STOCK_OK, STOCK_MAX = 7, 30 -- days of supply: fine up to a week; the bars end at a month

-- rows = { { id, odds, stock, perDay } }: each writ's drop odds, units listed and sold a day.
-- `sealed` writs opened add sealed * odds to each. Days of supply = stock / perDay (now and after);
-- fastShare = share of your opened writs that land where everything clears within STOCK_OK days.
-- Sorts rows worst first. Pure.
function ns.Supply(rows, sealed)
  local function days(stock, pd) return (pd or 0) > 0 and stock / pd or (stock > 0 and math.huge or 0) end
  local t, fast = { stock = 0, perDay = 0, sealed = sealed, rows = rows }, 0
  for _, r in ipairs(rows) do
    r.add = sealed * r.odds
    r.now, r.after = days(r.stock, r.perDay), days(r.stock + r.add, r.perDay)
    t.stock, t.perDay = t.stock + r.stock, t.perDay + (r.perDay or 0)
    if r.after <= STOCK_OK then fast = fast + r.add end
  end
  t.now, t.after = days(t.stock, t.perDay), days(t.stock + sealed, t.perDay)
  t.fastShare = sealed > 0 and fast / sealed or 1
  table.sort(rows, function(a, b) return a.after > b.after end)
  return t
end

-- Units listed: your last live check if under an hour old, else AHledger's last scan.
local function Listed(id)
  local l = Live(id)
  if l then return l.n or 0, "live" end
  local r = AHledgerAPI and AHledgerAPI.GetPrice(id)
  return r and r.quantity or 0, r and r.quantity and "scan" or nil
end

local SROWS, SBW = 30, 200
local stock = CreateFrame("Frame", "FlipRulesStock", frame, "BasicFrameTemplateWithInset")
stock:SetSize(600, 120 + SROWS * 15)
stock:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
stock:EnableMouse(true)
stock:Hide()
stock.TitleText:SetText("Stock & demand")
local sOffset = 0

local function SText(parent, x, y, w, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", x, y)
  if w then fs:SetWidth(w); fs:SetWordWrap(false) end
  fs:SetJustifyH("LEFT")
  return fs
end

local sHead = SText(stock, 14, -32, 570, "GameFontNormal")
local sSum = SText(stock, 14, -52, 570)
sSum:SetWordWrap(true)
local sealLabel = SText(stock, 14, -90, nil)
sealLabel:SetText("Sealed to buy (empty = all listed):")
local sealBox = CreateFrame("EditBox", nil, stock, "InputBoxTemplate")
sealBox:SetSize(50, 18)
sealBox:SetPoint("LEFT", sealLabel, "RIGHT", 8, 0)
sealBox:SetAutoFocus(false)
sealBox:SetNumeric(true)
sealBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
sealBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
local sLegend = SText(stock, 300, -90, 290, "GameFontDisableSmall")
sLegend:SetText(("|cff999999grey|r listed now, |cffffd100yellow|r yours, line = %d days"):format(STOCK_OK))

local SY = -112
local okLine = stock:CreateTexture(nil, "OVERLAY")
okLine:SetColorTexture(0.3, 1, 0.3, 0.7)
okLine:SetPoint("TOPLEFT", 190 + SBW * STOCK_OK / STOCK_MAX, SY + 2)
okLine:SetSize(1, SROWS * 15)
local sRows = {}
for i = 1, SROWS do
  local y = SY - (i - 1) * 15
  local r = { name = SText(stock, 14, y, 172) }
  r.base = stock:CreateTexture(nil, "ARTWORK"); r.base:SetPoint("TOPLEFT", 190, y - 1); r.base:SetHeight(11)
  r.mine = stock:CreateTexture(nil, "ARTWORK"); r.mine:SetPoint("LEFT", r.base, "RIGHT", 0, 0); r.mine:SetHeight(11)
  r.base:SetColorTexture(0.6, 0.6, 0.6, 0.8)
  r.mine:SetColorTexture(1, 0.82, 0, 0.9)
  r.val = SText(stock, 196 + SBW, y, 390 - SBW)
  sRows[i] = r
end

local function Days(d) return d == math.huge and "never" or d >= STOCK_MAX and ("%d+d"):format(STOCK_MAX) or ("%.1fd"):format(d) end

RefreshStock = function()
  if not stock:IsShown() then return end
  local r = selected
  if not (r and r.pool and r.use) then sHead:SetText("Select a sealed writ rule.") sSum:SetText("") for _, x in ipairs(sRows) do x.name:Hide(); x.base:Hide(); x.mine:Hide(); x.val:Hide() end return end
  local e = Evaluated(r)
  local pool, w = e.evalRule.pool, e.weights
  local total = 0
  for _, id in ipairs(pool) do total = total + (w and (w[id] or 0) or 1) end
  local rows, unknown = {}, 0
  for _, id in ipairs(pool) do
    local n, src = Listed(id)
    if not src then unknown = unknown + 1 end
    rows[#rows + 1] = { id = id, odds = (w and (w[id] or 0) or 1) / total, stock = n, perDay = PerDay(id) }
  end
  local listedSealed, sealedSrc = Listed(r.use)
  local sealed = tonumber(sealBox:GetText()) or listedSealed
  local t = ns.Supply(rows, sealed)
  local col = t.fastShare >= 0.7 and "|cff40ff40" or t.fastShare >= 0.4 and "|cffffd100" or "|cffff4040"
  local word = t.fastShare >= 0.7 and "Balanced" or t.fastShare >= 0.4 and "Tight" or "Oversupplied"
  sHead:SetText(("%s%s|r  -  %d sealed listed (%s), buying %d"):format(col, word, listedSealed, sealedSrc or "no data", sealed))
  sSum:SetText(("Opened writs listed: %d, selling ~%.1f a day in total: %s of supply now, %s after you add %d.\n"
    .. "%s%.0f%%|r of the writs you'd open land where everything listed clears within %d days.%s"):format(
    t.stock, t.perDay, Days(t.now), Days(t.after), sealed, col, 100 * t.fastShare, STOCK_OK,
    unknown > 0 and (" |cff999999%d writs have no listing data: run Check prices.|r"):format(unknown) or ""))
  sOffset = math.max(0, math.min(sOffset, #rows - SROWS))
  local px = SBW / STOCK_MAX
  for i, x in ipairs(sRows) do
    local it = rows[i + sOffset]
    if it then
      local base = math.min(it.now, STOCK_MAX)
      local mine = math.min(it.after, STOCK_MAX) - base
      x.name:SetText(("%s |cff999999%.1f%%|r"):format((Name(it.id):gsub("^Craftsman's Writ: ", "")), 100 * it.odds))
      x.base:SetWidth(math.max(1, base * px))
      x.mine:SetWidth(math.max(1, mine * px))
      x.mine:SetShown(mine > 0)
      x.val:SetText(("%s  |cff999999%d listed +%.1f, %.1f/day|r"):format(
        (it.after <= STOCK_OK and "|cff40ff40" or "|cffff6060") .. Days(it.now) .. " > " .. Days(it.after) .. "|r",
        it.stock, it.add, it.perDay or 0))
      x.name:Show(); x.base:Show(); x.val:Show()
    else
      x.name:Hide(); x.base:Hide(); x.mine:Hide(); x.val:Hide()
    end
  end
end

stock:EnableMouseWheel(true)
stock:SetScript("OnMouseWheel", function(_, d) sOffset = math.max(0, sOffset - d * 3); RefreshStock() end)
stock:SetScript("OnShow", RefreshStock)
sealBox:SetScript("OnTextChanged", function(_, user) if user then RefreshStock() end end)

stockBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
stockBtn:SetSize(120, 22)
stockBtn:SetPoint("TOPRIGHT", -14, -32)
stockBtn:SetText("Stock & demand")
stockBtn:SetScript("OnClick", function() stock:SetShown(not stock:IsShown()) end)
stockBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Stock & demand")
  GameTooltip:AddLine("Would buying up the sealed writs flood the market? For each writ: days until what's listed "
    .. "sells at today's pace, now and after your opened writs are added by their drop odds.", 1, 1, 1, true)
  GameTooltip:Show()
end)
stockBtn:SetScript("OnLeave", GameTooltip_Hide)
end

---------------------------------------------------------------- price history: what you sell vs what it takes, per scan

-- An item's cheapest listing at hour `day` (see ns.Slot) from the history, else the last point before
-- it with one. Pure.
function ns.DayPrice(hist, id, day)
  local h, best, bd = hist and hist[id], nil, nil
  for d, x in pairs(h or {}) do
    if d <= day and (not bd or d > bd) and (x.lo or x.min) then best, bd = x.lo or x.min, d end
  end
  return best
end

-- Any field of the last point at or before hour `day` that has it (e.g. "pd", AHledger's sold per day). Pure.
function ns.HistField(hist, id, day, field)
  local best, bd = nil, nil
  for d, x in pairs(hist and hist[id] or {}) do
    if d <= day and (not bd or d > bd) and x[field] then best, bd = x[field], d end
  end
  return best
end

-- A price function for ns.Evaluate on `day`: buying = vendor price, else the cheaper of that day's
-- listing and crafting it from that day's reagent prices; selling = that day's listing. Pure.
function ns.PriceOn(hist, day, vendor, recipes)
  local function buy(x)
    local v = vendor(x)
    if v then return v, "vendor" end
    return ns.DayPrice(hist, x, day), "AH"
  end
  return function(id, isBuy)
    if isBuy then return (ns.BestCost(id, buy, recipes)) end
    return ns.DayPrice(hist, id, day)
  end
end

do
local HW, HH, HROWS = 560, 200, 10
local hist = CreateFrame("Frame", "FlipRulesHistory", frame, "BasicFrameTemplateWithInset")
hist:SetSize(600, 120 + HH + HROWS * 15 + 30)
hist:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, 0)
hist:EnableMouse(true)
hist:Hide()
hist.TitleText:SetText("Price history")

local function HText(x, y, w, font, parent)
  local fs = (parent or hist):CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", x, y)
  if w then fs:SetWidth(w); fs:SetWordWrap(false) end
  fs:SetJustifyH("LEFT")
  return fs
end
local hHead = HText(14, -32, 570, "GameFontNormal")
local hNote = HText(14, -50, 570, "GameFontDisableSmall")
local hLegend = HText(14, -66, 570)
hLegend:SetText("|cff40ff40--|r sells for (after AH cut)   |cffff6060--|r costs to make   |cff999999one dot per scan or live check|r")

local plot = CreateFrame("Frame", nil, hist)
plot:SetPoint("TOPLEFT", 20, -86)
plot:SetSize(HW, HH)
local bg = plot:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetColorTexture(0.08, 0.08, 0.08, 1)
local yTop, yMid = HText(2, -2, 120, nil, plot), HText(2, -HH / 2, 120, nil, plot)
local xFirst, xLast = HText(0, -HH - 4, 90), HText(0, -HH - 4, 90)
xFirst:ClearAllPoints(); xFirst:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -2)
xLast:ClearAllPoints(); xLast:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -2); xLast:SetJustifyH("RIGHT")
local lines, dots, ticks = {}, {}, {}
-- a faint line and a date where a new day starts
local function Tick(i, x, label)
  local t = ticks[i] or { tex = plot:CreateTexture(nil, "BORDER"), fs = plot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall") }
  ticks[i] = t
  t.tex:SetColorTexture(1, 1, 1, 0.12)
  t.tex:ClearAllPoints(); t.tex:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, 0); t.tex:SetSize(1, HH)
  t.fs:ClearAllPoints(); t.fs:SetPoint("TOP", plot, "BOTTOMLEFT", x, -2); t.fs:SetText(label)
  t.tex:Show(); t.fs:Show()
end
local function Line(i, x1, y1, x2, y2, r, g, b)
  local l = lines[i] or plot:CreateLine(nil, "ARTWORK")
  lines[i] = l
  l:SetThickness(2)
  l:SetColorTexture(r, g, b, 1)
  l:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
  l:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
  l:Show()
end
local function Dot(i, x, y, r, g, b)
  local d = dots[i] or plot:CreateTexture(nil, "OVERLAY")
  dots[i] = d
  d:SetColorTexture(r, g, b, 1)
  d:SetSize(5, 5)
  d:ClearAllPoints()
  d:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
  d:Show()
end

local TY = -86 - HH - 22
local th = HText(14, TY, 570, "GameFontNormalSmall")
th:SetText("Item                                                    first point      now        change")
local tRows = {}
for i = 1, HROWS do
  local y = TY - i * 15
  tRows[i] = { name = HText(14, y, 300), a = HText(320, y, 90), b = HText(415, y, 90), c = HText(510, y, 70) }
end


ns.RefreshHist = function()
  if not hist:IsShown() then return end
  for _, l in pairs(lines) do l:Hide() end
  for _, d in pairs(dots) do d:Hide() end
  local r = selected
  if not (r and (r.inputs or r.pool)) then hHead:SetText("Select a rule.") return end
  local e = Evaluated(r)
  local er, H = e.evalRule, FlipRulesDB.hist or {}
  -- one point at every hour any item involved has data (inputs, station, chains, outputs or pool)
  local now, seen, slots = ns.Slot(time()), {}, {}
  for _, id in ipairs(RuleItems(r)) do
    for k in pairs(H[id] or {}) do if not seen[k] then seen[k] = true; slots[#slots + 1] = k end end
  end
  if not seen[now] then slots[#slots + 1] = now end
  table.sort(slots)
  local first, today = slots[1], now
  local pts, hi, nPriced = {}, 0, #(er.pool or {})
  for _ in pairs(er.outputs or {}) do nPriced = nPriced + 1 end
  for _, k in ipairs(slots) do
    local cost, value, _, unpriced = ns.Evaluate(er, ns.PriceOn(H, k, VendorPrice, ns.recipes), e.weights)
    local ok = nPriced > 0 and unpriced / nPriced <= 0.25
    local p = { slot = k, cost = cost, value = ok and value or nil }
    pts[#pts + 1] = p
    hi = math.max(hi, p.cost or 0, p.value or 0)
  end
  hHead:SetText(r.name)
  hNote:SetText(#pts < 2 and "History builds up from your live checks and AHledger's scans and price table: one point each."
    or ("%d points over %.1f days, from your live checks and AHledger's scans; a gap = too little seen then"):format(
      #pts, (today - first) / 24))
  if hi <= 0 then hi = 1 end
  yTop:SetText(Money(hi)); yMid:SetText(Money(hi / 2))
  xFirst:SetText(date("%m-%d %H:%M", first * 3600)); xLast:SetText(date("%m-%d %H:%M", today * 3600))
  local span = math.max(1, today - first)
  local function X(i) return #pts > 1 and (pts[i].slot - first) / span * HW or HW / 2 end
  local function Y(v) return v / hi * (HH - 14) end
  for _, t in pairs(ticks) do t.tex:Hide(); t.fs:Hide() end
  local ti, lastDay = 0, date("%m-%d", first * 3600)
  for k = first + 1, today do -- shortcut: walks every hour of the range, at most 720
    local d = date("%m-%d", k * 3600)
    if d ~= lastDay then
      lastDay = d
      local x = (k - first) / span * HW
      if x > 40 and x < HW - 40 then ti = ti + 1; Tick(ti, x, d) end -- keep clear of the end labels
    end
  end
  local li, di = 0, 0
  for key, c in pairs({ value = { 0.25, 1, 0.25 }, cost = { 1, 0.38, 0.38 } }) do
    for i, p in ipairs(pts) do
      if p[key] then
        di = di + 1; Dot(di, X(i), Y(p[key]), unpack(c))
        local q = pts[i + 1]
        if q and q[key] then li = li + 1; Line(li, X(i), Y(p[key]), X(i + 1), Y(q[key]), unpack(c)) end
      end
    end
  end

  -- each direct input (and the station) and what you sell: first point vs now
  local rows = {}
  local priceFirst, priceNow = ns.PriceOn(H, first, VendorPrice, ns.recipes), ns.PriceOn(H, today, VendorPrice, ns.recipes)
  for id, n in pairs(er.inputs or {}) do rows[#rows + 1] = { id = id, a = priceFirst(id, true), b = priceNow(id, true), tag = "mat" } end
  for id in pairs(er.outputs or {}) do rows[#rows + 1] = { id = id, a = priceFirst(id, false), b = priceNow(id, false), tag = "sell" } end
  local pf, pn = pts[1], pts[#pts]
  local function PerDayFmt(v) return v and ("%.1f/day"):format(v) or "|cff999999?|r" end
  for id in pairs(er.outputs or {}) do
    rows[#rows + 1] = { label = "Sold per day (AHledger)", a = ns.HistField(H, id, first, "pd"), b = ns.HistField(H, id, today, "pd"), fmt = PerDayFmt }
  end
  rows[#rows + 1] = { label = "Total cost to make", a = pf.cost, b = pn.cost }
  rows[#rows + 1] = { label = "Sells for (after cut)", a = pf.value, b = pn.value }
  for i, x in ipairs(tRows) do
    local it = rows[i]
    if it then
      local name = it.label and ("|cffffffff" .. it.label .. "|r")
        or ((it.tag == "sell" and "|cff40ff40sell|r " or "") .. Link(it.id) .. (ns.vendor[it.id] and " |cff80c0ff(vendor)|r" or ""))
      x.name:SetText(name)
      x.a:SetText((it.fmt or Money)(it.a)); x.b:SetText((it.fmt or Money)(it.b))
      local ch = it.a and it.b and it.a > 0 and (it.b / it.a - 1) * 100
      x.c:SetText(ch and ((ch > 0.5 and "|cffff9040+" or ch < -0.5 and "|cff40c0ff" or "|cff999999") .. ("%.0f%%|r"):format(ch)) or "")
      for _, f in pairs(x) do f:Show() end
    else
      for _, f in pairs(x) do f:Hide() end
    end
  end
end

hist:SetScript("OnShow", function() if FlipRulesStock then FlipRulesStock:Hide() end ns.RefreshHist() end)
if FlipRulesStock then FlipRulesStock:HookScript("OnShow", function() hist:Hide() end) end

ns.histBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
ns.histBtn:SetSize(110, 22)
ns.histBtn:SetPoint("TOPRIGHT", -140, -32)
ns.histBtn:SetText("Price history")
ns.histBtn:SetScript("OnClick", function() hist:SetShown(not hist:IsShown()) end)
ns.histBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Price history")
  GameTooltip:AddLine("What the result sells for against what making it costs, by day, from your live checks and AHledger's scans. "
    .. "Below: each reagent's price on the first recorded day and now.", 1, 1, 1, true)
  GameTooltip:Show()
end)
ns.histBtn:SetScript("OnLeave", GameTooltip_Hide)
end

---------------------------------------------------------------- footer: settings

local BASIS_HELP = {
  now = { "Now", "The cheapest listing from your last live check (Check prices, under an hour old), else today's median. Reacts fastest, but one odd listing moves it." },
  ["7d"] = { "7 days", "Median of the last 7 days. Smooths out today's outliers." },
  safe = { "Safe", "The lower of today's and the 7-day median (cautious). The verdict always uses this." },
}

local sellLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
sellLabel:SetPoint("BOTTOMLEFT", LX, 16)
sellLabel:SetText("Value outputs at:")

local basisBtns, prev = {}, sellLabel
for _, key in ipairs({ "now", "7d", "safe" }) do
  local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  b:SetSize(66, 22)
  b:SetPoint("LEFT", prev, "RIGHT", prev == sellLabel and 8 or 2, 0)
  b:SetText(BASIS_HELP[key][1])
  b:SetScript("OnClick", function() FlipRulesDB.basis = key; RefreshAll() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(BASIS_HELP[key][1])
    GameTooltip:AddLine(BASIS_HELP[key][2], 1, 1, 1, true)
    GameTooltip:AddLine("Buying: vendor items at the vendor price, the rest at the cheapest listing, or crafting it when that is cheaper.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", GameTooltip_Hide)
  basisBtns[key] = b
  prev = b
end

local checkBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
checkBtn:SetSize(110, 22)
checkBtn:SetPoint("LEFT", prev, "RIGHT", 10, 0)
checkBtn:SetText("Check prices")
checkBtn:SetScript("OnClick", function()
  local ids = {}
  if FlipRulesDB.filter == "writs" then -- every sealed writ first, selected or not
    for _, r in ipairs(ns.rules) do if r.use and Shown(r) then ids[#ids + 1] = r.use end end
  end
  for _, id in ipairs(selected and RuleItems(selected) or {}) do ids[#ids + 1] = id end
  Check(ids) -- drops duplicates
end)
checkBtn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Check prices live")
  GameTooltip:AddLine("Searches the auction house for every item of the selected rule, one after another. "
    .. "For an hour the lowest listings found replace AHledger's, on all your characters.", 1, 1, 1, true)
  if FlipRulesDB.filter == "writs" then GameTooltip:AddLine("Writs tab: all three sealed writs are checked too.", 0.4, 1, 0.4, true) end
  GameTooltip:AddLine("Searches you do yourself in the auction house are recorded too.", 0.7, 0.7, 0.7, true)
  if #searchQueue > 0 or searching then GameTooltip:AddLine(("%d searches left"):format(#searchQueue + (searching and 1 or 0)), 1, 0.8, 0) end
  GameTooltip:Show()
end)
checkBtn:SetScript("OnLeave", GameTooltip_Hide)

local mailLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mailLabel:SetPoint("BOTTOMLEFT", RX + 250, 18)
mailLabel:SetText("Mail between:")
local mailBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
mailBox:SetSize(160, 20)
mailBox:SetPoint("LEFT", mailLabel, "RIGHT", 10, 0)
mailBox:SetAutoFocus(false)
mailBox:SetScript("OnTextChanged", function(self, user) if user then FlipRulesDB.mailChars = self:GetText() end end)
mailBox:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Your mail characters, comma separated")
  GameTooltip:AddLine("Mail goes to the first one you aren't logged in as: now " .. MailTo() .. ".", 1, 1, 1, true)
  GameTooltip:Show()
end)
mailBox:SetScript("OnLeave", GameTooltip_Hide)
mailBox:SetScript("OnEnterPressed", function(self) self:ClearFocus(); RefreshAll() end)
mailBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local ahCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
ahCheck:SetSize(24, 24)
ahCheck:SetPoint("BOTTOMLEFT", RX - 4, 12)
ahCheck:SetScript("OnClick", function(self) FlipRulesDB.withAH = self:GetChecked() and true or false end)
local ahLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ahLabel:SetPoint("LEFT", ahCheck, "RIGHT", 2, 0)
ahLabel:SetText("Open and close with the auction house")

---------------------------------------------------------------- refresh everything

RefreshAll = function()
  if not frame:IsShown() then return end
  local list = Results()
  if not selected and list[1] then selected = list[1].rule end
  listOffset = math.max(0, math.min(listOffset, #list - N_ROWS))
  for i, b in ipairs(rows) do
    local e = list[i + listOffset]
    b.entry = e
    if e then
      local r = e.rule
      local v, col = ns.Verdict(e)
      local tag = r.recipe and "|cff999999[craft]|r " or r.group and "|cff999999[LW]|r " or ""
      b.cols[1]:SetText(col .. v .. "|r " .. tag .. r.name)
      b.cols[2]:SetText(Money(e.cost))
      b.cols[3]:SetText(Money(e.value))
      b.cols[4]:SetText(Money(e.profit))
      b.sel:SetShown(selected and r.name == selected.name)
      b:Show()
    else
      b:Hide()
    end
  end
  local shown = #list > N_ROWS and ("Showing %d-%d of %d, scroll for more. "):format(listOffset + 1, listOffset + N_ROWS, #list) or ""
  status:SetText(shown .. (#ns.craft == 0 and "Open a profession window to add its recipes." or (#ns.craft .. " recipes scanned.")))
  for b, btn in pairs(basisBtns) do if b == Basis() then btn:LockHighlight() else btn:UnlockHighlight() end end
  for f, btn in pairs(filterBtns) do if f == (FlipRulesDB.filter or "all") then btn:LockHighlight() else btn:UnlockHighlight() end end
  for spec, c in pairs(specChecks) do
    c:SetShown(FlipRulesDB.filter == "Leatherworking")
    c:SetChecked(HasSpec(spec))
  end
  ahCheck:SetChecked(FlipRulesDB.withAH and true or false)
  checkBtn:SetShown(ahOpen)
  if not mailBox:HasFocus() then mailBox:SetText(FlipRulesDB.mailChars or MAIL_CHARS) end
  local left = #searchQueue + (searching and 1 or 0)
  checkBtn:SetText(left > 0 and ("Checking (%d)"):format(left) or "Check prices")
  RefreshStats()
  RefreshView()
  RefreshStock()
  ns.RefreshHist()
  ns.histBtn:SetShown(selected and true or false)
  stockBtn:SetShown(selected and selected.use and selected.pool and true or false)
end
frame:SetScript("OnShow", function() RefreshAll() end)

---------------------------------------------------------------- opening the window

local openedByAH = false

-- the window holds a secure button, so it can't be shown or hidden in combat
local function Toggle(show)
  if InCombatLockdown() then return print("|cff33ff99FlipRules|r can't open or close in combat") end
  if show == nil then show = not frame:IsShown() end
  frame:SetShown(show)
end

-- minimap button: click to open, drag to move it around the minimap
local mm = CreateFrame("Button", "FlipRulesMinimapButton", Minimap)
mm:SetSize(31, 31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\Minimap\UI-Minimap-ZoomButton-Highlight")
local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetSize(20, 20)
mmIcon:SetPoint("CENTER", 0, 1)
local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\Minimap\MiniMap-TrackingBorder")
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")

local function PlaceMinimapButton()
  local a = math.rad(FlipRulesDB.minimapAngle or 200)
  local r = Minimap:GetWidth() / 2 + 5
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end
mm:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    FlipRulesDB.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx))
    PlaceMinimapButton()
  end)
end)
mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mm:SetScript("OnClick", function() openedByAH = false; Toggle() end)
mm:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("FlipRules")
  GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
  GameTooltip:Show()
end)
mm:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
local TRADE_EVENTS = { TRADE_SKILL_SHOW = true, TRADE_SKILL_LIST_UPDATE = true, TRADE_SKILL_UPDATE = true }
for e in pairs(TRADE_EVENTS) do pcall(ev.RegisterEvent, ev, e) end -- the set differs by client
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_AUCTION_CREATED",
  "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
  "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_SEND_INFO_UPDATE" }) do pcall(ev.RegisterEvent, ev, e) end
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    FlipRulesDB = FlipRulesDB or {}
    FlipRulesDB.stats = FlipRulesDB.stats or {}
    FlipRulesDB.live = FlipRulesDB.live or {}
    FlipRulesDB.earn = FlipRulesDB.earn or {}
    FlipRulesDB.hist = FlipRulesDB.hist or {}
    FlipRulesDB.track = FlipRulesDB.track or {}
    ns.PruneHist(FlipRulesDB.hist, time())
    C_Timer.After(10, ns.ImportAHledger) -- after login settles
    FlipRulesDB.seen = nil -- 0.1 format, replaced by stats
    mmIcon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(262890) or "Interface\Icons\INV_Misc_Note_01")
    PlaceMinimapButton()
    TrackOpens() -- baseline bag counts
    -- sale mail names the item but gives no id; names only resolve for items the client has loaded
    if C_Item and C_Item.RequestLoadItemDataByID then
      for _, r in ipairs(ns.rules) do for _, id in ipairs(RuleItems(r)) do C_Item.RequestLoadItemDataByID(id) end end
    end
    return
  end
  if event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    if FlipRulesDB.withAH and not frame:IsShown() then
      openedByAH = true
      return Toggle(true)
    end
  end
  if event == "AUCTION_HOUSE_CLOSED" then
    ahOpen, posting = false, nil
    StaticPopup_Hide("FLIPRULES_POST_CONFIRM")
    if openedByAH and frame:IsShown() then Toggle(false) end
    openedByAH = false
  end
  if event == "AUCTION_HOUSE_POST_WARNING" then -- next frame: the game shows its box on this same event
    C_Timer.After(0, function()
      if posting and posting.asking and StaticPopup_Visible("AUCTION_HOUSE_POST_WARNING") then
        StaticPopup_Hide("AUCTION_HOUSE_POST_WARNING")
      end
    end)
    return
  end
  if event == "AUCTION_HOUSE_AUCTION_CREATED" then pcall(ns.PostCreated); PostDone() end
  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then OnResults(event, arg1) end
  if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then Pump() end
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then OnBrowse() end
  if event == "MAIL_SHOW" then mailOpen = true end
  if event == "MAIL_CLOSED" then mailOpen, mailing = false, nil end
  if event == "MAIL_SEND_SUCCESS" and mailing then
    Say(("mailed %d stacks of %s to %s"):format(mailing.n, mailing.kind, mailing.to))
    mailing = nil
  end
  if event == "MAIL_FAILED" and mailing then -- the items stay attached in the Send Mail tab
    Say(("mail to %s failed (check the name); the %s are still attached in the Send Mail tab."):format(mailing.to, mailing.kind))
    mailing = nil
  end
  -- the game clears the Send Mail form on open and after each send: refill it a moment later
  if event == "MAIL_SHOW" or event == "MAIL_SEND_SUCCESS" then C_Timer.After(0.2, FillSendMail) end
  if event == "MAIL_SEND_INFO_UPDATE" then FillSendMail() end
  if event == "AUCTION_HOUSE_CLOSED" then searchQueue, searching = {}, nil; C_Timer.After(15, ns.ImportAHledger) end -- a scan AHledger just saved
  if event == "BAG_UPDATE_DELAYED" then TrackOpens() end
  if TRADE_EVENTS[event] then ScanTradeSkill() end
  RefreshAll()
end)

-- /flip only opens the window; every setting lives in it
SLASH_FLIPRULES1 = "/flip"
SlashCmdList.FLIPRULES = function(msg)
  if (msg or ""):lower() == "test" then return SelfTest() end
  openedByAH = false
  Toggle()
end
