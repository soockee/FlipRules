-- Leatherworking tab: every craft flip (writ-linked or all learned recipes) in one sortable list.

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local COLS = W.Columns({
  { key = "verdict", label = "", width = 46, justify = "LEFT", sort = true },
  { key = "name", label = "Craft flip", width = 250, justify = "LEFT", sort = true },
  { key = "cost", label = "Cost", width = 80, justify = "RIGHT", sort = true, tip = "Reagents (the cheaper of buying and crafting each) plus the station share for writ crafts." },
  { key = "profit", label = "Profit", width = 80, justify = "RIGHT", sort = true, tip = "Per craft, after the 5% AH cut." },
  { key = "perDay", label = "Sold/day", width = 64, justify = "RIGHT", sort = true, tip = "Units sold a day on the AH: AHledger's crowd figure, or * = from your own scans." },
  { key = "profitDay", label = "Profit/day", width = 90, justify = "RIGHT", sort = true, tip = "Profit per craft x sold a day, counting at most 10 a day." },
})
local VERDICT_ORDER = { YES = 4, RISKY = 3, NO = 1, ["?"] = 0 }

local function State()
  local db = UI.DB()
  return db.lwSort or "profitDay", db.lwAsc or false
end

local function Items()
  local all = FlipRulesDB.lwView == "all"
  local items = {}
  for _, r in ipairs(ns.rules) do
    if r.group == "Leatherworking" and (all or r.writ) then
      local e = ns.Evaluated(r)
      e.verdict = ns.Verdict(e)
      items[#items + 1] = e
    end
  end
  local key, asc = State()
  table.sort(items, function(a, b)
    local x, y
    if key == "name" then x, y = a.rule.name, b.rule.name
    elseif key == "verdict" then x, y = VERDICT_ORDER[a.verdict] or 0, VERDICT_ORDER[b.verdict] or 0
    else x, y = a[key] or -math.huge, b[key] or -math.huge end
    if x == y then return a.rule.name < b.rule.name end
    if asc then return x < y end
    return x > y
  end)
  return items
end

local function Selected()
  local name = UI.DB().lwSel
  for _, r in ipairs(ns.rules) do if r.name == name then return r end end
end

local function Build(p)
  local view = W.Segmented(p, {
    { "writ", "Writ-linked", { "Writ-linked", "Only crafts a Craftsman's Writ asks for." } },
    { "all", "All crafts", { "All crafts", "Every recipe your crafter has learned, except products that bind when picked up." } },
  }, function() return FlipRulesDB.lwView == "all" and "all" or "writ" end,
  function(k) FlipRulesDB.lwView = k; p.list.offset = 0; UI.Refresh() end)
  view:SetPoint("TOPLEFT", 0, 0)
  p.view = view

  p.checkAll = W.Button(p, "Check all", function()
    local ids = {}
    for _, r in ipairs(ns.rules) do if r.group == "Leatherworking" then for _, id in ipairs(ns.RuleItems(r)) do ids[#ids + 1] = id end end end
    ns.CheckAll(ids)
  end, { width = 90, tip = function() return { "Check all", "Prices every item of every craft flip: a full scan of the "
    .. "auction house when one is allowed, otherwise a few queries by item class.", ns.ScanStatus() } end })
  p.checkAll:SetPoint("TOPRIGHT", 0, 0)
  p.check = W.Button(p, "Check prices", function()
    local r = Selected()
    if r then ns.Check(ns.RuleItems(r)) end
  end, { width = 100, tip = { "Check prices", "Searches every item of the selected craft flip: product, reagents down the chains, station." } })
  p.check:SetPoint("RIGHT", p.checkAll, "LEFT", -T.GAP, 0)

  p.heads = W.SortHeads(p, COLS, State, function(key)
    local db = UI.DB()
    if db.lwSort == key or (not db.lwSort and key == "profitDay") then db.lwAsc = not db.lwAsc
    else db.lwSort, db.lwAsc = key, key == "name" end
    UI.Refresh()
  end)
  p.heads:SetPoint("TOPLEFT", 0, -28)
  p.heads:SetWidth(COLS.width + 8)

  p.list = W.RowList(p, {
    cols = COLS,
    fill = function(row, e)
      local v, col = ns.Verdict(e)
      row.cells.verdict:SetText(col .. v .. "|r")
      row.cells.name:SetText(e.rule.name)
      row.cells.cost:SetText(ns.Money(e.cost))
      row.cells.profit:SetText(ns.Money(e.profit))
      row.cells.perDay:SetText(e.perDay and (e.perDay >= 10 and "%.0f" or "%.1f"):format(e.perDay) .. (e.paceOwn and "*" or "") or "-")
      row.cells.profitDay:SetText(ns.Money(e.profitDay))
    end,
    onClick = function(e) UI.DB().lwSel, UI.DB().lastSel = e.rule.name, e.rule.name; UI.Refresh() end,
    onEnter = function(row, e) ns.ShowBreakdown(row, e) end,
  })
  p.list:SetPoint("TOPLEFT", p.heads, "BOTTOMLEFT", 0, 0)
  p.list:SetPoint("BOTTOMLEFT", 0, 20)
  p.list:SetWidth(COLS.width + 8)
  p.list:SetSelected(function(e) return e.rule.name == UI.DB().lwSel end)

  p.status = T.Label(p, "small", "muted")
  p.status:SetPoint("BOTTOMLEFT", 0, 2)
  p.status:SetWidth(COLS.width)

  p.details = UI.Details(p)
  p.details:SetPoint("TOPLEFT", p.heads, "TOPRIGHT", T.PAD, 0)
  p.details:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function Refresh(p)
  p.view:Refresh()
  p.heads:Refresh()
  local items = Items()
  p.list:SetItems(items)
  local open = ns.AHOpen()
  p.check:SetEnabled(open and Selected() ~= nil)
  p.details:SetRule(Selected())
  p.checkAll:SetEnabled(open and not ns.ScanBusy(true))
  p.checkAll:SetLabel(ns.ScanBusy(true) and "Scanning..." or "Check all")
  local lw = FlipRulesDB.lw
  p.status:SetText(lw and ("%d craft flips  -  %d learned recipes of %s, saved %s%s"):format(#items, #lw.recipes, lw.char,
    date("%m-%d %H:%M", lw.t), open and "" or "  -  open the AH to check prices")
    or "Open your crafter's Leatherworking window once to add the recipes.")
end

UI.AddTab("lw", Build, Refresh)
