local ADDON, ns = ...

-- This client moved several globals into C_Item / C_Container.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local NumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local SlotInfo = (C_Container and C_Container.GetContainerItemInfo) or GetContainerItemInfo
-- backpack + 4 bags, plus the reagent bag (5) where the client has one
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

local AH_CUT = 0.05
local MIN_OBSERVED = 30 -- opens before your own drop counts replace uniform odds

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
-- Craftsman's Writs that ask for a leatherworking product: ns.writLinks[product] = { tier, writ, station }.
ns.writLinks = {}
function FlipRules.WritLink(product, tier, writ, station) ns.writLinks[product] = { tier = tier, writ = writ, station = station } end
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
  c.minBuyout, c.liveMin, c.liveOwn, c.itemID = l.min, l.min, l.own, id
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

-- Units sold a day: AHledger's crowd figure, else FlipRules' own estimate from its full scans.
-- Second value: "crowd" or "own".
local function PerDay(id)
  local r = AHRow(id)
  if r and r.soldPerDay then return r.soldPerDay, "crowd" end
  local own = ns.OwnPace(id)
  if own then return own, "own" end
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
  local mv = ns.Movers({ { id = 1, perDay = 100, listed = 25, price = 10 }, { id = 2, perDay = 5, listed = 0, price = 1000 },
    { id = 3, listed = 4, price = 50 } }, "gold")
  assert(mv[1].id == 2 and mv[1].gold == 5000 and mv[2].cover == 6 and mv[2].short, "movers: gold order, cover, short")
  assert(not mv[1].short and mv[3].cover == math.huge, "movers: slow sellers aren't short, unsold has no cover")
  assert(ns.Movers(mv, "cover")[1].id == 2 and ns.Movers(mv, "sold")[1].id == 1, "movers: other sorts")
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
  -- craft flips from learned recipes
  local fl, it = ns.BuildCrafts({ { name = "Ball", inputs = { [1] = 2 }, outputs = { [10] = 1 } },
    { name = "Bound Helm", inputs = { [1] = 5 }, outputs = { [11] = 1 } },
    { name = "Leather", inputs = { [2] = 4 }, outputs = { [1] = 1 } }, { name = "No reagents", inputs = {}, outputs = { [12] = 1 } } },
    { [10] = { tier = "Journeyman", writ = 99, station = 98 } }, function(id) return id == 11 end)
  assert(#fl == 2 and fl[1].name == "Leather" and fl[2].name == "[Journeyman] Ball" and fl[2].writ == 99
    and fl[2].station == 98 and fl[1].writ == nil and fl[2].group == "Leatherworking" and fl[2].craft, "craft flips")
  assert(it[11] and it[1].makes == 1 and it[1].reagents[2] == 4 and not it[12], "intermediates include bound products")
  -- never undercut yourself
  assert(ns.PostPrice(500, nil, 450) == 450 and ns.PostPrice(500, nil, 500) == 500, "your auction is cheapest: match it")
  assert(ns.PostPrice(500, nil, 600) == 499 and ns.PostPrice(nil, 300, 450) == 450, "others cheaper: undercut them")
  assert(select(4, ns.Lowest({ { price = 300, qty = 2, own = 1 }, { price = 200, qty = 1, own = 0 } })) == 300, "your cheapest")
  -- full scan
  local acc = {}
  ns.ScanAdd(acc, 7, 20, 2000, "Other", false, false)
  ns.ScanAdd(acc, 7, 20, 2000, "Other", false, true)
  ns.ScanAdd(acc, 7, 5, 400, "Me-Realm", true, false)
  ns.ScanAdd(acc, 7, 1, 0, "Other", false, false) -- bid only: counted, no price
  assert(acc[7].n == 46 and acc[7].own == 5 and acc[7].min == 100 and acc[7].ownMin == 80, "scan totals")
  assert(acc[7].keys["Other:100:20"].c == 2 and acc[7].keys["Other:100:20"].short == 1, "scan keys")
  assert(ns.IsMine("Me-Realm", { Me = true }) and ns.IsMine("Me", { Me = true }) and not ns.IsMine("Meh", { Me = true })
    and not ns.IsMine(nil, { Me = true }), "whose auction")
  local prev = { ["A:100:20"] = { c = 3, short = 1 }, ["B:90:5"] = { c = 1, short = 0 } }
  local cur = { ["A:100:20"] = { c = 1, short = 0 } }
  assert(ns.Vanished(prev, cur, 12) == (20 + 5) * 2, "sold a day: gone minus expiring")
  assert(ns.Vanished(prev, nil, 24) == 45 and ns.Vanished(prev, cur, 0.1) == nil and ns.Vanished(nil, cur, 5) == nil, "vanished edges")
  local hp = {}
  ns.Hist(hp, 7, K * 3600, 100, 5, { op = 10 }); ns.Hist(hp, 7, (K + 1) * 3600, 100, 5, { op = 30 })
  assert(ns.OwnPace(7, (K + 2) * 3600, hp) == 20 and ns.OwnPace(7, (K + 400) * 3600, hp) == nil, "own pace: last week only")
  local gs, rest = ns.GroupByClass({ 1, 2, 3, 4 }, function(id) if id == 4 then return nil end return 7, id == 3 and 2 or 1 end)
  assert(#gs == 2 and #gs[1].ids == 2 and gs[1].subClassID == 1 and #rest == 1 and rest[1] == 4, "group by class")
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
  for bag = 0, LAST_BAG do
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
ns.Money, ns.Name, ns.Link = Money, Name, Link

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

local ScanTradeSkill -- the helpers stay inside the block: Lua allows 200 locals in the main chunk
do
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

local LW_SKILL = 165 -- Leatherworking's profession id

local function IsLeatherworking()
  if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    if ok and info then
      return info.professionID == LW_SKILL or info.parentProfessionID == LW_SKILL or info.professionName == "Leatherworking"
    end
  end
  return GetTradeSkillLine and GetTradeSkillLine() == "Leatherworking"
end

local function Linked() -- someone else's recipe list, opened from a chat link
  if C_TradeSkillUI and C_TradeSkillUI.IsTradeSkillLinked then
    local ok, l = pcall(C_TradeSkillUI.IsTradeSkillLinked)
    if ok and l then return true end
  end
  return IsTradeSkillLinked and IsTradeSkillLinked() and true or false
end

local function ReadTradeSkill()
  local craft = {}
  if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeSchematic then ScanModern(craft) end
  if #craft > 0 or not GetNumTradeSkills then return craft end
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
  return craft
end

-- An open profession window: Leatherworking is saved (account-wide) as your crafter's learned
-- recipes and becomes craft flips; any other profession is listed under All until you log out.
ScanTradeSkill = function()
  local craft = ReadTradeSkill()
  if not IsLeatherworking() then ns.craft = craft return end
  if Linked() or #craft == 0 then return end
  local old = FlipRulesDB.lw and #FlipRulesDB.lw.recipes or 0
  FlipRulesDB.lw = { char = UnitName("player"), t = time(), recipes = craft }
  ns.RebuildCrafts()
  if #craft ~= old then ns.Say(("%d learned leatherworking recipes saved."):format(#craft)) end
end
end

---------------------------------------------------------------- evaluation

local CRAFTS_A_DAY = 10 -- profit a day counts at most this many sold a day

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
  local paceOwn = false
  for id in pairs(rule.outputs or {}) do
    local pd, src = PerDay(id)
    paceOwn = paceOwn or src == "own"
    pd = pd or 0
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
    profitDay = profit and profit * math.min(perDay, CRAFTS_A_DAY), -- capped: you can only craft and post so many
    maxBuy = maxBuy, perDay = perDay, paceOwn = paceOwn, unpriced = unpriced, unpricedShare = nPriced > 0 and unpriced / nPriced or 0,
    opens = s and s.opens or 0, observed = observed, safeValue = safeValue, evalRule = rule, weights = weights }
end

ns.Evaluated = Evaluated

-- The checks behind the verdict, { pass, text } each; the first one is the hard requirement.
function ns.Checks(e)
  local c = {
    { (e.safe or 0) > 0, ("Makes money at cautious prices: %s a run"):format(Money(e.safe)) },
    { not (e.worst and e.worst < 0), ("Still makes money at the week's lowest price: %s a run"):format(Money(e.worst)) },
    { e.perDay >= 1, ("Sells often enough: ~%.1f a day on the AH%s (want 1+)"):format(e.perDay,
      e.paceOwn and ", from your scans" or "") },
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
  GameTooltip:AddLine("Click: show the details", 0.4, 1, 0.4)
  if not r.use and Auctionator then GameTooltip:AddLine("At the auction house, the click also searches the reagents in Auctionator", 0.4, 1, 0.4) end
  if AHledgerAPI then GameTooltip:AddLine(AHledgerAPI.CREDIT, 0.5, 0.5, 0.5) end
  GameTooltip:Show()
end
ns.ShowBreakdown = ShowBreakdown

local RefreshAll
function ns.RefreshAll() RefreshAll() end

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

-- Reset a writ flip's drop statistics; the confirm box gets the flip's name.
StaticPopupDialogs.FLIPRULES_RESET = {
  text = "Clear all drop statistics for\n%s?",
  button1 = YES, button2 = NO,
  OnAccept = function(_, name) FlipRulesDB.stats[name] = nil; RefreshAll() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

---------------------------------------------------------------- selling: one auction per click

-- The server takes one post per click and needs a moment between posts, so "bulk" is a button you
-- click repeatedly: each click posts the most valuable result of the selected rule still in your bags.
local POST_DURATION = 3 -- writs: the longest the AH offers (24 h or 48 h depending on the client)
local POST_DURATION_LW = 1 -- leatherworking: the shortest (2 h); heavy undercutting, so a short post risks less deposit
local DURATION_NAME = { "short", "medium", "long" }
local POST_WAIT = 5     -- seconds to wait for the AH to confirm a post
local POST_FRESH = 60   -- re-check an item's price before posting when the last check is older
local SEARCH_WAIT = 5   -- seconds before giving up on a search answer
local ahOpen, posting = false, nil
function ns.AHOpen() return ahOpen end

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
    FlipRulesDB.live[s.id] = { min = s.best, n = s.n or 0, top = s.mins, variants = s.variants, own = s.own, t = time(), v = LIVE_V }
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
  if searching or ns.ScanBusy() or not ahOpen or not (AH and AH.SendSearchQuery and AH.MakeItemKey) then return end
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
ns.Check, ns.Pump, ns.LIVE_V = Check, function() Pump() end, LIVE_V
function ns.SearchesLeft() return #searchQueue + (searching and 1 or 0) end
function ns.Searching() return searching ~= nil end

-- Cheapest unit price not yours, how many are listed (not yours), the 5 cheapest, and your own
-- cheapest. Pure.
function ns.Lowest(rows)
  local n, top, own = 0, {}, nil
  for _, r in ipairs(rows) do
    if r.price and r.price > 0 and r.own < r.qty then
      n = n + r.qty - r.own
      top[#top + 1] = math.floor(r.price)
    end
    if r.price and r.price > 0 and r.own > 0 and (not own or r.price < own) then own = math.floor(r.price) end
  end
  table.sort(top)
  for i = #top, 6, -1 do top[i] = nil end -- the 5 cheapest auctions, for the sanity check
  return top[1], n, top, own
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
  local min, n, top, own = ns.Lowest(rows)
  local s = searching
  if s and s.id == id and s.key then -- the variant holding your auction: its cheapest not yours
    if min and (not s.best or min < s.best) then s.best = min end
    s.own = own
    return FinishSearch(s)
  end
  if s and s.id == id and not s.browse then -- plain item search (name wasn't loaded)
    s.best, s.n, s.mins, s.variants, s.own = min, n, top, nil, own
    return FinishSearch(s)
  end
  -- a search you did yourself: one variant only, so it can't replace an all-variant check
  local l = FlipRulesDB.live[id]
  if l and l.variants and l.variants > 1 and time() - l.t <= LIVE_FRESH then return end
  FlipRulesDB.live[id] = { min = min, n = n, top = top, own = own, t = time(), v = LIVE_V }
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
ns.RuleItems = RuleItems

-- Cheapest listing not yours minus 1 copper (no listing: `fallback`). When your own auction is
-- already the cheapest (`own`), match it instead of undercutting yourself. Pure.
function ns.PostPrice(min, fallback, own)
  if own and own >= 1 and (not min or own <= min) then return math.floor(own) end
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
      q[#q + 1] = { id = id, n = n, cur = row and row.minBuyout, price = ns.PostPrice(row and row.minBuyout, price(id, false), row and row.liveOwn),
        lw = r.group == "Leatherworking" }
    end
  end
  -- most valuable first; unpriced ones last (shown, never posted)
  table.sort(q, function(a, b) return (a.price or -1) * a.n > (b.price or -1) * b.n end)
  return q
end

local function NextPost(q)
  for _, it in ipairs(q) do if it.price then return it end end
end

local function FindSlot(id)
  for bag = 0, LAST_BAG do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and info.itemID == id and not info.isLocked then return bag, slot, info.stackCount or 1 end
    end
  end
end

local function Say(s) print("|cff33ff99FlipRules|r " .. s) end
ns.Say = Say

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
  Say(("posted %d x %s at %s each (%s duration)"):format(posting.qty, Link(posting.id), Money(posting.price),
    DURATION_NAME[posting.duration]))
  posting = nil
end

local function CallPost(p, confirm)
  local AH = C_AuctionHouse
  if p.commodity then
    return pcall(confirm and AH.ConfirmPostCommodity or AH.PostCommodity, p.loc, p.duration, p.qty, p.price)
  end
  return pcall(confirm and AH.ConfirmPostItem or AH.PostItem, p.loc, p.duration, p.qty, nil, p.price)
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
  if not bag then return Say(("no unlocked %s in your bags (a locked one is still being posted or moved)."):format(Link(item.id))) end
  local p = { id = item.id, price = item.price, loc = ItemLocation:CreateFromBagAndSlot(bag, slot),
    duration = item.lw and POST_DURATION_LW or POST_DURATION }
  if AH.GetItemCommodityStatus and AH.PostCommodity then
    local ok, s = pcall(AH.GetItemCommodityStatus, p.loc)
    p.commodity = ok and s == (Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity or 2)
  end
  p.qty = p.commodity and item.n or stack -- commodities go up in one post; other items one stack per post
  local ok, needs = CallPost(p)
  if not ok then return Say("couldn't post: " .. tostring(needs)) end
  Say(("posting %d x %s at %s (%s, %s)..."):format(p.qty, Link(p.id), Money(p.price), p.commodity and "commodity" or "item",
    DURATION_NAME[p.duration]))
  posting = p
  if needs then
    p.asking = true
    StaticPopup_Show("FLIPRULES_POST_CONFIRM", ("%d x %s at %s each"):format(p.qty, Name(p.id), Money(p.price)), nil, p)
    Say(("the auction house asks to confirm %d x %s at %s: click Yes, or Post again."):format(p.qty, Link(p.id), Money(p.price)))
    RefreshAll() -- the button turns into "Confirm post"
  else
    WaitPost(p)
  end
end

-- The game's own confirm box doesn't work for addon posts, so ours replaces it (see POST_WARNING).
-- Confirms the post the AH asked about: from the box's Yes, or from clicking Post again.
local function ConfirmPost(p)
  if posting ~= p or not p.asking then return end
  p.asking = nil
  StaticPopup_Hide("FLIPRULES_POST_CONFIRM")
  local ok, err = CallPost(p, true)
  if ok then return WaitPost(p) end
  posting = nil
  Say("couldn't post: " .. tostring(err))
end
StaticPopupDialogs.FLIPRULES_POST_CONFIRM = {
  text = "The auction house asks you to confirm this post:\n%s",
  button1 = YES, button2 = NO,
  OnAccept = function(_, p) ConfirmPost(p) end,
  OnCancel = function(_, p) if posting == p then posting = nil end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

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
ns.MAIL_CHARS = MAIL_CHARS
local function MailTo() return ns.MailTarget(FlipRulesDB.mailChars or MAIL_CHARS, UnitName("player")) end

-- What a mail sends: kind "writs" = the opened writs; "LW items" = every leatherworking item,
-- reagents and crafted products.
local function MailIDs(kind)
  local ids = {}
  if kind == "writs" then
    for _, r in ipairs(ns.rules) do for _, id in ipairs(r.pool or {}) do ids[id] = true end end
    return ids
  end
  -- everything leatherworking: each rule's reagents, products and station, every intermediate recipe
  -- (Heavy Leather, Cured Heavy Hide, ...) with its own reagents, and the stations
  for _, r in ipairs(ns.rules) do
    if r.group == "Leatherworking" then for _, id in ipairs(RuleItems(r)) do ids[id] = true end end
  end
  for id, rec in pairs(ns.recipes) do
    ids[id] = true
    for rid in pairs(rec.reagents or {}) do ids[rid] = true end
  end
  for id in pairs(ns.stations) do ids[id] = true end
  return ids
end

local function MailSlots(kind)
  local ids, slots = MailIDs(kind), {}
  for bag = 0, LAST_BAG do
    for slot = 1, (NumSlots(bag) or 0) do
      local info = SlotInfo(bag, slot)
      if type(info) == "table" and ids[info.itemID] and not info.isLocked and not info.isBound then
        slots[#slots + 1] = { bag = bag, slot = slot }
      end
    end
  end
  return slots
end

local function SendBatch(kind)
  local to = MailTo()
  if not mailOpen then return Say("open a mailbox first.") end
  if mailing then return Say("still sending the last mail, click again in a moment.") end
  if to == "" then return Say("type your characters in the 'Mail between' box first.") end
  for i = 1, MAIL_MAX do
    if GetSendMailItem(i) then return Say("the Send Mail tab already has attachments: clear them first.") end
  end
  if MailFrameTab_OnClick then MailFrameTab_OnClick(nil, 2) end -- attaching needs the Send Mail tab
  local slots = MailSlots(kind)
  local n = math.min(MAIL_MAX, #slots)
  if n == 0 then return Say(("no %s in your bags."):format(kind)) end
  for i = 1, n do
    ClearCursor()
    Pickup(slots[i].bag, slots[i].slot)
    ClickSendMailItemButton(i)
  end
  ClearCursor()
  mailing = { to = to, n = n, kind = kind }
  SendMail(to, ("%s (%d)"):format(kind == "writs" and "Writs" or "LW items", n), "")
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

---------------------------------------------------------------- deleting writs worth less than 1 silver

local CheapSlots
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
  for bag = 0, LAST_BAG do
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

function ns.Ago(t)
  local m = math.floor((time() - t) / 60)
  return m < 60 and ("%dm ago"):format(m) or ("%dh ago"):format(math.floor(m / 60))
end

-- One click deletes one stack: the first of CheapSlots().
function ns.DeleteCheap()
  local it = CheapSlots()[1]
  if not it then return end
  ClearCursor()
  Pickup(it.bag, it.slot)
  if CursorHasItem() then
    DeleteCursorItem()
    Say(("deleted %s x%d (cheapest listing %s, checked %s)"):format(it.link or it.id, it.n, Money(it.price), ns.Ago(it.t)))
  end
  ClearCursor()
end

end

---------------------------------------------------------------- what the window's action bar uses

ns.BagCounts, ns.Live, ns.ShopReagents, ns.CHEAP = BagCounts, Live, ShopReagents, 100
function ns.MailOpen() return mailOpen end
function ns.Mailing() return mailing ~= nil end
ns.MailTo, ns.MailSlots, ns.SendBatch, ns.CheapSlots, ns.MAIL_MAX = MailTo, MailSlots, SendBatch, CheapSlots, MAIL_MAX

-- What posting `r` looks like now: its results in your bags, best first (queue), the next one to
-- post (head) and whether its price is fresh. Looks the next one up when it isn't, at most once a
-- minute so an unanswered search doesn't loop.
function ns.PostState(r)
  local q = ahOpen and r and PostQueue(r) or {}
  local items = 0
  for _, it in ipairs(q) do if it.price then items = items + it.n end end
  local head = NextPost(q)
  local fresh = head and Live(head.id, POST_FRESH) and true or false
  if head and not fresh and GetTime() - (tried[head.id] or -POST_FRESH) >= POST_FRESH then Check({ head.id }) end
  return { queue = q, items = items, head = head, fresh = fresh, busy = posting ~= nil and not posting.asking,
    asking = posting and posting.asking and true or false }
end
-- A post waiting for the AH's confirmation is confirmed by the next click instead of blocking it.
function ns.PostNext(r)
  if posting and posting.asking then return ConfirmPost(posting) end
  local head = NextPost(ahOpen and r and PostQueue(r) or {})
  if head then Post(head) end
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
  if extra then d.md, d.pd, d.op = extra.md or d.md, extra.pd or d.pd, extra.op or d.op end
end
-- FlipRules' own units-sold-a-day estimate: the average over the last week's full scans; nil without one.
function ns.OwnPace(id, now, hist)
  local h = (hist or FlipRulesDB and FlipRulesDB.hist or {})[id]
  if not h then return nil end
  local from, sum, n = ns.Slot(now or time()) - WEEK, 0, 0
  for k, d in pairs(h) do if k >= from and d.op then sum, n = sum + d.op, n + 1 end end
  return n > 0 and sum / n or nil, n
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
  -- "won" mail is not counted: on this client its invoice gives the item count where the price
  -- should be (every purchase saved as 1 copper each, 2026-11-25); purchases are taken at the AH below
  if not rule or kind ~= "sold" then return RefreshAll() end
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

-- What you pay for a writ flip's input (the sealed writ), taken when you buy it at the AH: the game
-- states the total there. Commodities: StartCommoditiesPurchase, then the price, then success.
do
local buying -- { id, qty, total } between starting and finishing a commodity purchase
local function Bought(id, qty, total)
  local rule
  for _, r in ipairs(ns.rules) do if r.use and r.inputs and r.inputs[id] then rule = r break end end
  if not (rule and total and total > 0 and FlipRulesDB) then return end
  local e = ns.Earn(FlipRulesDB.earn, "won", rule.name, qty, total)
  Say(("bought %d x %s for %s: %s net so far"):format(qty, Link(id), Money(total), Money(e.revenue - e.spent)))
  RefreshAll()
end
local AH = C_AuctionHouse
if AH and AH.StartCommoditiesPurchase then
  hooksecurefunc(AH, "StartCommoditiesPurchase", function(id, qty) buying = { id = id, qty = qty } end)
end
if AH and AH.PlaceBid and AH.GetAuctionInfoByID then -- a non-commodity bought out
  -- shortcut: counted when the buyout is sent, not when it succeeds; a failed buyout counts too (rare)
  hooksecurefunc(AH, "PlaceBid", function(auctionID, amount)
    local ok, info = pcall(AH.GetAuctionInfoByID, auctionID)
    if ok and info and info.itemKey and info.buyoutAmount and amount >= info.buyoutAmount then
      Bought(info.itemKey.itemID, info.quantity or 1, amount)
    end
  end)
end
local f = CreateFrame("Frame")
for _, e in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED" }) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, event, _, total)
  if not buying then return end
  if event == "COMMODITY_PRICE_UPDATED" then buying.total = total -- unitPrice, totalPrice
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    local b = buying
    buying = nil
    Bought(b.id, b.qty, b.total)
  else
    buying = nil
  end
end)
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
local function Wanted()
  local w = {}
  for _, r in ipairs(ns.rules) do for _, id in ipairs(RuleItems(r)) do w[id] = true end end
  return w
end
-- AHledger's downloaded crowd table only (docs/adr/0001): its own AH scans are not used.
ns.ImportAHledger = function()
  if not (FlipRulesDB and AHledgerAPI and AHledgerAPI.GetPrice) then return end
  for id in pairs(Wanted()) do -- the lowest listing, count, median and pace at the table's update
    local p = AHledgerAPI.GetPrice(id)
    if p and p.updated and not p.snapshot then
      ns.Hist(FlipRulesDB.hist, id, p.updated, p.minBuyout, p.quantity, { md = p.median, pd = p.soldPerDay })
    end
  end
end
end
-- 95% margin of error for a share p seen in n tries (normal approximation).
local function Margin(p, n) return n > 0 and 1.96 * math.sqrt(p * (1 - p) / n) or 0 end
-- The details pane's content as data (UI/Details.lua lays it out): what you buy down the chains,
-- what you sell, your record, and for a writ flip what opening gave you.
do
local function ChainRows(rows, id, qty, depth, dim)
  local c, how, buy, craft = Cost(id)
  rows[#rows + 1] = { id = id, depth = depth, qty = qty, how = how, each = c, total = c and c * qty, dim = dim,
    alt = craft and how ~= "craft" and ("craft " .. Money(craft)) or how == "craft" and buy and ("AH " .. Money(buy)) or nil }
  local rec = depth < 8 and ns.recipes[id]
  if rec then
    for rid, n in pairs(rec.reagents) do ChainRows(rows, rid, qty * n / rec.makes, depth + 1, dim or how ~= "craft") end
  end
end

-- your posts of `id`, and its cheapest listing by day and AHledger's updates
function ns.RecordData(id)
  local t = FlipRulesDB.track and FlipRulesDB.track[id]
  local d = { id = id, sum = ns.TrackSummary(t), track = t, days = {}, crowd = {} }
  local h = FlipRulesDB.hist and FlipRulesDB.hist[id]
  if not h then return d end
  local slots, byDay = {}, {}
  for k in pairs(h) do slots[#slots + 1] = k end
  table.sort(slots)
  for _, k in ipairs(slots) do
    local x, dk = h[k], date("%m-%d", k * 3600)
    local day = byDay[dk]
    if not day then day = { day = dk }; byDay[dk] = day; d.days[#d.days + 1] = day end
    local lo = x.lo or x.min
    if lo and (not day.lo or lo < day.lo) then day.lo = lo end
    day.n = x.n
    if x.pd or x.md then d.crowd[#d.crowd + 1] = { day = date("%m-%d %H:%M", k * 3600), median = x.md, perDay = x.pd } end
  end
  while #d.days > 7 do table.remove(d.days, 1) end
  while #d.crowd > 5 do table.remove(d.crowd, 1) end
  return d
end

function ns.DetailData(r)
  local e, price = Evaluated(r), PriceFor(r)
  local d = { e = e, basis = Basis(), sell = {}, records = {} }
  if r.writ then d.writ = { link = Link(r.writ), tier = r.tier } end
  if r.inputs and not r.use then
    d.chain = {}
    for id, n in pairs(r.inputs) do ChainRows(d.chain, id, n, 1) end
    if r.station then
      d.station = { crafts = CraftsPerStation(), rows = {} }
      ChainRows(d.station.rows, r.station, 1 / CraftsPerStation(), 1)
    end
  else
    d.buy = {}
    for id, n in pairs(r.inputs or {}) do d.buy[#d.buy + 1] = { id = id, qty = n, each = price(id, true) } end
  end
  for id, n in pairs(r.outputs or {}) do
    local l = Live(id)
    d.sell[#d.sell + 1] = { id = id, qty = n, price = price(id, false), perDay = (PerDay(id)), variants = l and l.variants,
      checked = l ~= nil }
    d.records[#d.records + 1] = ns.RecordData(id)
  end
  if r.use then
    local s = Stats(r)
    local n = s.opens
    local en = FlipRulesDB.earn and FlipRulesDB.earn[r.name]
    d.drops = { opens = n, need = MIN_OBSERVED, earn = en, cats = {}, items = {} }
    local ids, inPool = {}, {}
    for _, id in ipairs(r.pool or {}) do ids[#ids + 1] = id; inPool[id] = true end
    for id in pairs(s.items) do if not inPool[id] then ids[#ids + 1] = id end end
    local cats, catPool, value = {}, {}, 0
    for _, id in ipairs(ids) do
      local c = Cat(r, id)
      cats[c] = (cats[c] or 0) + (s.items[id] or 0)
      if inPool[id] then catPool[c] = (catPool[c] or 0) + 1 end
      value = value + (s.items[id] or 0) * (price(id, false) or 0)
      local k = s.items[id] or 0
      local p = n > 0 and k / n or 0
      d.drops.items[#d.drops.items + 1] = { id = id, cat = c, inPool = inPool[id], count = k, chance = p,
        margin = Margin(p, n), price = price(id, false), perDay = (PerDay(id)) }
    end
    d.drops.avg = n > 0 and value / n or nil
    for c, k in pairs(cats) do
      local p = n > 0 and k / n or 0
      d.drops.cats[#d.drops.cats + 1] = { cat = c, count = k, share = p, margin = Margin(p, n),
        uniform = #(r.pool or {}) > 0 and (catPool[c] or 0) / #r.pool or 0 }
    end
    table.sort(d.drops.cats, function(a, b) return a.count > b.count or (a.count == b.count and a.cat < b.cat) end)
    table.sort(d.drops.items, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return (a.price or 0) > (b.price or 0)
    end)
  end
  return d
end
end

---------------------------------------------------------------- stock & demand: would buying all sealed flood the market?

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

-- Movers: every item FlipRules knows, ranked by how much moves through the AH. cover = hours until
-- what's listed now sells out at the current pace; under SHORT_COVER hours on a busy item it is
-- likely under-supplied. Pure: rows = { { id, perDay, listed, price } }.
local SHORT_COVER, BUSY = 12, 10 -- hours of cover; units sold a day
function ns.Movers(rows, key)
  for _, r in ipairs(rows) do
    r.gold = (r.perDay or 0) * (r.price or 0)
    r.cover = (r.perDay or 0) > 0 and r.listed / r.perDay * 24 or math.huge
    r.short = r.cover < SHORT_COVER and (r.perDay or 0) >= BUSY
  end
  local by = key == "sold" and function(a, b) return (a.perDay or 0) > (b.perDay or 0) end
    or key == "cover" and function(a, b) if a.cover ~= b.cover then return a.cover < b.cover end return a.gold > b.gold end
    or function(a, b) return a.gold > b.gold end
  table.sort(rows, by)
  return rows
end

local function MoverItems(key)
  local ids, seen = {}, {}
  local function add(id) if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
  for _, r in ipairs(ns.rules) do add(r.use); for _, id in ipairs(RuleItems(r)) do add(id) end end
  for id, rec in pairs(ns.recipes) do add(id); for rid in pairs(rec.reagents or {}) do add(rid) end end
  local rows = {}
  for _, id in ipairs(ids) do
    local pd = PerDay(id)
    if pd and not ns.vendor[id] then
      local a = AHRow(id)
      rows[#rows + 1] = { id = id, perDay = pd, listed = (Listed(id)), price = a and (a.median or a.minBuyout) or 0 }
    end
  end
  return ns.Movers(rows, key or "gold")
end
ns.MoverRows = MoverItems
-- Stock & demand of a writ flip's pool if you open `sealed` more (nil: every sealed one listed): ns.Supply's
-- table plus listedSealed, sealedSrc ("live" / "scan" / nil) and unknown (writs with no listing data).
function ns.SupplyFor(r, sealed)
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
  local t = ns.Supply(rows, sealed or listedSealed)
  t.listedSealed, t.sealedSrc, t.unknown, t.okDays = listedSealed, sealedSrc, unknown, STOCK_OK
  return t
end
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

-- A flip's history as data: one point per hour any of its items was seen (cost to make, value after
-- the cut), first..today slots, and each input and output's price then and now.
function ns.HistData(r)
  local e = Evaluated(r)
  local er, H = e.evalRule, FlipRulesDB.hist or {}
  local now, seen, slots = ns.Slot(time()), {}, {}
  for _, id in ipairs(RuleItems(r)) do
    for k in pairs(H[id] or {}) do if not seen[k] then seen[k] = true; slots[#slots + 1] = k end end
  end
  if not seen[now] then slots[#slots + 1] = now end
  table.sort(slots)
  local pts, hi, nPriced = {}, 0, #(er.pool or {})
  for _ in pairs(er.outputs or {}) do nPriced = nPriced + 1 end
  for _, k in ipairs(slots) do
    local cost, value, _, unpriced = ns.Evaluate(er, ns.PriceOn(H, k, VendorPrice, ns.recipes), e.weights)
    local ok = nPriced > 0 and unpriced / nPriced <= 0.25
    pts[#pts + 1] = { slot = k, cost = cost, value = ok and value or nil }
    hi = math.max(hi, cost or 0, ok and value or 0)
  end
  local first = slots[1]
  local rows = {}
  local pf, pn = ns.PriceOn(H, first, VendorPrice, ns.recipes), ns.PriceOn(H, now, VendorPrice, ns.recipes)
  for id in pairs(er.inputs or {}) do rows[#rows + 1] = { id = id, a = pf(id, true), b = pn(id, true), vendor = ns.vendor[id] ~= nil } end
  for id in pairs(er.outputs or {}) do
    rows[#rows + 1] = { id = id, a = pf(id, false), b = pn(id, false), sell = true }
    rows[#rows + 1] = { label = "Sold per day (AHledger)", a = ns.HistField(H, id, first, "pd"), b = ns.HistField(H, id, now, "pd"), perDay = true }
  end
  rows[#rows + 1] = { label = "Total cost to make", a = pts[1].cost, b = pts[#pts].cost }
  rows[#rows + 1] = { label = "Sells for (after cut)", a = pts[1].value, b = pts[#pts].value }
  return { pts = pts, first = first, today = now, hi = hi, rows = rows }
end
---------------------------------------------------------------- footer: settings

local BASIS_HELP = {
  now = { "Now", "The cheapest listing from your last live check (Check prices, under an hour old), else today's median. Reacts fastest, but one odd listing moves it." },
  ["7d"] = { "7 days", "Median of the last 7 days. Smooths out today's outliers." },
  safe = { "Safe", "The lower of today's and the 7-day median (cautious). The verdict always uses this." },
}
ns.BASIS_HELP, ns.Basis = BASIS_HELP, Basis
---------------------------------------------------------------- refresh everything

RefreshAll = function() if ns.RefreshUI then ns.RefreshUI() end end -- the window (UI/)


---------------------------------------------------------------- opening the window

local openedByAH = false

-- minimap button: click to open, drag to move it around the minimap
local mm = CreateFrame("Button", "FlipRulesMinimapButton", Minimap)
mm:SetSize(31, 31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture([[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]])
local mmIcon = mm:CreateTexture(nil, "BACKGROUND")
mmIcon:SetSize(20, 20)
mmIcon:SetPoint("CENTER", 0, 1)
local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture([[Interface\Minimap\MiniMap-TrackingBorder]])
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
mm:SetScript("OnClick", function() openedByAH = false; ns.ToggleUI() end)
mm:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("FlipRules")
  GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
  GameTooltip:Show()
end)
mm:SetScript("OnLeave", GameTooltip_Hide)

---------------------------------------------------------------- craft flips from the learned recipes

-- The crafter's learned recipes as craft flips (products that bind on pickup left out, writ links
-- attached) and as intermediates { [product] = { makes, reagents } }. bop(id) -> true when the
-- product binds on pickup. Pure.
function ns.BuildCrafts(recipes, links, bop)
  local flips, inter = {}, {}
  for _, rc in ipairs(recipes or {}) do
    local out, made = next(rc.outputs or {})
    if out and next(rc.inputs or {}) then
      inter[out] = { makes = made, reagents = rc.inputs }
      if not bop(out) then
        local l = links[out]
        flips[#flips + 1] = { name = l and ("[%s] %s"):format(l.tier, rc.name) or rc.name, group = "Leatherworking",
          craft = true, inputs = rc.inputs, outputs = { [out] = made },
          writ = l and l.writ, tier = l and l.tier, station = l and l.station }
      end
    end
  end
  table.sort(flips, function(a, b) return a.name < b.name end)
  return flips, inter
end

do
local function IsBop(id)
  local bind = select(14, GetItemInfo(id))
  if bind == nil and C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
  return bind == 1 -- unknown until the item loads: kept, and the rebuild after login drops it
end

-- Replaces the craft flips in ns.rules (in place: other code holds ns.rules) with the saved recipes.
function ns.RebuildCrafts()
  local lw = FlipRulesDB and FlipRulesDB.lw
  local flips, inter = ns.BuildCrafts(lw and lw.recipes, ns.writLinks, IsBop)
  local keep = {}
  for _, r in ipairs(ns.rules) do if not r.craft then keep[#keep + 1] = r end end
  for _, r in ipairs(flips) do keep[#keep + 1] = r end
  for i = #ns.rules, 1, -1 do ns.rules[i] = nil end
  for i, r in ipairs(keep) do ns.rules[i] = r end
  for id, rec in pairs(inter) do ns.recipes[id] = rec end
end
end

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
    if not FlipRulesDB.earnV then -- purchases saved before 2026-11-25 hold item counts, not copper: drop them
      for name, e in pairs(FlipRulesDB.earn) do
        e.bought, e.spent = 0, 0
        if e.sold == 0 then FlipRulesDB.earn[name] = nil end -- reagent buys counted under a craft, nothing else
      end
      FlipRulesDB.earnV = 2
    end
    FlipRulesDB.hist = FlipRulesDB.hist or {}
    FlipRulesDB.track = FlipRulesDB.track or {}
    FlipRulesDB.scan = FlipRulesDB.scan or {}
    FlipRulesDB.chars = FlipRulesDB.chars or {}
    FlipRulesDB.chars[UnitName("player")] = true -- whose auctions are yours in a full scan
    ns.PruneHist(FlipRulesDB.hist, time())
    C_Timer.After(10, ns.ImportAHledger) -- after login settles
    FlipRulesDB.seen = nil -- 0.1 format, replaced by stats
    mmIcon:SetTexture(((C_Item and C_Item.GetItemIconByID) or GetItemIcon)(262890) or [[Interface\Icons\INV_Misc_Note_01]])
    PlaceMinimapButton()
    TrackOpens() -- baseline bag counts
    ns.RebuildCrafts()
    C_Timer.After(5, function() ns.RebuildCrafts(); RefreshAll() end) -- item data loaded by now: bind types known
    -- sale mail names the item but gives no id; names only resolve for items the client has loaded
    if C_Item and C_Item.RequestLoadItemDataByID then
      for _, r in ipairs(ns.rules) do for _, id in ipairs(RuleItems(r)) do C_Item.RequestLoadItemDataByID(id) end end
    end
    return
  end
  if event == "AUCTION_HOUSE_SHOW" then
    ahOpen = true
    if FlipRulesDB.withAH and not ns.UIShown() then
      openedByAH = true
      ns.ToggleUI(true)
    end
  end
  if event == "AUCTION_HOUSE_CLOSED" then
    ahOpen, posting = false, nil
    StaticPopup_Hide("FLIPRULES_POST_CONFIRM")
    if openedByAH and ns.UIShown() then ns.ToggleUI(false) end
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
  if event == "AUCTION_HOUSE_CLOSED" then searchQueue, searching = {}, nil; C_Timer.After(15, ns.ImportAHledger) end
  if event == "BAG_UPDATE_DELAYED" then TrackOpens() end
  if TRADE_EVENTS[event] then ScanTradeSkill() end
  RefreshAll()
end)

-- /flip only opens the window; every setting lives in it
SLASH_FLIPRULES1 = "/flip"
SlashCmdList.FLIPRULES = function(msg)
  if (msg or ""):lower() == "test" then return SelfTest() end
  openedByAH = false
  ns.ToggleUI()
end
