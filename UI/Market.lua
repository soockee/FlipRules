-- Market tab: Movers (every item FlipRules knows, by gold moved a day, units sold or hours of cover)
-- and Sealed stock (would opening more sealed writs flood the writs they drop?).

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local MOVER_COLS = W.Columns({
  { key = "name", label = "Item", width = 260, justify = "LEFT" },
  { key = "sold", label = "Sold/day", width = 70, justify = "RIGHT", sort = true, tip = "AHledger's crowd estimate, or your own scans'." },
  { key = "listed", label = "Listed", width = 70, justify = "RIGHT" },
  { key = "cover", label = "Cover", width = 60, justify = "RIGHT", sort = true, tip = "Hours until what's listed now sells out at today's pace. Red: under 12 h while selling 10+ a day." },
  { key = "price", label = "Price", width = 90, justify = "RIGHT" },
  { key = "gold", label = "Gold/day", width = 100, justify = "RIGHT", sort = true, tip = "Sold a day x price: where the money moves." },
})
local STOCK_COLS = W.Columns({
  { key = "name", label = "Writ (drop chance)", width = 260, justify = "LEFT" },
  { key = "bar", label = "Days to sell what's listed: now, + yours", width = 300, justify = "LEFT" },
  { key = "val", label = "", width = 220, justify = "LEFT" },
})
local BAR_W, BAR_MAX = 290, 30 -- the bars end at a month

local function Count(n) return n >= 10000 and ("%.0fk"):format(n / 1000) or n >= 100 and ("%.0f"):format(n) or ("%.1f"):format(n) end
local function Cover(h) return h == math.huge and "-" or h >= 48 and ("%.0fd"):format(h / 24) or ("%.0fh"):format(h) end
local function Days(d) return d == math.huge and "never" or d >= BAR_MAX and ("%d+d"):format(BAR_MAX) or ("%.1fd"):format(d) end

local function WritRules()
  local list = {}
  for _, r in ipairs(ns.rules) do if r.use and r.pool then list[#list + 1] = r end end
  return list
end

local function Build(p)
  local db = UI.DB()
  p.mode = W.Segmented(p, { { "movers", "Movers" }, { "stock", "Sealed stock" } },
    function() return db.marketMode or "movers" end, function(k) db.marketMode = k; UI.Refresh() end, 110)
  p.mode:SetPoint("TOPLEFT", 0, 0)

  -- movers
  p.mv = CreateFrame("Frame", nil, p)
  p.mv:SetPoint("TOPLEFT", 0, -28); p.mv:SetPoint("BOTTOMRIGHT")
  p.mvHeads = W.SortHeads(p.mv, MOVER_COLS, function() return db.moverKey or "gold", db.moverKey == "cover" end,
    function(k) db.moverKey = k; p.mvList.offset = 0; UI.Refresh() end)
  p.mvHeads:SetPoint("TOPLEFT"); p.mvHeads:SetWidth(MOVER_COLS.width + 8)
  p.mvList = W.RowList(p.mv, {
    cols = MOVER_COLS,
    fill = function(row, it)
      local c = it.short and "loss" or "text"
      row.cells.name:SetText((ns.Name(it.id):gsub("^Craftsman's Writ: ", "Writ: ")))
      row.cells.name:SetTextColor(T.Unpack(c))
      row.cells.sold:SetText(Count(it.perDay or 0))
      row.cells.listed:SetText(Count(it.listed or 0))
      row.cells.cover:SetText(Cover(it.cover)); row.cells.cover:SetTextColor(T.Unpack(c))
      row.cells.price:SetText(ns.Money(it.price))
      row.cells.gold:SetText(ns.Money(math.floor(it.gold)))
    end,
    onEnter = function(row, it)
      GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(it.id)
      GameTooltip:Show()
    end,
  })
  p.mvList:SetPoint("TOPLEFT", p.mvHeads, "BOTTOMLEFT")
  p.mvList:SetPoint("BOTTOMLEFT", 0, 34)
  p.mvList:SetWidth(MOVER_COLS.width + 8)
  p.mvNote = T.Label(p.mv, "small", "muted")
  p.mvNote:SetPoint("BOTTOMLEFT", 0, 2); p.mvNote:SetPoint("RIGHT", p.mv, "RIGHT")
  p.mvNote:SetWordWrap(true)

  -- sealed stock
  p.st = CreateFrame("Frame", nil, p)
  p.st:SetPoint("TOPLEFT", 0, -28); p.st:SetPoint("BOTTOMRIGHT")
  local choices = {}
  for _, r in ipairs(WritRules()) do choices[#choices + 1] = { r.name, (r.name:match("^Sealed (%a+)") or r.name) } end
  p.stRule = W.Segmented(p.st, choices, function() return db.stockRule or (choices[1] and choices[1][1]) end,
    function(k) db.stockRule = k; UI.Refresh() end, 110)
  p.stRule:SetPoint("TOPLEFT")
  local label = T.Label(p.st, "small", "muted")
  label:SetPoint("LEFT", p.stRule, "RIGHT", T.PAD, 0)
  label:SetText("Sealed to open (empty = every one listed):")
  p.stBox = CreateFrame("EditBox", nil, p.st, "InputBoxTemplate")
  p.stBox:SetSize(60, 18)
  p.stBox:SetPoint("LEFT", label, "RIGHT", 10, 0)
  p.stBox:SetAutoFocus(false)
  p.stBox:SetNumeric(true)
  p.stBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  p.stBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  p.stBox:SetScript("OnTextChanged", function(_, user) if user then UI.Refresh() end end)
  p.stHead = T.Label(p.st, "large", "text")
  p.stHead:SetPoint("TOPLEFT", 0, -30)
  p.stSum = T.Label(p.st, "small", "muted")
  p.stSum:SetPoint("TOPLEFT", 0, -50); p.stSum:SetPoint("RIGHT", p.st, "RIGHT")
  p.stSum:SetWordWrap(true)
  p.stHeads = W.SortHeads(p.st, STOCK_COLS, function() return nil end, function() end)
  p.stHeads:SetPoint("TOPLEFT", 0, -84); p.stHeads:SetWidth(STOCK_COLS.width + 8)
  p.stList = W.RowList(p.st, {
    cols = STOCK_COLS,
    fill = function(row, it)
      if not row.base then -- the bar: grey = listed now, gold = what you'd add
        row.base = row:CreateTexture(nil, "ARTWORK"); row.base:SetHeight(10)
        row.base:SetPoint("LEFT", STOCK_COLS[2].x + 4, 0)
        row.mine = row:CreateTexture(nil, "ARTWORK"); row.mine:SetHeight(10)
        row.mine:SetPoint("LEFT", row.base, "RIGHT")
        row.base:SetColorTexture(T.Unpack("muted")); row.mine:SetColorTexture(T.Unpack("accent"))
        row.okLine = row:CreateTexture(nil, "OVERLAY"); row.okLine:SetSize(1, T.ROW_H)
        row.okLine:SetColorTexture(T.Unpack("good", 0.8))
      end
      local px = BAR_W / BAR_MAX
      local base = math.min(it.now, BAR_MAX)
      local mine = math.min(it.after, BAR_MAX) - base
      row.base:SetWidth(math.max(1, base * px))
      row.mine:SetWidth(math.max(1, mine * px)); row.mine:SetShown(mine > 0)
      row.okLine:SetPoint("LEFT", STOCK_COLS[2].x + 4 + p.okDays * px, 0)
      row.cells.name:SetText(("%s  %s%.1f%%|r"):format((ns.Name(it.id):gsub("^Craftsman's Writ: ", "")), T.Hex("dim"), 100 * it.odds))
      row.cells.bar:SetText("")
      row.cells.val:SetText(("%s%s > %s|r  %s%d listed +%.1f, %.1f/day|r"):format(T.Hex(it.after <= p.okDays and "good" or "loss"),
        Days(it.now), Days(it.after), T.Hex("dim"), it.stock, it.add, it.perDay or 0))
    end,
  })
  p.stList:SetPoint("TOPLEFT", p.stHeads, "BOTTOMLEFT")
  p.stList:SetPoint("BOTTOMLEFT")
  p.stList:SetWidth(STOCK_COLS.width + 8)
end

local function Refresh(p)
  local db = UI.DB()
  p.mode:Refresh()
  local movers = (db.marketMode or "movers") == "movers"
  p.mv:SetShown(movers); p.st:SetShown(not movers)
  if movers then
    p.mvHeads:Refresh()
    local rows = ns.MoverRows(db.moverKey or "gold")
    local short = 0
    for _, r in ipairs(rows) do if r.short then short = short + 1 end end
    p.mvList:SetItems(rows)
    p.mvNote:SetText(("%d items, %s%d likely under-supplied|r (red: under 12 h of cover while selling 10+ a day). "
      .. "Sold/day is AHledger's estimate from players' scans, or yours; listed is your last full scan or check."):format(
      #rows, T.Hex("loss"), short))
    return
  end
  p.stRule:Refresh()
  local r
  for _, x in ipairs(WritRules()) do if x.name == (db.stockRule or WritRules()[1].name) then r = x end end
  if not r then return end
  local t = ns.SupplyFor(r, tonumber(p.stBox:GetText()))
  p.okDays = t.okDays
  local word, col = "Oversupplied", "loss"
  if t.fastShare >= 0.7 then word, col = "Balanced", "good" elseif t.fastShare >= 0.4 then word, col = "Tight", "warn" end
  p.stHead:SetText(("%s%s|r  -  %d sealed listed (%s), opening %d"):format(T.Hex(col), word, t.listedSealed,
    t.sealedSrc or "no data", t.sealed))
  p.stSum:SetText(("Opened writs listed: %d, selling ~%.1f a day in total: %s of supply now, %s after you add %d. "
    .. "%s%.0f%%|r of the writs you'd open land where everything listed sells within %d days (green line).%s"):format(
    t.stock, t.perDay, Days(t.now), Days(t.after), t.sealed, T.Hex(col), 100 * t.fastShare, t.okDays,
    t.unknown > 0 and (" %d writs have no listing data yet."):format(t.unknown) or ""))
  p.stList:SetItems(t.rows)
end

UI.AddTab("market", Build, Refresh)
