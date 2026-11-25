--[[ Leatherworking: what the game can't tell FlipRules about the crafts.
  The recipes themselves (reagents, products, how many each makes) come from your crafter's
  Leatherworking window: open it once and every learned recipe becomes a craft flip.
  Here: which Craftsman's Writ asks for which product (writ link: tier, writ, the camp station
  that tier needs), the stations' own recipes, and reagents always bought at a vendor.
  Writ links from LibForeverData quest objectives, vendor prices from CraftersJournal (2026-11).
  Stations per tier: Journeyman = Camp Tent, Expert = Tanning Rack, Artisan = Sewing Machine.
]]

local R = FlipRules

-- station item -> reagents of its own recipe (nil: no recipe known, AH price only)
R.Station(279978, { [2318] = 5 })                           -- Camp Tent
R.Station(279941, { [2319] = 5, [2321] = 3, [4470] = 2 })   -- Tanning Rack
R.Station(279945, nil)                                      -- Sewing Machine

-- product, writ tier, writ, station
R.WritLink(18662, "Journeyman", 264038, 279978) -- Heavy Leather Ball
R.WritLink(5958, "Journeyman", 264039, 279978) -- Fine Leather Pants
R.WritLink(7349, "Journeyman", 264040, 279978) -- Herbalist's Gloves
R.WritLink(2317, "Journeyman", 264041, 279978) -- Dark Leather Tunic
R.WritLink(7358, "Journeyman", 264042, 279978) -- Pilferer's Gloves
R.WritLink(7371, "Journeyman", 264043, 279978) -- Heavy Quiver
R.WritLink(4252, "Journeyman", 264044, 279978) -- Dark Leather Shoulders
R.WritLink(4254, "Journeyman", 264045, 279978) -- Barbaric Gloves
R.WritLink(7284, "Journeyman", 264046, 279978) -- Red Whelp Gloves
R.WritLink(8174, "Expert", 264092, 279941) -- Comfortable Leather Hat
R.WritLink(5965, "Expert", 264093, 279941) -- Guardian Cloak
R.WritLink(7378, "Expert", 264094, 279941) -- Dusky Bracers
R.WritLink(8214, "Expert", 264095, 279941) -- Wild Leather Helmet
R.WritLink(8210, "Expert", 264096, 279941) -- Wild Leather Shoulders
R.WritLink(8217, "Expert", 264097, 279941) -- Quickdraw Quiver
R.WritLink(7391, "Expert", 264098, 279941) -- Swift Boots
R.WritLink(8192, "Expert", 264099, 279941) -- Nightscape Shoulders
R.WritLink(8201, "Expert", 264100, 279941) -- Big Voodoo Mask
R.WritLink(8200, "Expert", 264101, 279941) -- Big Voodoo Robe
R.WritLink(8189, "Expert", 264102, 279941) -- Turtle Scale Breastplate
R.WritLink(8218, "Expert", 264103, 279941) -- Thick Leather Ammo Pouch
R.WritLink(15087, "Artisan", 264143, 279945) -- Wicked Leather Pants
R.WritLink(18258, "Artisan", 264144, 279945) -- Gordok Ogre Suit
R.WritLink(15053, "Artisan", 264145, 279945) -- Volcanic Breastplate
R.WritLink(15094, "Artisan", 264146, 279945) -- Runic Leather Headband
R.WritLink(15084, "Artisan", 264147, 279945) -- Wicked Leather Bracers
R.WritLink(15075, "Artisan", 264148, 279945) -- Chimeric Vest
R.WritLink(15080, "Artisan", 264149, 279945) -- Heavy Scorpid Helm
R.WritLink(15092, "Artisan", 264150, 279945) -- Runic Leather Bracers
R.WritLink(15071, "Artisan", 264151, 279945) -- Frostsaber Boots

-- Vendor reagents (copper each): always priced at the vendor, a stable price, not the AH.
-- Fine/Silken/Heavy Silken/Rune Thread, Black/Gray Dye, Salt, Simple Wood.
R.Vendor{ [2321] = 100, [2325] = 1000, [4289] = 50, [4291] = 500, [4340] = 350, [4470] = 38, [8343] = 2000, [14341] = 5000 }
