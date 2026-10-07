# Warehouse Distribution (TF3)

A Transport Fever 3 script mod: your warehouses hand their cargo to the industries and town buildings around them that take it. A warehouse becomes a buffer: a train or truck fills it, and it keeps the buildings in reach supplied.

In the base game a warehouse is only storage for vehicles. The game manual says: *"Town buildings and factories do not have access to the warehouse's content. They rely on you to transport their cargo from or to them."* This mod gives them that access.

> **Status: untested in the game.** Everything below is built against the official script API documentation and tested offline against a mock of the engine (50 tests, Lua 5.1, 5.2 and LuaJIT). The mod moves cargo with a command the game files under `debug`, and nobody has confirmed yet that the command works in a normal game. Do the [first test in the game](#first-test-in-the-game) on a new game or a copy of a save before you rely on it.

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

The mod pays it instead, **like a delivery from where the cargo was produced to the building that took it, using the game's own price code**. The game prices a cargo delivery like this:

- **Base price:** the cargo type's income function × distance × a constant. The income function depends on the cargo type and the time since the item was picked up. The constant reflects difficulty. Distance is the straight-line distance plus eight times any climb.
- **Paid:** the base price × what the game's scripts answer when the game asks for the price of the delivery (the `OnCalcTicketPrice` event). That covers the company rank's ticket price multiplier and subsidy bonuses.

For each item handed out, the mod calls the same code:

| Part | How |
|---|---|
| Income function, including the time since pickup | Each cargo type's own function, named in its resource (`scriptRef`) and called through the game's `util.useFn`. |
| Time since pickup | Counted from the item's pickup time. Time a specialized warehouse froze the delivery timer (`deliveryExtensionDuration`) is left out if that's what the game does; the mod measures which way matches the game's prices. |
| Company rank multiplier and subsidy bonuses | The base game's own company and subsidy scripts are asked about a made-up delivery event, the same question the game asks them. They get a throw-away copy of their state, and any command they send is dropped, so asking can't change anything in the game. If the company script can't be asked, the rank multiplier is read from `company_progression_util`. |
| The constant (difficulty) and the unit of the game's distances | Not exposed, so they're **measured** from the game's own deliveries. Every time one of your vehicles delivers cargo, the game reports the base price and distance, and the mod works out the constant. The formula is only used once at least 5 deliveries agree on it within 5%. That shows the mod is calling the same code the game uses. |

If part of it isn't available, the mod falls back as follows:

- If a cargo type's income function can't be called, or the measured constant doesn't agree across deliveries, it uses the average price per distance learned for that cargo type. That misses the time since pickup.
- If no multiplier is available, it uses ×1.
- Cargo handed out before the game has priced any delivery is paid once it has, at the learned price per distance.

The diagnostics log says which method priced each hand-out.

The money is booked once per warehouse and day, shown above the warehouse. It counts as transport income of the line and vehicle that brought the cargo to the warehouse, so it appears in the finance window and in the line and vehicle statistics. The option pays 100% (default), 50% or nothing. With infinite money nothing is booked.

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

Price measuring listens to the game's `OnCalcTicketPrice` event and never changes the price.

The game runs game scripts in several Lua states, so everything that must survive (budgets, prices, unpaid money, the stop flag) lives in the script state, which is saved with the game. Module variables are only caches.

Files:

| File | What |
|---|---|
| `mod/warehouse_distribution_1/mod.json` | mod id, options |
| `content/warehouse_distribution/warehouse_distribution.gs.lua` | registers the game script (`update`, `handleEvent`) |
| `content/warehouse_distribution/warehouse_distribution.script.lua` | the game script: reach, moves, checks, payment |
| `content/warehouse_distribution/rules.lua` | allocation, pricing, options: no game API, tested on its own |
| `mod/warehouse_distribution_1/_metadata/0.png` | preview image (1920x1080), rendered from `assets/preview.svg` |
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
5. **Payment:** let a few vehicles deliver cargo straight to industries or towns, so the mod can measure the game's prices. Then check the log:
   - `game price script company: handler …` and `… subsidies: handler …` mean the game's own price scripts were found. `not found` means they weren't, and the rank multiplier comes from `company_progression_util` instead.
   - `game delivery of …: … constant: frozen 0.5 (spread 0.0%), raw …` is one line per delivery. A spread near 0% for one of the two means the mod is calling the same price code as the game. If both spreads stay high, or it says `income function not found`, please send those lines.
   - `price of … handed out: … (game formula (frozen); multipliers from company, subsidies)` is the method used for each hand-out. `learned price per distance` means the fallback was used.
   
   Then compare the income shown above the warehouse with the income above a truck that delivers the same cargo over a similar distance.
6. **Mixed module:** put two cargo types into one universal module, of which the building takes only one. The other one must stay.
7. **Town:** a warehouse with goods near the commercial or industrial district. Check the buildings' supply in their window and the town's cargo supply rating.
8. **Save and load:** distribution continues and nothing is paid twice.

## Known limits and open questions

- **Debug command.** It may need Debug Mode, and a game update may change or remove it. The mod checks every use and stops rather than guess.
- **Town growth.** The game gives towns XP when cargo arrives on a vehicle. Cargo handed out by a warehouse probably gives none. Whether a building's *supply* counts it is part of the in-game test.
- **Statistics.** The industry and town windows won't list the warehouse as a supplier, and cargo handed out won't show in their "delivered" figures.
- **Payment relies on internals.** It calls the base game's own price code, but the paths of the company and subsidy scripts and how they're called come from reading the game's scripts, not from documentation. Each part is checked, falls back to the learned price or ×1 if missing, and the log says what was used.
  - Handed-out cargo doesn't count towards a subsidy's progress, because only a copy of the subsidy script's state is used.
  - Other mods that change prices through `OnCalcTicketPrice` aren't asked.
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

# preview image: edit assets/preview.svg, then
npm install --prefix tools/.cache @resvg/resvg-js
node tools/render_preview.js
```

The scripts are plain Lua for the game's Lua 5.2 sandbox. That means no `unpack`, `rawget`, `loadstring`, `goto` or `//`; the test runner removes those globals so accidental use fails. Tuning values are in `CONFIG` at the top of `warehouse_distribution.script.lua`. Raise `REVISION` there when a release fixes something that made the mod stop, so games that stopped try again.

## Credits

- The income booking (journal entries on the player, line and vehicle, the carrier mapping) and `tools/deploy.ps1` follow [Paid Warehouse Deliveries](https://github.com/GlcrTE/TF3-Paid-Warehouse-Deliveries) by GlcrTE, MIT licence.
- API facts come from the official [script documentation](https://wiki.transportfever3.com/script-doc/) and [modding manual](https://wiki.transportfever3.com/doku.php?id=modding).

## License

MIT, see [LICENSE](LICENSE).
