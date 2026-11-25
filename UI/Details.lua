-- The details pane next to a tab's list: the selected flip's verdict and why, its key numbers,
-- the checks behind the verdict, and the long text (breakdown, chains, your record, drop stats).

local _, ns = ...
local T, UI = ns.Theme, ns.UI

local NUMS = 6 -- label/value pairs, two columns

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

  d.nums = {}
  for i = 1, NUMS do
    local col, rowN = (i - 1) % 2, math.floor((i - 1) / 2)
    local y = -54 - rowN * 16
    local label = T.Label(d, "small", "muted")
    label:SetPoint("TOPLEFT", T.PAD + col * 250, y)
    local value = T.Label(d, "small", "text", "RIGHT")
    value:SetPoint("TOPLEFT", T.PAD + col * 250 + 110, y)
    value:SetWidth(120)
    d.nums[i] = { label = label, value = value }
  end

  d.checkHead = T.Label(d, "small", "heading")
  d.checkHead:SetPoint("TOPLEFT", T.PAD, -112)
  d.checkHead:SetText("Checks")
  d.checks = {}
  for i = 1, 5 do
    local fs = T.Label(d, "small", "text")
    fs:SetPoint("TOPLEFT", T.PAD, -112 - i * 15)
    fs:SetPoint("RIGHT", d, "RIGHT", -T.PAD, 0)
    d.checks[i] = fs
  end

  local line = d:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(T.Unpack("border"))
  line:SetPoint("TOPLEFT", T.PAD, -202); line:SetPoint("TOPRIGHT", -T.PAD, -202); line:SetHeight(1)

  -- the long text scrolls with the mouse wheel
  local scroll = CreateFrame("ScrollFrame", nil, d)
  scroll:SetPoint("TOPLEFT", T.PAD, -208)
  scroll:SetPoint("BOTTOMRIGHT", -T.PAD, T.PAD)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1, 1)
  scroll:SetScrollChild(child)
  local body = T.Label(child, "small", "text")
  body:SetPoint("TOPLEFT")
  body:SetWordWrap(true)
  body:SetJustifyV("TOP")
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, child:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 40)))
  end)
  scroll:SetScript("OnSizeChanged", function(self, w) body:SetWidth(w); child:SetWidth(w) end)

  local empty = T.Label(d, "normal", "muted", "CENTER")
  empty:SetPoint("CENTER")
  empty:SetText("Select a flip in the list.")

  function d:SetRule(r)
    local shown = r ~= nil
    for _, x in ipairs({ self.verdict, self.name, self.why, self.checkHead, line, scroll }) do x:SetShown(shown) end
    for _, n in ipairs(self.nums) do n.label:SetShown(shown); n.value:SetShown(shown) end
    for _, c in ipairs(self.checks) do c:SetShown(shown) end
    empty:SetShown(not shown)
    if not r then return end
    local e = ns.Evaluated(r)
    local v, col, why = ns.Verdict(e)
    self.verdict:SetText(col .. v .. "|r")
    self.name:SetText(r.name)
    self.why:SetText(table.concat(why, "; "))
    local M = ns.Money
    local pairs6 = {
      { "Cost", M(e.cost) }, { "Sells for (after cut)", M(e.value) },
      { "Profit", M(e.profit) }, { "At cautious prices", M(e.safe) },
      { "Week low .. high", ("%s .. %s"):format(M(e.worst), M(e.best)) },
      r.use and { "Break-even buy", M(e.maxBuy) } or { "Profit a day", M(e.profitDay) },
    }
    for i, n in ipairs(self.nums) do n.label:SetText(pairs6[i][1]); n.value:SetText(pairs6[i][2]) end
    local checks = ns.Checks(e)
    for i, c in ipairs(self.checks) do
      local ch = checks[i]
      c:SetText(ch and ((ch[1] and T.Hex("good") .. "+|r  " or T.Hex("loss") .. "x|r  ") .. ch[2]) or "")
    end
    if self.rule ~= r then scroll:SetVerticalScroll(0) end
    self.rule = r
    body:SetText(ns.StatsText(r))
    child:SetHeight(body:GetStringHeight() + 10)
  end
  d:SetRule(nil)
  return d
end
