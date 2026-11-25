-- Writs tab: the writ flips (open a sealed writ, sell the Craftsman's Writ) with the details pane.

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local COLS = W.Columns({
  { key = "verdict", label = "", width = 46, justify = "LEFT" },
  { key = "name", label = "Writ flip", width = 250, justify = "LEFT" },
  { key = "cost", label = "Sealed", width = 80, justify = "RIGHT", tip = "What one sealed writ costs on the AH now." },
  { key = "value", label = "Writ value", width = 80, justify = "RIGHT", tip = "What the writ you open is worth on average, after the 5% AH cut." },
  { key = "profit", label = "Profit", width = 80, justify = "RIGHT", tip = "Per sealed writ opened." },
  { key = "perDay", label = "Sold/day", width = 64, justify = "RIGHT", tip = "How many of the writs from this pool sell a day, on average per writ." },
})

local function WritRules()
  local list = {}
  for _, r in ipairs(ns.rules) do if r.use and r.pool then list[#list + 1] = r end end
  return list
end

local function Selected()
  local name = UI.DB().writSel
  for _, r in ipairs(WritRules()) do if r.name == name then return r end end
  return WritRules()[1]
end

local function Build(p)
  p.checkAll = W.Button(p, "Check all writs", function()
    local ids = {}
    for _, r in ipairs(WritRules()) do ids[#ids + 1] = r.use; for _, id in ipairs(ns.RuleItems(r)) do ids[#ids + 1] = id end end
    ns.CheckAll(ids)
  end, { width = 120, tip = function() return { "Check all writs", "Prices the three sealed writs and every writ they can "
    .. "drop: a full scan of the auction house when one is allowed, otherwise a few queries by item class.", ns.ScanStatus() } end })
  p.checkAll:SetPoint("TOPLEFT", COLS.width + 8 - 120, 0)
  p.check = W.Button(p, "Check prices", function()
    local r = Selected()
    if r then local ids = { r.use } for _, id in ipairs(ns.RuleItems(r)) do ids[#ids + 1] = id end ns.Check(ids) end
  end, { width = 100, tip = { "Check prices", "Searches the selected sealed writ and every writ it can drop, one at a time." } })
  p.check:SetPoint("RIGHT", p.checkAll, "LEFT", -T.GAP, 0)

  p.heads = W.SortHeads(p, COLS, function() return nil end, function() end)
  p.heads:SetPoint("TOPLEFT", 0, -28)
  p.heads:SetWidth(COLS.width + 8)

  p.list = W.RowList(p, {
    cols = COLS,
    fill = function(row, e)
      local v, col = ns.Verdict(e)
      row.cells.verdict:SetText(col .. v .. "|r")
      row.cells.name:SetText(e.rule.name)
      row.cells.cost:SetText(ns.Money(e.cost))
      row.cells.value:SetText(ns.Money(e.value))
      row.cells.profit:SetText(ns.Money(e.profit))
      row.cells.perDay:SetText(e.perDay and ("%.1f"):format(e.perDay) .. (e.paceOwn and "*" or "") or "-")
    end,
    onClick = function(e) UI.DB().writSel, UI.DB().lastSel = e.rule.name, e.rule.name; UI.Refresh() end,
    onEnter = function(row, e) ns.ShowBreakdown(row, e) end,
  })
  p.list:SetPoint("TOPLEFT", p.heads, "BOTTOMLEFT", 0, 0)
  p.list:SetWidth(COLS.width + 8)
  p.list:SetHeight(math.max(3, #WritRules()) * T.ROW_H)
  p.list:SetSelected(function(e) local s = Selected() return s and e.rule.name == s.name end)

  local hint = T.Label(p, "small", "dim")
  hint:SetPoint("TOPLEFT", p.list, "BOTTOMLEFT", 0, -T.PAD)
  hint:SetWidth(COLS.width)
  hint:SetWordWrap(true)
  hint:SetText("Opening writs, stock & demand and posting are still in the old window (/flip) until the last piece.")

  p.details = UI.Details(p)
  p.details:SetPoint("TOPLEFT", p.heads, "TOPRIGHT", T.PAD, 0)
  p.details:SetPoint("BOTTOMRIGHT", 0, 0)
end

local function Refresh(p)
  p.heads:Refresh()
  local items = {}
  for _, r in ipairs(WritRules()) do items[#items + 1] = ns.Evaluated(r) end
  table.sort(items, function(a, b) return (a.profit or -math.huge) > (b.profit or -math.huge) end)
  p.list:SetItems(items)
  local open = ns.AHOpen()
  p.check:SetEnabled(open)
  p.checkAll:SetEnabled(open and not ns.ScanBusy(true))
  p.checkAll:SetLabel(ns.ScanBusy(true) and "Scanning..." or "Check all writs")
  p.details:SetRule(Selected())
end

UI.AddTab("writs", Build, Refresh)
