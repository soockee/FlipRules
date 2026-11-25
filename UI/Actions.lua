-- The action bar under a tab's list: open a sealed writ, post, mail, delete cheap writs, reset stats;
-- and below it, while the auction house is open, the post queue (what goes up next, at which price).
-- UI.Actions(parent, kind) -> bar, queue; kind = "writs" or "lw". bar:Refresh(rule).

local _, ns = ...
local T, W, UI = ns.Theme, ns.Widgets, ns.UI

local QUEUE_ROWS = 6
local QCOLS = W.Columns({
  { key = "name", label = "Post queue", width = 300, justify = "LEFT" },
  { key = "n", label = "Qty", width = 40, justify = "RIGHT" },
  { key = "cur", label = "Cheapest now", width = 90, justify = "RIGHT", tip = "From your last check; grey = AHledger's, not checked live." },
  { key = "price", label = "You list at", width = 90, justify = "RIGHT", tip = "Cheapest listing not yours minus 1 copper, or your own price when yours is already the cheapest." },
})

-- The open button uses the item, which only a secure button may do: its item can't change in combat.
-- The name stays FlipRulesOpenButton so /click macros keep working.
local function OpenButton(parent)
  local b = CreateFrame("Button", "FlipRulesOpenButton", parent, "SecureActionButtonTemplate")
  b:SetSize(210, 22)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "item")
  T.Fill(b, "accent")
  local edge = T.Border(b, "border")
  b.label = T.Label(b, "small", "ink", "CENTER")
  b.label:SetPoint("CENTER")
  b:HookScript("OnEnter", function(self)
    edge:SetColor("borderLit")
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Open a sealed writ")
    GameTooltip:AddLine("Each click opens one; what drops is counted for the drop statistics. Works in combat, "
      .. "but the writ it opens can only change out of combat.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:HookScript("OnLeave", function() edge:SetColor("border"); GameTooltip:Hide() end)
  return b
end

function UI.Actions(parent, kind)
  local mailKind = kind == "writs" and "writs" or "LW items"
  local bar = CreateFrame("Frame", nil, parent)
  bar:SetHeight(22)
  local rule

  if kind == "writs" then
    bar.open = OpenButton(bar)
    bar.open:SetPoint("LEFT")
  end

  bar.post = W.Button(bar, "Post next", function() ns.PostNext(rule) end, { width = 150, primary = true, tip = function()
    return { "Post results on the auction house", "One click posts one auction, the highlighted row of the queue. Click again for the next.",
      "Price: the cheapest listing not yours minus 1 copper, checked live right before each post.",
      rule and rule.group == "Leatherworking" and "Duration: short (2 h). Leatherworking is undercut fast, so a short post loses less deposit."
        or "Duration: long (writs)." }
  end })

  bar.mail = W.Button(bar, "Mail", function() ns.SendBatch(mailKind) end, { width = 170, tip = function()
    local slots = ns.MailSlots(mailKind)
    local t = { ("Mail %s to %s"):format(mailKind, ns.MailTo()),
      ("One click sends one mail of up to %d stacks. %d stacks in your bags: %d mails."):format(ns.MAIL_MAX, #slots, math.ceil(#slots / ns.MAIL_MAX)),
      kind == "writs" and "Every Craftsman's Writ the rules know; sealed writs stay. The Leatherworking tab mails leatherworking items."
        or "Every leatherworking item: leather, hides, thread, salt, dyes, the stations, and what the flips craft." }
    local counts, order = {}, {}
    for _, s in ipairs(slots) do
      local info = C_Container.GetContainerItemInfo(s.bag, s.slot)
      if info then
        if not counts[info.itemID] then order[#order + 1] = info.itemID end
        counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1)
      end
    end
    for i, id in ipairs(order) do
      if i > 15 then t[#t + 1] = ("... and %d more"):format(#order - 15) break end
      t[#t + 1] = ("%s x%d"):format(ns.Name(id), counts[id])
    end
    return t
  end })

  if kind == "writs" then
    bar.del = W.Button(bar, "Delete", ns.DeleteCheap, { width = 150, tip = function()
      local t = { "Delete writs worth less than " .. ns.Money(ns.CHEAP), "One click deletes one stack, the first below. This can't be undone.",
        "Price = the cheapest listing from your own checks in the last 24 hours (not AHledger). Writs you haven't checked are kept." }
      for i, it in ipairs(ns.CheapSlots()) do
        if i > 15 then t[#t + 1] = "..." break end
        t[#t + 1] = ("%s x%d: %s (%s)"):format(it.link or it.id, it.n, ns.Money(it.price), ns.Ago(it.t))
      end
      return t
    end })
    bar.reset = W.Button(bar, "Reset stats", function() if rule then StaticPopup_Show("FLIPRULES_RESET", rule.name, nil, rule.name) end end,
      { width = 90, tip = { "Reset stats", "Clears the drop statistics of the selected writ flip." } })
  end

  -- the queue: a heading row and the rows, hidden while the AH is closed or nothing is in your bags
  local queue = CreateFrame("Frame", nil, parent)
  queue:SetWidth(QCOLS.width + 8)
  queue:SetHeight(T.HEAD_H + QUEUE_ROWS * T.ROW_H)
  local heads = W.SortHeads(queue, QCOLS, function() return nil end, function() end)
  heads:SetPoint("TOPLEFT"); heads:SetPoint("TOPRIGHT")
  heads:Refresh()
  local list = W.RowList(queue, {
    cols = QCOLS,
    fill = function(row, it)
      local live = ns.Live(it.id)
      row.cells.name:SetText(ns.Link(it.id))
      row.cells.n:SetText(it.n)
      row.cells.cur:SetText(live and (live.min and ns.Money(live.min) or "none") or (T.Hex("dim") .. (it.cur and ns.Money(it.cur) or "?") .. "|r"))
      row.cells.price:SetText(it.price and ns.Money(it.price) or (T.Hex("dim") .. "no price|r"))
    end,
    onEnter = function(row, it)
      GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
      GameTooltip:SetItemByID(it.id)
      GameTooltip:AddDoubleLine("You list at", it.price and ns.Money(it.price) or "not posted (no price)", 0.2, 1, 0.6, 1, 1, 1)
      GameTooltip:Show()
    end,
  })
  list:SetPoint("TOPLEFT", heads, "BOTTOMLEFT")
  list:SetPoint("BOTTOMRIGHT")

  function bar:Refresh(r)
    rule = r
    local ah, mail = ns.AHOpen(), ns.MailOpen()
    if self.open then
      local has = r and r.use
      if has then self.open.label:SetText(("Open %s (%d)"):format(ns.Name(r.use), ns.BagCounts()[r.use] or 0)) end
      if not InCombatLockdown() then -- secure attributes wait for PLAYER_REGEN_ENABLED
        self.open:SetAttribute("item", has and ("item:" .. r.use) or nil)
        self.open:SetShown(has and true or false)
      end
    end
    local st = ns.PostState(ah and r or nil)
    self.post:SetShown(ah)
    self.post:SetEnabled(st.items > 0 and not st.busy and (st.fresh or not ns.Searching()))
    self.post:SetLabel(st.items == 0 and "Nothing to post" or st.fresh and ("Post next (%d left)"):format(st.items)
      or ns.Searching() and "Checking price..." or "Check price")
    local stacks = mail and #ns.MailSlots(mailKind) or 0
    self.mail:SetShown(mail)
    self.mail:SetEnabled(stacks > 0 and not ns.Mailing())
    self.mail:SetLabel(ns.Mailing() and "Sending..." or stacks > 0 and ("Mail %s (%d)"):format(mailKind, stacks) or ("No %s to mail"):format(mailKind))
    if self.del then
      local cheap = #ns.CheapSlots()
      self.del:SetShown(cheap > 0)
      self.del:SetLabel(("Delete writs <%s (%d)"):format(ns.Money(ns.CHEAP), cheap))
    end
    if self.reset then self.reset:SetShown(r and r.use and true or false) end
    -- the other buttons follow the open button left to right; it never moves (it's secure)
    local prev = self.open
    for _, b in ipairs({ self.post, self.mail, self.del, self.reset }) do
      if b and b:IsShown() then
        b:ClearAllPoints()
        if prev then b:SetPoint("LEFT", prev, "RIGHT", T.GAP, 0) else b:SetPoint("LEFT") end
        prev = b
      end
    end
    local on = ah and #st.queue > 0
    queue:SetShown(on)
    queue:SetHeight(on and T.HEAD_H + QUEUE_ROWS * T.ROW_H or 1) -- on the Leatherworking tab the list takes the room
    list:SetItems(st.queue)
    list:SetSelected(function(it) return it == st.head end)
  end

  return bar, queue
end
