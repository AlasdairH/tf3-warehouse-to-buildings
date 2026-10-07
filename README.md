# Warehouse Distribution (TF3)

A Transport Fever 3 script mod: your warehouses hand their cargo to the industries and town buildings around them that take it. A warehouse becomes a buffer: a train or truck fills it, and it keeps the buildings in reach supplied.

In the base game a warehouse is only storage for vehicles. The game manual says: *"Town buildings and factories do not have access to the warehouse's content. They rely on you to transport their cargo from or to them."* This mod gives them that access.

> **Status: untested in the game.** Everything below is built against the official script API documentation and tested offline against a mock of the engine (43 tests, Lua 5.1, 5.2 and LuaJIT). The mod moves cargo with a command the game files under `debug`, and nobody has confirmed yet that the command works in a normal game. Do the [first test in the game](#first-test-in-the-game) on a new game or a copy of a save before you rely on it.

## What it does

- Every quarter of an in-game day, each of your warehouses looks at the buildings in its reach:
  - industries and town buildings within a radius of the warehouse (default 200 m, measured from its edge to theirs),
  - and, if the option is on, every building in the catchment area of a station whose catchment area holds the warehouse. Those are the buildings the station's own vehicles could deliver to. Select the station to see them highlighted.
- A building takes cargo if one of its **input stocks** takes a cargo type the warehouse holds and isn't full. Output stocks and residential buildings get nothing.
- Cargo goes to the **emptiest** input stock first, one item at a time, so a small amount is shared fairly instead of going to whichever building comes first.
- A warehouse hands out at most a set number of items per month (default 100). If it's idle, unused allowance builds up only to a quarter of a month's worth.
- Only your own warehouses take part. With the option set, only warehouses with **[D]** in their name do. Rename one in its window. Use this to stop transfer hubs from handing out cargo meant for somewhere else.

### Payment

The base game pays for cargo only when a vehicle drops it at its final destination. Cargo handed out by a warehouse never gets there on a vehicle, so the game would never pay for it, and the line that filled the warehouse would earn nothing.

The mod pays it instead, like a delivery **from where the cargo was produced to the building that took it**:

- **Price per metre:** learned for each cargo type from the game's own deliveries. Every time one of your vehicles delivers cargo, the game reports the base price and the mod divides it by the delivery's distance. The price therefore follows the game's era, difficulty and cargo prices without the mod knowing the formula.
  - If a cargo type hasn't been delivered by a vehicle yet, the average of the known prices is used.
  - If no price is known at all yet, the distance is kept and paid as soon as one is.
- **Distance:** horizontal distance plus eight times any climb, as the game's manual describes for cargo income.
- **Where it shows up:** the money is booked once per warehouse and day, shown above the warehouse. It counts as transport income of the line and vehicle that brought the cargo to the warehouse, so it appears in the finance window and in the line and vehicle statistics.
- **Share:** the option pays 100% (default), 50% or nothing.
- **Infinite money:** nothing is booked.

This works alongside [Paid Warehouse Deliveries](https://github.com/GlcrTE/TF3-Paid-Warehouse-Deliveries). That mod pays a handling fee when cargo goes *into* a warehouse; this one pays the delivery when it comes *out*.

## How it works

The script API has no command that moves a cargo item. The only command that changes what a stock holds is

```lua
api.cmd.debug.makeStockSetCargoAmountCmd(stockList, stockId, amount, cargoType)
```

It sets how many items of a cargo type a stock holds. So a hand-out is two commands: the warehouse stock is set to *n − k* and the building's input stock to *m + k*.

The command lives under `debug`, so the mod treats every use as an experiment:

1. Commands sent from a game script are applied at once (api.cmd docs), so after each command the mod reads the counts of **every stock** of the warehouse or building again and compares them with before.
2. If nothing changed, it tries the next spelling of the cargo type: resource name, file name, short name, upper case. It remembers the one that works.
3. If the building took fewer items than sent, the rest goes back into the warehouse. A building that takes nothing is skipped for 30 days.
4. If **anything else changed** (another cargo type, another stock, a different amount), the mod puts the counts back as they were and **stops for good in that game**. It writes what happened to the game log.
5. If the command **does nothing at all**, the mod stops and says so in the log. That probably means debug commands need Debug Mode. It tries again a year later.
6. The **first move of a game is a single item**, so if the command misbehaves, very little is at stake.

Price learning listens to the game's `OnCalcTicketPrice` event and never changes the price.

The game runs game scripts in several Lua states, so everything that must survive (budgets, prices, unpaid money, the stop flag) lives in the script state, which is saved with the game. Module variables are only caches.

Files:

| File | What |
|---|---|
| `mod/warehouse_distribution_1/mod.json` | mod id, options |
| `content/warehouse_distribution/warehouse_distribution.gs.lua` | registers the game script (`update`, `handleEvent`) |
| `content/warehouse_distribution/warehouse_distribution.script.lua` | the game script: reach, moves, checks, payment |
| `content/warehouse_distribution/rules.lua` | allocation, pricing, options: no game API, tested on its own |
| `tests/mock_engine.lua` | mock of the engine API, with switchable command behaviour |
| `tests/*_test.lua` | tests; `tools/check.sh` runs them |

## Options

| Option | Values | Default |
|---|---|---|
| Delivery radius around a warehouse | Off, 100, 200, 300, 500 m | 200 m |
| Also deliver in the catchment area of its stations | No, Yes | Yes |
| Items per warehouse per month | 20, 50, 100, 200, No limit | 100 |
| Payment for cargo handed out | None, 50%, 100% | 100% |
| Warehouses that hand out cargo | All of mine, Only names with [D] | All of mine |
| Diagnostics in the game log | No, Yes | No |

## First test in the game

Use a new free game, or a copy of a save, and set **Diagnostics in the game log: Yes**. The log is `<Steam>\userdata\<your Steam ID>\3493540\local\crash_dump\stdout.txt`; the mod's lines start with `[Warehouse Distribution]`.

1. **Set up:** a coal mine, a truck line from the mine to a truck station, and a warehouse with a universal module in that station's catchment area. Put a steel mill (or any industry that takes coal) within 200 m of the warehouse but **outside** the station's catchment area, so that only the mod can supply it. Set the line to unload at the warehouse station.
2. **Hand-out:** once coal is in the warehouse, open the steel mill's window. Within a few in-game days coal should appear in its input stock, and the warehouse's coal should drop by the same amount. The log shows `buildings in reach` and lines like `warehouse … -> industry … (stock 0): 1 coal.cargo`.
3. **If the log says `stopped: the stock command changed nothing`**, turn on Debug Mode (Settings > Advanced), load the game again and repeat. If it still stops, the command isn't usable from a mod and the mod can't work as built. Please report it.
4. **If the log says `stopped: … changed: …`**, the command behaves differently than expected. The line says what changed. Please report it.
5. **Payment:** let any vehicle deliver cargo straight to an industry somewhere, so the mod learns a price. The log shows `learned price of …: … per m (delivery of … m paid …; event distance …)`. Then compare the income above the warehouse with what a direct delivery over the same distance pays. If it's far off, the `event distance` figure in that line shows why.
6. **Mixed module:** put two cargo types into one universal module, of which the building takes only one. The other one must stay.
7. **Town:** a warehouse with goods near the commercial or industrial district. Check the buildings' supply in their window and the town's cargo supply rating.
8. **Save and load:** distribution continues and nothing is paid twice.

## Known limits and open questions

- **Debug command.** It may need Debug Mode, and a game update may change or remove it. The mod checks every use and stops rather than guess.
- **Town growth.** The game gives towns XP when cargo arrives on a vehicle. Cargo handed out by a warehouse probably gives none. Whether a building's *supply* counts it is part of the in-game test.
- **Statistics.** The industry and town windows won't list the warehouse as a supplier, and cargo handed out won't show in their "delivered" figures.
- **Payment is an estimate.** It uses the game's base price per metre for the cargo type. It doesn't apply the company-rank ticket multiplier or subsidies, and ignores how long the cargo took.
- **Which items leave** a warehouse is up to the game. Handed-out cargo arrives at the building as new items.
- **Not built for multiplayer.**

## Installation

Copy `mod/warehouse_distribution_1` into your TF3 mods folder (`<Steam>\userdata\<your Steam ID>\3493540\local\mods\`) or the staging area next to it, and enable the mod in the game's mod menu. `tools/deploy.ps1` (Windows PowerShell) does that for every Steam user on the machine: `tools\deploy.ps1` for the staging area, `tools\deploy.ps1 -Target mods` for the mods folder.

The mod can be added to running games.

## Development

```
tools/check.sh          # JSON, _content.json, tests
tools/check.sh --fix    # also rewrites _content.json after adding files
lua tests/run.lua coal  # only tests whose name contains "coal"
```

The scripts are plain Lua for the game's Lua 5.2 sandbox. That means no `unpack`, `rawget`, `loadstring`, `goto` or `//`; the test runner removes those globals so accidental use fails. Tuning values are in `CONFIG` at the top of `warehouse_distribution.script.lua`. Raise `REVISION` there when a release fixes something that made the mod stop, so games that stopped try again.

## Credits

- The income booking (journal entries on the player, line and vehicle, the carrier mapping) and `tools/deploy.ps1` follow [Paid Warehouse Deliveries](https://github.com/GlcrTE/TF3-Paid-Warehouse-Deliveries) by GlcrTE, MIT licence.
- API facts come from the official [script documentation](https://wiki.transportfever3.com/script-doc/) and [modding manual](https://wiki.transportfever3.com/doku.php?id=modding).

## License

MIT, see [LICENSE](LICENSE).
