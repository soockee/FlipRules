--[[ FlipRules rules. One rule = one repeatable action you can profit from.

  FlipRules.Add{
    name    = "shown in the list",
    inputs  = { [itemID] = qty, ... },     -- what you buy (min AH buyout, or vendor price if known)
    outputs = { [itemID] = qty, ... },     -- fixed results you sell (AH median, minus 5% cut)
    pool    = { itemID, ... },             -- optional: exactly ONE of these drops per run
    poolQty = 1,                           -- optional: how many of the pool item drop
    use     = itemID,                      -- optional: the Open button uses this item;
                                           -- whatever lands in your bags is recorded as a drop
    category = { [itemID] = "label" },     -- optional: grouping in the stats; R.Categories builds it
    price   = { [itemID] = copper },       -- optional: fixed price override (vendor items etc.)
  }

  Pool odds are uniform until you have opened MIN_OBSERVED (30) yourself; then your own counts are used.
  Profession recipes don't need rules: open the profession window and they are scanned automatically.
]]

local R = FlipRules

-- Sealed X's Writ -> one X-tier Craftsman's Writ. Tiers read from Wowhead tooltips (2026-11): the
-- writ IDs come in one block per tier, split into equal blocks per profession in this order.

-- Journeyman: 264011-264055, 9 per profession.
R.Add{
  name = "Sealed Journeyman's Writ -> sell writ",
  inputs = { [262888] = 1 },
  pool = R.Range(264011, 264055),
  use = 262888,
  category = R.Categories{
    Alchemy = { 264011, 264019 },
    Blacksmithing = { 264020, 264028 },
    Engineering = { 264029, 264037 },
    Leatherworking = { 264038, 264046 },
    Tailoring = { 264047, 264055 },
  },
}

-- Expert: 264056-264115, 12 per profession.
R.Add{
  name = "Sealed Expert's Writ -> sell writ",
  inputs = { [262889] = 1 },
  pool = R.Range(264056, 264115),
  use = 262889,
  category = R.Categories{
    Alchemy = { 264056, 264067 },
    Blacksmithing = { 264068, 264079 },
    Engineering = { 264080, 264091 },
    Leatherworking = { 264092, 264103 },
    Tailoring = { 264104, 264115 },
  },
}

-- Artisan: 264116-264160, 9 per profession. 264134 (Masterwork Target Dummy) is in it too: it
-- drops from the sealed writ and its quest matches the others (level 60, same giver).
R.Add{
  name = "Sealed Artisan's Writ -> sell writ",
  inputs = { [262890] = 1 },
  pool = R.Range(264116, 264160),
  use = 262890,
  category = R.Categories{ -- the writ IDs come in blocks of 9 per profession
    Alchemy = { 264116, 264124 },
    Blacksmithing = { 264125, 264133 },
    Engineering = { 264134, 264142 },
    Leatherworking = { 264143, 264151 },
    Tailoring = { 264152, 264160 },
  },
}
