-- The details pane next to a tab's list: the verdict on top, then sections laid out as tables
-- (key numbers, checks, what you buy down the chains, what you sell, your record, drop stats).
-- Everything below the verdict scrolls, and the tables reflow when the pane is resized.

local _, ns = ...
local T, UI = ns.Theme, ns.UI
local M = function(c) return ns.Money(c) end

-- A small layout engine over pooled font strings and bands: y moves down as sections are added.
local function Layout(child)
  local L = { fs = {}, tex = {}, nfs = 0, ntex = 0, y = 0, w = 300 }
  function L:Begin(w) self.nfs, self.ntex, self.y, self.w = 0, 0, 0, w end
  function L:Text(text, x, y, w, size, color, justify, wrap)
    self.nfs = self.nfs + 1
    local fs = self.fs[self.nfs]
    if not fs then fs = T.Label(child, "small"); self.fs[self.nfs] = fs end
    fs:SetFont(T.FONT, T.sizes[size or "small"], "")
    fs:SetTextColor(T.Unpack(color or "text"))
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(wrap and true or false)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", x, -y)
    fs:SetWidth(w)
    fs:SetText(text or "")
    fs:Show()
    return fs
  end
  function L:Band(y, h, key, alpha)
    self.ntex = self.ntex + 1
    local t = self.tex[self.ntex]
    if not t then t = child:CreateTexture(nil, "BACKGROUND"); self.tex[self.ntex] = t end
    t:SetColorTexture(T.Unpack(key, alpha))
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", 0, -y)
    t:SetSize(self.w, h)
    t:Show()
  end
  function L:End()
    for i = self.nfs + 1, #self.fs do self.fs[i]:Hide() end
    for i = self.ntex + 1, #self.tex do self.tex[i]:Hide() end
    return self.y
  end
  function L:Gap(h) self.y = self.y + (h or 10) end
  function L:Heading(text)
    self:Gap(6)
    self:Text(text, 0, self.y, self.w, "normal", "heading")
    self.y = self.y + 18
  end
  function L:Line(text, color, size)
    local fs = self:Text(text, 0, self.y, self.w, size or "small", color or "text", "LEFT", true)
    self.y = self.y + math.max(14, fs:GetStringHeight() + 3)
  end
  -- label/value pairs in `cols` columns
  function L:Pairs(list, cols)
    cols = cols or 2
    local cw = self.w / cols
    for i, kv in ipairs(list) do
      local c, row = (i - 1) % cols, math.floor((i - 1) / cols)
      local y = self.y + row * 16
      self:Text(kv[1], c * cw, y, cw * 0.5, "small", "muted")
      self:Text(kv[2], c * cw + cw * 0.5, y, cw * 0.5 - 12, "small", kv[3] or "text", "RIGHT")
    end
    self.y = self.y + math.ceil(#list / cols) * 16 + 2
  end
  -- cols = { { label, width (nil: takes the rest), justify }, ... }; rows = { { cells..., color = key }, ... }
  function L:Table(cols, rows)
    local fixed, flex = 0, 0
    for _, c in ipairs(cols) do if c[2] then fixed = fixed + c[2] else flex = flex + 1 end end
    local gap = 6
    local rest = math.max(60, (self.w - fixed - gap * (#cols - 1)) / math.max(1, flex))
    local xs, x = {}, 0
    for i, c in ipairs(cols) do xs[i] = { x, c[2] or rest }; x = x + (c[2] or rest) + gap end
    self:Band(self.y, 16, "header")
    for i, c in ipairs(cols) do self:Text(c[1], xs[i][1] + 4, self.y + 2, xs[i][2] - 4, "tiny", "heading", c[3]) end
    self.y = self.y + 16
    for r, row in ipairs(rows) do
      self:Band(self.y, 16, r % 2 == 0 and "rowAlt" or "row")
      for i, c in ipairs(cols) do
        self:Text(row[i], xs[i][1] + 4, self.y + 2, xs[i][2] - 4, "small", row.color or "text", c[3])
      end
      self.y = self.y + 16
    end
    if #rows == 0 then self:Line("  none", "dim") end
    self.y = self.y + 4
  end
  return L
end

local function Qty(q) return q == math.floor(q) and ("%d"):format(q) or ("%.2f"):format(q) end
local function PerDayText(v) return v and (v >= 10 and "%.0f" or "%.1f"):format(v) or "?" end
local HOW = { vendor = "vendor", AH = "AH", craft = "craft" }
local function Pct(p) return p and ("%.0f%%"):format(100 * p) or "-" end

local function Chain(L, rows)
  local t = {}
  for _, x in ipairs(rows) do
    t[#t + 1] = { ("    "):rep(x.depth - 1) .. ns.Name(x.id), Qty(x.qty), x.each and (HOW[x.how] or "?") or "no price",
      M(x.each), M(x.total), x.alt or "", color = x.dim and "dim" or (not x.each and "loss") or nil }
  end
  L:Table({ { "Item" }, { "Qty", 44, "RIGHT" }, { "How", 52 }, { "Each", 78, "RIGHT" }, { "Total", 78, "RIGHT" },
    { "Other way", 96, "RIGHT" } }, t)
end

local function Record(L, rec)
  local s, t = rec.sum, rec.track
  if s then
    L:Pairs({
      { "Posted", t.posted }, { "Still up", s.open },
      { "Sold", t.sold, "good" }, { "Expired", t.expired, t.expired > 0 and "loss" or nil },
      { "Cancelled", t.cancelled }, { "Sold of ended", Pct(s.through), s.through and (s.through >= 0.6 and "good" or "loss") or nil },
      { "Hours to sell", s.hours and ("%.0f h"):format(s.hours) or "-" }, { "You got each", M(s.each) },
      { "Of your list price", Pct(s.ofList) }, { "Profit per sold", M(s.profit) },
    })
  else
    L:Line("No posts recorded yet: counted from now on, ended by the auction mail you take.", "dim")
  end
  if #rec.days > 0 then
    local rows = {}
    for _, d in ipairs(rec.days) do rows[#rows + 1] = { d.day, M(d.lo), d.n or 0 } end
    L:Gap(4)
    L:Table({ { "Day", 70 }, { "Cheapest listing", 110, "RIGHT" }, { "Listed", 70, "RIGHT" } }, rows)
  end
  if #rec.crowd > 0 then
    local rows = {}
    for _, c in ipairs(rec.crowd) do rows[#rows + 1] = { c.day, M(c.median), PerDayText(c.perDay) } end
    L:Table({ { "AHledger update", 110 }, { "Median", 90, "RIGHT" }, { "Sold/day", 70, "RIGHT" } }, rows)
  end
end

local function Fill(L, r, d)
  local e = d.e
  L:Pairs({
    { "Cost", M(e.cost) }, { "Sells for (after cut)", M(e.value) },
    { "Profit", M(e.profit), (e.profit or 0) >= 0 and "good" or "loss" }, { "At cautious prices", M(e.safe) },
    { "Week low .. high", M(e.worst) .. " .. " .. M(e.best) },
    r.use and { "Break-even buy", M(e.maxBuy) } or { "Profit a day", M(e.profitDay) },
  })
  L:Heading("Checks")
  for _, ch in ipairs(ns.Checks(e)) do L:Line((ch[1] and T.Hex("good") .. "+|r  " or T.Hex("loss") .. "x|r  ") .. ch[2]) end
  if d.writ then L:Gap(4); L:Line(("Asked for by %s (%s writ)"):format(d.writ.link, d.writ.tier or "?"), "muted") end

  if d.chain then
    L:Heading("Buy  (down the production chain)")
    Chain(L, d.chain)
    if d.station then
      L:Line(("Station, shared by %d crafts:"):format(d.station.crafts), "muted")
      Chain(L, d.station.rows)
    end
    L:Pairs({ { "Total per craft", M(e.cost) } }, 1)
  elseif d.buy then
    L:Heading("Buy")
    local rows = {}
    for _, b in ipairs(d.buy) do rows[#rows + 1] = { ns.Name(b.id), Qty(b.qty), M(b.each), M(b.each and b.each * b.qty) } end
    L:Table({ { "Item" }, { "Qty", 44, "RIGHT" }, { "Each", 78, "RIGHT" }, { "Total", 78, "RIGHT" } }, rows)
  end

  if #d.sell > 0 then
    L:Heading(("Sell  (valued at %s)"):format(d.basis))
    local rows = {}
    for _, s in ipairs(d.sell) do
      rows[#rows + 1] = { ns.Name(s.id), Qty(s.qty), M(s.price), PerDayText(s.perDay),
        not s.checked and "not checked live" or (s.variants or 0) > 1 and (s.variants .. " variants") or "" }
    end
    L:Table({ { "Item" }, { "Qty", 44, "RIGHT" }, { "Price", 78, "RIGHT" }, { "Sold/day", 64, "RIGHT" }, { "Note", 110, "RIGHT" } }, rows)
    L:Pairs({ { "After 5% AH cut", M(e.value) }, { "Profit per craft", M(e.profit), (e.profit or 0) >= 0 and "good" or "loss" } })
    for _, rec in ipairs(d.records) do
      L:Heading("Your record" .. (#d.records > 1 and ("  -  " .. ns.Name(rec.id)) or ""))
      Record(L, rec)
    end
  end

  local dr = d.drops
  if dr then
    L:Heading("Earned")
    if dr.earn then
      L:Pairs({ { "Net", M(dr.earn.revenue - dr.earn.spent), dr.earn.revenue >= dr.earn.spent and "good" or "loss" },
        { "Sold", ("%d for %s"):format(dr.earn.sold, M(dr.earn.revenue)) }, { "Bought", ("%d for %s"):format(dr.earn.bought, M(dr.earn.spent)) } })
    else
      L:Line("Nothing yet: counted when you take auction mail for this flip.", "dim")
    end
    L:Heading(("Opened %d"):format(dr.opens))
    if dr.opens < dr.need then L:Line(("Profit uses equal odds until %d opens."):format(dr.need), "dim") end
    if dr.avg then L:Pairs({ { "Average value per open", M(dr.avg) } }, 1) end
    L:Heading("By category")
    local rows = {}
    for _, c in ipairs(dr.cats) do
      rows[#rows + 1] = { c.cat, c.count, ("%.1f%%"):format(100 * c.share), ("%.1f"):format(100 * c.margin), ("%.1f%%"):format(100 * c.uniform) }
    end
    L:Table({ { "Category" }, { "Count", 50, "RIGHT" }, { "Share", 60, "RIGHT" }, { "+/-", 44, "RIGHT" }, { "Equal odds", 76, "RIGHT" } }, rows)
    L:Heading("By item")
    rows = {}
    for _, it in ipairs(dr.items) do
      rows[#rows + 1] = { (ns.Name(it.id):gsub("^Craftsman's Writ: ", "")), it.cat, it.count, ("%.1f%%"):format(100 * it.chance),
        M(it.price), PerDayText(it.perDay), color = not it.inPool and "loss" or nil }
    end
    L:Table({ { "Item" }, { "Category", 96 }, { "Count", 44, "RIGHT" }, { "Chance", 54, "RIGHT" }, { "Price", 78, "RIGHT" },
      { "Sold/day", 58, "RIGHT" } }, rows)
  end
  L:Gap(6)
  L:Line("Vendor items at their vendor price; anything you can make costs the cheaper of the AH and crafting it "
    .. "(indented: what crafting it takes, grey when buying is cheaper).", "dim", "tiny")
end

function UI.Details(parent)
  local d = CreateFrame("Frame", nil, parent)
  T.Fill(d, "panel")
  T.Border(d, "border")

  d.verdict = T.Label(d, "title", "text")
  d.verdict:SetPoint("TOPLEFT", T.PAD, -T.PAD)
  d.name = T.Label(d, "large", "text")
  d.name:SetPoint("LEFT", d.verdict, "RIGHT", 8, 0)
  d.name:SetPoint("RIGHT", d, "RIGHT", -T.PAD, 0)
  d.why = T.Label(d, "small", "muted")
  d.why:SetPoint("TOPLEFT", d.verdict, "BOTTOMLEFT", 0, -4)
  d.why:SetPoint("RIGHT", d, "RIGHT", -T.PAD, 0)
  local line = d:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(T.Unpack("border"))
  line:SetPoint("TOPLEFT", T.PAD, -50); line:SetPoint("TOPRIGHT", -T.PAD, -50); line:SetHeight(1)

  local scroll = CreateFrame("ScrollFrame", nil, d)
  scroll:SetPoint("TOPLEFT", T.PAD, -56)
  scroll:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  local L = Layout(child)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, child:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
  end)

  local empty = T.Label(d, "normal", "muted", "CENTER")
  empty:SetPoint("CENTER")
  empty:SetText("Select a flip in the list.")

  function d:SetRule(r)
    local shown = r ~= nil
    for _, x in ipairs({ self.verdict, self.name, self.why, line, scroll }) do x:SetShown(shown) end
    empty:SetShown(not shown)
    if not r then return end
    local e = ns.Evaluated(r)
    local v, col, why = ns.Verdict(e)
    self.verdict:SetText(col .. v .. "|r")
    self.name:SetText(r.name)
    self.why:SetText(table.concat(why, "; "))
    if self.rule ~= r then scroll:SetVerticalScroll(0) end
    self.rule = r
    local w = math.max(300, scroll:GetWidth())
    child:SetWidth(w)
    L:Begin(w)
    Fill(L, r, ns.DetailData(r))
    child:SetHeight(L:End() + 10)
  end
  -- reflow the tables when the pane changes size
  local pending = false -- while the window is dragged bigger, reflow once per 0.1 s, not every frame
  scroll:SetScript("OnSizeChanged", function()
    if pending or not d.rule then return end
    pending = true
    C_Timer.After(0.1, function() pending = false; if d.rule and d:IsVisible() then d:SetRule(d.rule) end end)
  end)
  d:SetRule(nil)
  return d
end
