-- Settings tab: every setting FlipRules has, in one place.

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local function Section(p, y, title, note)
  local h = T.Label(p, "normal", "heading")
  h:SetPoint("TOPLEFT", 0, y)
  h:SetText(title)
  if note then
    local n = T.Label(p, "small", "muted")
    n:SetPoint("TOPLEFT", 0, y - 18); n:SetWidth(620)
    n:SetWordWrap(true)
    n:SetText(note)
  end
end

local function Build(p)
  Section(p, 0, "Value results at", "What a flip's results are worth in the list and the details. The verdict always uses Safe.")
  local keys = {}
  for _, k in ipairs({ "now", "7d", "safe" }) do
    local help = ns.BASIS_HELP[k]
    keys[#keys + 1] = { k, help[1], { help[1], help[2] } }
  end
  p.basis = W.Segmented(p, keys, function() return ns.Basis() end, function(k) FlipRulesDB.basis = k; ns.RefreshAll() end, 90)
  p.basis:SetPoint("TOPLEFT", 0, -40)

  Section(p, -80, "Mail between", "Your characters, comma separated. The Send Mail form fills in the other one and a subject.")
  p.mail = W.Input(p, { width = 300 }, function(text) FlipRulesDB.mailChars = text end)
  p.mail:SetPoint("TOPLEFT", 0, -120)

  Section(p, -160, "Writ crafts", "A writ craft needs a camp station, which is used up when placed; its cost is spread over this many crafts.")
  local label = T.Label(p, "small", "text")
  label:SetPoint("TOPLEFT", 0, -202)
  label:SetText("Crafts per station")
  p.per = W.Input(p, { width = 60, numeric = true }, function(text)
    FlipRulesDB.craftsPerStation = math.max(1, tonumber(text) or 10)
    ns.RefreshAll()
  end)
  p.per:SetPoint("LEFT", label, "RIGHT", 10, 0)
  p.shop = W.Check(p, "Put the station on the Auctionator shopping list too", function() return FlipRulesDB.shopStation end,
    function(v) FlipRulesDB.shopStation = v and true or false end)
  p.shop:SetPoint("TOPLEFT", 0, -230)

  Section(p, -270, "Window")
  p.withAH = W.Check(p, "Open and close FlipRules with the auction house", function() return FlipRulesDB.withAH end,
    function(v) FlipRulesDB.withAH = v and true or false end)
  p.withAH:SetPoint("TOPLEFT", 0, -292)

  Section(p, -330, "Scanning")
  p.scan = T.Label(p, "small", "text")
  p.scan:SetPoint("TOPLEFT", 0, -352); p.scan:SetWidth(620)
  p.scan:SetWordWrap(true)
  local why = T.Label(p, "small", "muted")
  why:SetPoint("TOPLEFT", 0, -372); why:SetWidth(620)
  why:SetWordWrap(true)
  why:SetText("FlipRules scans the whole auction house when you open it, at most every 15 minutes. AHledger's own "
    .. "auto-scan has to be off for that (/ahl auto off); its downloaded price file is still read for sold per day.")
end

local function Refresh(p)
  p.basis:Refresh()
  if not p.mail:HasFocus() then p.mail:SetText(FlipRulesDB.mailChars or ns.MAIL_CHARS) end
  if not p.per:HasFocus() then p.per:SetText(tostring(FlipRulesDB.craftsPerStation or 10)) end
  p.shop:Refresh()
  p.withAH:Refresh()
  p.scan:SetText(ns.ScanStatus())
end

UI.AddTab("settings", Build, Refresh)
