-- History tab: the flip you last selected (Writs or Leatherworking), what it sells for against what it
-- costs to make, one point per scan; below, each input's and output's price then and now.

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local COLS = W.Columns({
  { key = "name", label = "Item", width = 330, justify = "LEFT" },
  { key = "a", label = "First point", width = 100, justify = "RIGHT" },
  { key = "b", label = "Now", width = 100, justify = "RIGHT" },
  { key = "c", label = "Change", width = 70, justify = "RIGHT" },
})

local function Rule()
  local name = UI.DB().lastSel
  for _, r in ipairs(ns.rules) do if r.name == name then return r end end
  for _, r in ipairs(ns.rules) do if r.use then return r end end
end

local function Build(p)
  p.head = T.Label(p, "large", "text")
  p.head:SetPoint("TOPLEFT")
  p.note = T.Label(p, "small", "muted")
  p.note:SetPoint("TOPLEFT", 0, -20); p.note:SetPoint("RIGHT", p, "RIGHT")
  local legend = T.Label(p, "small", "text")
  legend:SetPoint("TOPLEFT", 0, -36)
  legend:SetText(T.Hex("good") .. "--|r sells for (after AH cut)    " .. T.Hex("loss") .. "--|r costs to make    "
    .. T.Hex("dim") .. "one dot per scan or price check|r")

  p.plot = CreateFrame("Frame", nil, p)
  p.plot:SetPoint("TOPLEFT", 70, -56)
  p.plot:SetPoint("RIGHT", p, "RIGHT", -10, 0)
  p.plot:SetHeight(200)
  T.Fill(p.plot, "rowAlt")
  T.Border(p.plot, "border")
  p.yTop = T.Label(p, "tiny", "muted", "RIGHT"); p.yTop:SetPoint("TOPRIGHT", p.plot, "TOPLEFT", -4, 0); p.yTop:SetWidth(66)
  p.yMid = T.Label(p, "tiny", "muted", "RIGHT"); p.yMid:SetPoint("RIGHT", p.plot, "LEFT", -4, 0); p.yMid:SetWidth(66)
  p.xFirst = T.Label(p, "tiny", "muted"); p.xFirst:SetPoint("TOPLEFT", p.plot, "BOTTOMLEFT", 0, -3)
  p.xLast = T.Label(p, "tiny", "muted", "RIGHT"); p.xLast:SetPoint("TOPRIGHT", p.plot, "BOTTOMRIGHT", 0, -3)
  p.lines, p.dots, p.ticks = {}, {}, {}

  p.heads = W.SortHeads(p, COLS, function() return nil end, function() end)
  p.heads:SetPoint("TOPLEFT", p.plot, "BOTTOMLEFT", -70, -20)
  p.heads:SetWidth(COLS.width + 8)
  p.list = W.RowList(p, {
    cols = COLS,
    fill = function(row, it)
      local name = it.label or ((it.sell and T.Hex("good") .. "sell|r " or "") .. ns.Name(it.id) .. (it.vendor and T.Hex("dim") .. " (vendor)|r" or ""))
      local fmt = it.perDay and function(v) return v and ("%.1f/day"):format(v) or "?" end or ns.Money
      row.cells.name:SetText(name)
      row.cells.a:SetText(fmt(it.a)); row.cells.b:SetText(fmt(it.b))
      local ch = it.a and it.b and it.a > 0 and (it.b / it.a - 1) * 100
      row.cells.c:SetText(ch and (T.Hex(ch > 0.5 and "warn" or ch < -0.5 and "good" or "dim") .. ("%+.0f%%|r"):format(ch)) or "")
    end,
  })
  p.list:SetPoint("TOPLEFT", p.heads, "BOTTOMLEFT")
  p.list:SetPoint("BOTTOMLEFT", 0, 0)
  p.list:SetWidth(COLS.width + 8)
  local pending = false -- redraw once per 0.1 s while the window is resized
  p:SetScript("OnSizeChanged", function()
    if pending then return end
    pending = true
    C_Timer.After(0.1, function() pending = false; if p:IsVisible() then UI.Refresh() end end)
  end)
end

local function Draw(p, d)
  for _, l in ipairs(p.lines) do l:Hide() end
  for _, x in ipairs(p.dots) do x:Hide() end
  for _, t in ipairs(p.ticks) do t.tex:Hide(); t.fs:Hide() end
  local pw, ph = p.plot:GetWidth(), p.plot:GetHeight()
  local pts, hi = d.pts, d.hi > 0 and d.hi or 1
  p.yTop:SetText(ns.Money(hi)); p.yMid:SetText(ns.Money(hi / 2))
  p.xFirst:SetText(date("%m-%d %H:%M", d.first * 3600)); p.xLast:SetText(date("%m-%d %H:%M", d.today * 3600))
  local span = math.max(1, d.today - d.first)
  local function X(i) return #pts > 1 and (pts[i].slot - d.first) / span * pw or pw / 2 end
  local function Y(v) return v / hi * (ph - 14) end
  local ti, last = 0, date("%m-%d", d.first * 3600)
  for k = d.first + 1, d.today do -- a faint line where each day starts; at most 720 hours
    local day = date("%m-%d", k * 3600)
    if day ~= last then
      last = day
      local x = (k - d.first) / span * pw
      if x > 40 and x < pw - 40 then
        ti = ti + 1
        local t = p.ticks[ti]
        if not t then t = { tex = p.plot:CreateTexture(nil, "BORDER"), fs = T.Label(p.plot, "tiny", "dim", "CENTER") }; p.ticks[ti] = t end
        t.tex:SetColorTexture(1, 1, 1, 0.08); t.tex:ClearAllPoints(); t.tex:SetPoint("BOTTOMLEFT", x, 0); t.tex:SetSize(1, ph)
        t.fs:ClearAllPoints(); t.fs:SetPoint("TOP", p.plot, "BOTTOMLEFT", x, -3); t.fs:SetText(day)
        t.tex:Show(); t.fs:Show()
      end
    end
  end
  local li, di = 0, 0
  for key, c in pairs({ value = "good", cost = "loss" }) do
    for i, pt in ipairs(pts) do
      if pt[key] then
        di = di + 1
        local dot = p.dots[di] or p.plot:CreateTexture(nil, "OVERLAY")
        p.dots[di] = dot
        dot:SetColorTexture(T.Unpack(c)); dot:SetSize(5, 5); dot:ClearAllPoints()
        dot:SetPoint("CENTER", p.plot, "BOTTOMLEFT", X(i), Y(pt[key])); dot:Show()
        local q = pts[i + 1]
        if q and q[key] then
          li = li + 1
          local l = p.lines[li] or p.plot:CreateLine(nil, "ARTWORK")
          p.lines[li] = l
          l:SetThickness(2); l:SetColorTexture(T.Unpack(c))
          l:SetStartPoint("BOTTOMLEFT", p.plot, X(i), Y(pt[key])); l:SetEndPoint("BOTTOMLEFT", p.plot, X(i + 1), Y(q[key]))
          l:Show()
        end
      end
    end
  end
end

local function Refresh(p)
  local r = Rule()
  if not r then p.head:SetText("Select a flip on the Writs or Leatherworking tab.") return end
  local d = ns.HistData(r)
  p.head:SetText(r.name)
  p.note:SetText(#d.pts < 2 and "History builds up from your full scans and price checks: one point each."
    or ("%d points over %.1f days; a gap = too little was seen then. Pick another flip on the Writs or Leatherworking tab."):format(
      #d.pts, (d.today - d.first) / 24))
  Draw(p, d)
  p.heads:Refresh()
  p.list:SetItems(d.rows)
end

UI.AddTab("history", Build, Refresh)
