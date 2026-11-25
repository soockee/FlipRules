-- FlipRules UI widgets, all shaped (parent, text/options, callback, opts) like Blackthornes_Farmer's:
-- Button, Tabs, Segmented, Columns + SortHeads, RowList.

local _, ns = ...
local T = ns.Theme

local W = {}
ns.Widgets = W

-- A flat button. opts: width, height, primary (gold), tip = { title, line, ... }
function W.Button(parent, text, onClick, opts)
  opts = opts or {}
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(opts.width or 100, opts.height or 22)
  b.bg = T.Fill(b, opts.primary and "accent" or "header")
  b.edge = T.Border(b, "border")
  b.label = T.Label(b, "small", opts.primary and "ink" or "text", "CENTER")
  b.label:SetPoint("CENTER")
  b.label:SetText(text)
  b.primary = opts.primary
  function b:SetLabel(t) self.label:SetText(t) end
  function b:SetActive(on) -- the lit state of a segmented choice
    self.active = on
    self.bg:SetColorTexture(T.Unpack((on or self.primary) and "accent" or "header"))
    self.label:SetTextColor(T.Unpack((on or self.primary) and "ink" or "text"))
  end
  b:SetScript("OnEnter", function(self)
    self.edge:SetColor("borderLit")
    if opts.tip then
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      for i, line in ipairs(type(opts.tip) == "function" and opts.tip() or opts.tip) do
        if i == 1 then GameTooltip:AddLine(line) else GameTooltip:AddLine(line, 1, 1, 1, true) end
      end
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function(self) self.edge:SetColor("border"); GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self) if self:IsEnabled() and onClick then onClick(self) end end)
  b:SetScript("OnDisable", function(self) self.label:SetTextColor(T.Unpack("dim")) end)
  b:SetScript("OnEnable", function(self) self:SetActive(self.active) end)
  return b
end

-- A row of tabs along the top of `parent`. tabs = { { key, text }, ... }. Returns the strip; strip:Select(key).
function W.Tabs(parent, tabs, onSelect)
  local strip = CreateFrame("Frame", nil, parent)
  strip:SetHeight(T.TAB_H)
  strip.buttons = {}
  local prev
  for _, t in ipairs(tabs) do
    local b = CreateFrame("Button", nil, strip)
    b:SetHeight(T.TAB_H)
    b.label = T.Label(b, "normal", "muted", "CENTER")
    b.label:SetPoint("CENTER")
    b.label:SetText(t[2])
    b:SetWidth(b.label:GetStringWidth() + 28)
    b.line = b:CreateTexture(nil, "OVERLAY")
    b.line:SetColorTexture(T.Unpack("accent"))
    b.line:SetPoint("BOTTOMLEFT"); b.line:SetPoint("BOTTOMRIGHT"); b.line:SetHeight(2)
    b.hover = T.Fill(b, "rowHover", 0.6)
    b.hover:Hide()
    if prev then b:SetPoint("LEFT", prev, "RIGHT", 2, 0) else b:SetPoint("LEFT") end
    b:SetScript("OnEnter", function(self) self.hover:Show() end)
    b:SetScript("OnLeave", function(self) self.hover:Hide() end)
    b:SetScript("OnClick", function() strip:Select(t[1]); onSelect(t[1]) end)
    strip.buttons[t[1]] = b
    prev = b
  end
  function strip:Select(key)
    for k, b in pairs(self.buttons) do
      b.label:SetTextColor(T.Unpack(k == key and "heading" or "muted"))
      b.line:SetShown(k == key)
    end
  end
  return strip
end

-- Buttons side by side where one is lit. choices = { { key, text, tip }, ... }; get() -> key.
function W.Segmented(parent, choices, get, onPick, width)
  local seg = CreateFrame("Frame", nil, parent)
  seg.buttons = {}
  local prev
  for _, c in ipairs(choices) do
    local b = W.Button(seg, c[2], function() onPick(c[1]) end, { width = width or 90, height = 20, tip = c[3] })
    if prev then b:SetPoint("LEFT", prev, "RIGHT", -1, 0) else b:SetPoint("LEFT") end
    seg.buttons[c[1]] = b
    prev = b
  end
  seg:SetSize(#choices * ((width or 90) - 1) + 1, 20)
  function seg:Refresh() local k = get() for key, b in pairs(self.buttons) do b:SetActive(key == k) end end
  return seg
end

-- Column layout from widths: cols = { { key, label, width, justify, sort = true }, ... } -> each gets x.
function W.Columns(cols, gap)
  local x = 0
  for _, c in ipairs(cols) do c.x = x; x = x + c.width + (gap or T.GAP) end
  cols.width = x - (gap or T.GAP)
  return cols
end

-- Clickable headings over `cols`; state() -> key, ascending; onSort(key). Returns heads:Refresh().
function W.SortHeads(parent, cols, state, onSort)
  local heads = CreateFrame("Frame", nil, parent)
  heads:SetHeight(T.HEAD_H)
  T.Fill(heads, "header")
  heads.cells = {}
  for _, c in ipairs(cols) do
    local b = CreateFrame("Button", nil, heads)
    b:SetPoint("TOPLEFT", c.x + 4, 0)
    b:SetSize(c.width, T.HEAD_H)
    b.label = T.Label(b, "small", "heading", c.justify)
    b.label:SetAllPoints()
    if c.sort then b:SetScript("OnClick", function() onSort(c.key) end) end
    if c.tip then
      b:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(c.label)
        GameTooltip:AddLine(c.tip, 1, 1, 1, true); GameTooltip:Show() end)
      b:SetScript("OnLeave", GameTooltip_Hide)
    end
    heads.cells[c.key] = b
  end
  function heads:Refresh()
    local key, asc = state()
    for _, c in ipairs(cols) do
      local arrow = c.key == key and (asc and " ^" or " v") or ""
      self.cells[c.key].label:SetText(c.label .. arrow)
    end
  end
  return heads
end

-- A list of pooled rows (only the visible ones exist) with stripes, hover and a selected row.
-- opts: rowHeight, cols, fill(row, item, cols) sets the row's cells, onClick(item), onEnter(row, item).
-- list:SetItems(items), list:SetSelected(fn(item) -> bool). Mouse wheel scrolls.
function W.RowList(parent, opts)
  local list = CreateFrame("Frame", nil, parent)
  local rh = opts.rowHeight or T.ROW_H
  list.items, list.offset, list.rows = {}, 0, {}
  T.Fill(list, "rowAlt")
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(self, d) self.offset = self.offset - d * 3; self:Render() end)
  local function Row(i)
    local r = list.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, list)
    r:SetHeight(rh)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * rh); r:SetPoint("TOPRIGHT", 0, -(i - 1) * rh)
    r.bg = T.Fill(r, i % 2 == 0 and "rowAlt" or "row")
    r.sel = T.Fill(r, "rowSel", 1, "ARTWORK"); r.sel:Hide()
    r.hover = T.Fill(r, "rowHover", 0.8, "ARTWORK"); r.hover:Hide()
    r.cells = {}
    for _, c in ipairs(opts.cols) do
      local fs = T.Label(r, "small", "text", c.justify)
      fs:SetPoint("LEFT", c.x + 4, 0); fs:SetWidth(c.width)
      r.cells[c.key] = fs
    end
    r:SetScript("OnEnter", function(self) self.hover:Show(); if opts.onEnter and self.item then opts.onEnter(self, self.item) end end)
    r:SetScript("OnLeave", function(self) self.hover:Hide(); GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self) if opts.onClick and self.item then opts.onClick(self.item) end end)
    list.rows[i] = r
    return r
  end
  -- +0.5: a height of exactly 3 rows can come back as 59.99 after UI scaling, which floored to 2
  function list:Visible() return math.max(1, math.floor(((self:GetHeight() or rh) + 0.5) / rh)) end
  function list:SetItems(items) self.items = items; self:Render() end
  function list:SetSelected(fn) self.isSelected = fn; self:Render() end
  function list:Render()
    local n = self:Visible()
    self.offset = math.max(0, math.min(self.offset, #self.items - n))
    for i = 1, math.max(n, #self.rows) do
      local item = i <= n and self.items[i + self.offset]
      if item then
        local r = Row(i)
        r.item = item
        opts.fill(r, item)
        r.sel:SetShown(self.isSelected and self.isSelected(item) or false)
        r:Show()
      elseif self.rows[i] then
        self.rows[i].item = nil
        self.rows[i]:Hide()
      end
    end
  end
  list:SetScript("OnSizeChanged", function(self) self:Render() end)
  return list
end
