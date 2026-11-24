--[[ Leatherworking: the items the Craftsman's Writs ask for, as craft rules.
  Production cost = the recipe's reagents (vendor price if a vendor sells it, else the cheaper of
  buying on the AH and crafting it yourself, see the chains below) plus a share of the camp
  station for that writ tier (placing one uses it up), spread over your "crafts per station".
  Writ -> item from LibForeverData quest objectives; recipes from CraftersJournal's data (2026-11).
  Stations per tier: Journeyman = Camp Tent, Expert = Tanning Rack, Artisan = Sewing Machine.
]]

local R = FlipRules

-- station item -> reagents of its own recipe (nil: no recipe known, AH price only)
R.Station(279978, { [2318] = 5 })                           -- Camp Tent
R.Station(279941, { [2319] = 5, [2321] = 3, [4470] = 2 })   -- Tanning Rack
R.Station(279945, nil)                                      -- Sewing Machine

local function L(t)
  local name, item, qty, tier, writ, station, reagents, spec = unpack(t)
  R.Add{
    name = ("[%s] %s"):format(tier, name),
    group = "Leatherworking", tier = tier, writ = writ, station = station, spec = spec,
    inputs = reagents, outputs = { [item] = qty },
  }
end

-- { item name, item, made per craft, writ tier, writ, station, reagents, specialization (nil: basic) }
L{ "Heavy Leather Ball", 18662, 1, "Journeyman", 264038, 279978, { [4234] = 2, [2321] = 1 } }
L{ "Fine Leather Pants", 5958, 1, "Journeyman", 264039, 279978, { [2319] = 8, [2997] = 1, [2321] = 1 } }
L{ "Herbalist's Gloves", 7349, 1, "Journeyman", 264040, 279978, { [2319] = 8, [3356] = 4, [2321] = 2 } }
L{ "Dark Leather Tunic", 2317, 1, "Journeyman", 264041, 279978, { [2319] = 6, [2321] = 1, [4340] = 1 } }
L{ "Pilferer's Gloves", 7358, 1, "Journeyman", 264042, 279978, { [2319] = 10, [5373] = 2, [2321] = 2 } }
L{ "Heavy Quiver", 7371, 1, "Journeyman", 264043, 279978, { [4234] = 8, [2321] = 2 } }
L{ "Dark Leather Shoulders", 4252, 1, "Journeyman", 264044, 279978, { [2319] = 12, [3390] = 1, [4340] = 1, [2321] = 2 } }
L{ "Barbaric Gloves", 4254, 1, "Journeyman", 264045, 279978, { [4234] = 6, [5637] = 2, [2321] = 1 } }
L{ "Red Whelp Gloves", 7284, 1, "Journeyman", 264046, 279978, { [7287] = 6, [2319] = 4, [2321] = 1 } }
L{ "Comfortable Leather Hat", 8174, 1, "Expert", 264092, 279941, { [4234] = 12, [4236] = 2, [4291] = 2 } }
L{ "Guardian Cloak", 5965, 1, "Expert", 264093, 279941, { [4234] = 14, [4305] = 2, [4291] = 2 } }
L{ "Dusky Bracers", 7378, 1, "Expert", 264094, 279941, { [4234] = 16, [2325] = 1, [4291] = 2 } }
L{ "Wild Leather Helmet", 8214, 1, "Expert", 264095, 279941, { [4304] = 10, [8153] = 2, [8172] = 1 } }
L{ "Wild Leather Shoulders", 8210, 1, "Expert", 264096, 279941, { [4304] = 10, [8153] = 1, [8172] = 1 } }
L{ "Quickdraw Quiver", 8217, 1, "Expert", 264097, 279941, { [4304] = 12, [8172] = 1, [8949] = 1, [4291] = 4 } }
L{ "Swift Boots", 7391, 1, "Expert", 264098, 279941, { [4234] = 10, [2459] = 2, [4337] = 2, [4291] = 1 } }
L{ "Nightscape Shoulders", 8192, 1, "Expert", 264099, 279941, { [4304] = 8, [4338] = 6, [4291] = 3 } }
L{ "Big Voodoo Mask", 8201, 1, "Expert", 264100, 279941, { [4304] = 8, [8151] = 6, [8343] = 1 } }
L{ "Big Voodoo Robe", 8200, 1, "Expert", 264101, 279941, { [4304] = 10, [8151] = 4, [8343] = 1 } }
L{ "Turtle Scale Breastplate", 8189, 1, "Expert", 264102, 279941, { [4304] = 6, [8167] = 12, [8343] = 1 } }
L{ "Thick Leather Ammo Pouch", 8218, 1, "Expert", 264103, 279941, { [4304] = 10, [8172] = 1, [8951] = 1, [4291] = 6 } }
L{ "Wicked Leather Pants", 15087, 1, "Artisan", 264143, 279945, { [8170] = 16, [15407] = 1, [2325] = 3, [14341] = 1 } }
L{ "Gordok Ogre Suit", 18258, 1, "Artisan", 264144, 279945, { [8170] = 4, [14048] = 2, [18240] = 1, [14341] = 1 } }
L{ "Volcanic Breastplate", 15053, 1, "Artisan", 264145, 279945, { [8170] = 8, [7078] = 1, [7076] = 1, [14341] = 1 }, "Elemental" }
L{ "Runic Leather Headband", 15094, 1, "Artisan", 264146, 279945, { [8170] = 14, [14047] = 10, [14341] = 1 } }
L{ "Wicked Leather Bracers", 15084, 1, "Artisan", 264147, 279945, { [8170] = 8, [2325] = 1, [14341] = 1 } }
L{ "Chimeric Vest", 15075, 1, "Artisan", 264148, 279945, { [8170] = 10, [15423] = 10, [14341] = 1 }, "Tribal" }
L{ "Heavy Scorpid Helm", 15080, 1, "Artisan", 264149, 279945, { [8170] = 8, [15408] = 12, [15407] = 1, [14341] = 1 } }
L{ "Runic Leather Bracers", 15092, 1, "Artisan", 264150, 279945, { [8170] = 6, [7971] = 1, [14047] = 6, [14341] = 1 } }
L{ "Frostsaber Boots", 15071, 1, "Artisan", 264151, 279945, { [8170] = 4, [15422] = 6, [14341] = 1 }, "Tribal" }

-- Intermediate recipes you can make yourself (Leatherworking, no specialization), so a reagent
-- costs the cheaper of buying it and crafting it: item, made per craft, reagents.
R.Recipe(2318, 1, { [2934] = 3 })                 -- Light Leather
R.Recipe(2319, 1, { [2318] = 4 })                 -- Medium Leather
R.Recipe(4234, 1, { [2319] = 5 })                 -- Heavy Leather
R.Recipe(4236, 1, { [4235] = 1, [4289] = 3 })     -- Cured Heavy Hide
R.Recipe(4304, 1, { [4234] = 6 })                 -- Thick Leather
R.Recipe(8170, 1, { [4304] = 6 })                 -- Rugged Leather
R.Recipe(8172, 1, { [8169] = 1, [8150] = 1 })     -- Cured Thick Hide
R.Recipe(15407, 2, { [8171] = 1, [15409] = 1 })   -- Cured Rugged Hide

-- Vendor reagents (copper each, CraftersJournal's vendor data): always priced at the vendor,
-- a stable price, not the AH. Fine/Silken/Heavy Silken/Rune Thread, Black/Gray Dye, Salt, Simple Wood.
R.Vendor{ [2321] = 100, [2325] = 1000, [4289] = 50, [4291] = 500, [4340] = 350, [4470] = 38, [8343] = 2000, [14341] = 5000 }
