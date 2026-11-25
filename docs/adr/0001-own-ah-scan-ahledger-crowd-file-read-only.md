# FlipRules scans the auction house itself; AHledger's crowd file is read-only

FlipRules needs current prices and listed counts for every item it knows, and how fast each item sells. It used to search the AH one item at a time and lean on AHledger's own full scans.

We decided FlipRules runs its own full scan when the AH opens (at most once per 15 minutes, the server's limit), plus a few item-class queries for "Check all" and a single-item search right before each post. From AHledger it only reads the downloaded crowd price file (median, sold per day), and only if AHledger is installed; nothing is sent anywhere. Sold per day prefers that crowd figure and falls back to FlipRules' own estimate from listings that vanish between its scans.

## Considered options

- **Read AHledger's own scans**: no second scanner, but it ties FlipRules to AHledger's scanning and its upload setting, which the user doesn't want.
- **Crowd file never read**: fully standalone, but sold per day from one player's scans is far weaker than about 480 players' scans.

## Consequences

- The server allows one full scan per 15 minutes per player, so AHledger's auto-scan has to be off (`/ahl auto off`). While it is on, FlipRules skips its own full scan and says why.
- Without AHledger, everything still works; sold per day is the own estimate, which reads high (cancelled and expired auctions count as sold) and needs scans a few hours apart.
