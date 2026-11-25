-- FlipRules UI: one palette, one font ladder, flat panels and 1px borders drawn from plain
-- textures (the pattern Blackthornes_Farmer uses), so every pane looks the same.

local _, ns = ...

local T = {}
ns.Theme = T

T.colors = {
  window   = { 0.067, 0.055, 0.039 }, -- the outer shell
  panel    = { 0.102, 0.086, 0.067 },
  header   = { 0.129, 0.106, 0.075 }, -- title band, column headings
  row      = { 0.090, 0.075, 0.055 },
  rowAlt   = { 0.059, 0.047, 0.031 },
  rowHover = { 0.141, 0.118, 0.082 },
  rowSel   = { 0.200, 0.165, 0.094 },
  border   = { 0.290, 0.235, 0.141 },
  borderLit = { 0.420, 0.353, 0.227 },
  accent   = { 0.784, 0.643, 0.302 }, -- gold: active tab, primary button
  ink      = { 0.110, 0.078, 0.024 }, -- dark text on gold
  heading  = { 1.000, 0.820, 0.000 },
  text     = { 1.000, 1.000, 1.000 },
  muted    = { 0.608, 0.573, 0.486 },
  dim      = { 0.478, 0.443, 0.369 },
  good     = { 0.310, 0.820, 0.545 },
  warn     = { 0.910, 0.757, 0.353 },
  loss     = { 0.898, 0.376, 0.310 },
}

T.FONT = (GameFontNormal and GameFontNormal:GetFont()) or [[Fonts\FRIZQT__.TTF]]
T.sizes = { tiny = 10, small = 11, normal = 12, large = 14, title = 16 }

-- spacing used everywhere, so panes line up
T.PAD, T.GAP, T.ROW_H, T.HEAD_H, T.TAB_H = 12, 6, 20, 20, 26

function T.Unpack(key, alpha)
  local c = T.colors[key] or T.colors.text
  return c[1], c[2], c[3], alpha or 1
end

-- "|cffRRGGBB" for a palette colour, for text built with string.format
function T.Hex(key)
  local r, g, b = T.Unpack(key)
  return ("|cff%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

function T.Fill(frame, key, alpha, layer)
  local t = frame:CreateTexture(nil, layer or "BACKGROUND")
  t:SetAllPoints(frame)
  t:SetColorTexture(T.Unpack(key, alpha))
  return t
end

-- a 1px border as four edge textures: crisp at any size, no BackdropTemplate needed
function T.Border(frame, key, alpha)
  local edges = {}
  for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local e = frame:CreateTexture(nil, "BORDER")
    e:SetColorTexture(T.Unpack(key or "border", alpha))
    if side == "TOP" or side == "BOTTOM" then
      e:SetPoint(side .. "LEFT"); e:SetPoint(side .. "RIGHT"); e:SetHeight(1)
    else
      e:SetPoint("TOP" .. side); e:SetPoint("BOTTOM" .. side); e:SetWidth(1)
    end
    edges[#edges + 1] = e
  end
  function edges.SetColor(_, k, a) for _, e in ipairs(edges) do e:SetColorTexture(T.Unpack(k, a)) end end
  return edges
end

function T.Panel(parent, bg, border)
  local f = CreateFrame("Frame", nil, parent)
  T.Fill(f, bg or "panel")
  T.Border(f, border or "border")
  return f
end

function T.Label(parent, size, color, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(T.FONT, T.sizes[size or "normal"] or 12, "")
  fs:SetTextColor(T.Unpack(color or "text"))
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end
