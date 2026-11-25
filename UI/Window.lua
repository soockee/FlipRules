-- FlipRules main window: a title band, a tab strip, and one pane per tab. Each tab file registers
-- itself with ns.UI.AddTab(key, build, refresh); the window builds a pane the first time it shows.

local _, ns = ...
local T, W = ns.Theme, ns.Widgets

local UI = { panes = {}, builders = {}, refreshers = {} }
ns.UI = UI

local TABS = {
  { "writs", "Writs" }, { "lw", "Leatherworking" }, { "market", "Market" },
  { "history", "History" }, { "settings", "Settings" },
}
local WIDTH, HEIGHT = 1220, 600

function UI.AddTab(key, build, refresh) UI.builders[key], UI.refreshers[key] = build, refresh end

local function DB()
  FlipRulesDB.ui = FlipRulesDB.ui or {}
  return FlipRulesDB.ui
end
UI.DB = DB

local win -- built on first open

local function Pane(key)
  if UI.panes[key] then return UI.panes[key] end
  local p = CreateFrame("Frame", nil, win.body)
  p:SetAllPoints()
  if UI.builders[key] then
    UI.builders[key](p)
  else -- not built yet: say where the feature still lives
    local fs = T.Label(p, "normal", "muted", "CENTER")
    fs:SetPoint("CENTER")
    fs:SetText("Not moved here yet: it's still in the old window (/flip).")
  end
  UI.panes[key] = p
  return p
end

function UI.Show(key)
  DB().tab = key
  for k, p in pairs(UI.panes) do p:SetShown(k == key) end
  Pane(key):Show()
  win.tabs:Select(key)
  UI.Refresh()
end

-- Redraws the visible tab; Core's RefreshAll calls this after every data change.
function UI.Refresh()
  if not (win and win:IsShown()) then return end
  local key = DB().tab or "lw"
  if UI.refreshers[key] and UI.panes[key] then UI.refreshers[key](UI.panes[key]) end
  win.foot:SetText(ns.ScanStatus and ns.ScanStatus() or "")
end
ns.RefreshUI = UI.Refresh

local function Build()
  win = CreateFrame("Frame", "FlipRulesMain", UIParent)
  win:SetSize(WIDTH, HEIGHT)
  win:SetFrameStrata("HIGH")
  win:SetToplevel(true)
  win:SetClampedToScreen(true)
  T.Fill(win, "window")
  T.Border(win, "border")
  local pos = DB().pos
  if pos then win:SetPoint(pos[1], UIParent, pos[1], pos[2], pos[3]) else win:SetPoint("CENTER") end
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, _, x, y = self:GetPoint()
    DB().pos = { p, x, y }
  end)
  tinsert(UISpecialFrames, "FlipRulesMain") -- Escape closes it

  local title = CreateFrame("Frame", nil, win)
  title:SetPoint("TOPLEFT", 1, -1); title:SetPoint("TOPRIGHT", -1, -1); title:SetHeight(30)
  T.Fill(title, "header")
  local name = T.Label(title, "title", "heading")
  name:SetPoint("LEFT", T.PAD, 0)
  name:SetText("FlipRules")
  local close = W.Button(title, "x", function() win:Hide() end, { width = 22, height = 20 })
  close:SetPoint("RIGHT", -6, 0)

  win.tabs = W.Tabs(win, TABS, UI.Show)
  win.tabs:SetPoint("TOPLEFT", T.PAD, -34)
  win.tabs:SetPoint("TOPRIGHT", -T.PAD, -34)
  local rule = win:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(T.Unpack("border"))
  rule:SetPoint("TOPLEFT", T.PAD, -34 - T.TAB_H); rule:SetPoint("TOPRIGHT", -T.PAD, -34 - T.TAB_H); rule:SetHeight(1)

  win.body = CreateFrame("Frame", nil, win)
  win.body:SetPoint("TOPLEFT", T.PAD, -34 - T.TAB_H - T.GAP)
  win.body:SetPoint("BOTTOMRIGHT", -T.PAD, 26)

  win.foot = T.Label(win, "tiny", "dim")
  win.foot:SetPoint("BOTTOMLEFT", T.PAD, 9)
  win.foot:SetPoint("BOTTOMRIGHT", -T.PAD, 9)

  win:SetScript("OnShow", function() UI.Show(DB().tab or "lw") end)
  win:Hide()
end

function ns.ToggleUI(show)
  if not win then Build() end
  if show == nil then show = not win:IsShown() end
  win:SetShown(show)
end
