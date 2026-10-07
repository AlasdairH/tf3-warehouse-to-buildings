-- Tests of the game script against the mock engine.

local mock = require("mock_engine")

return function(test, env)
	local SCRIPT = "warehouse_distribution/warehouse_distribution.script.lua"
	local COAL, IRON, STEEL, GOODS, FUEL = mock.COAL, mock.IRON, mock.STEEL, mock.GOODS, mock.FUEL
	local DAY, MONTH, YEAR = mock.DAY, mock.MONTH, mock.YEAR

	-- a world with a fresh script; the script is loaded after the mock so
	-- it sees the mock's api
	local function setup()
		local w = mock.new()
		local M = env.load(SCRIPT)
		local state = mock.state()
		return w, M, state
	end

	-- runs the game for `days`, eight updates a day
	local function run(w, M, state, days)
		for _ = 1, math.floor(days * 8) do
			w.advance(DAY / 8)
			env.sandboxed(M.update, {}, state, 1)
		end
	end

	local function event(M, state, entries)
		return env.sandboxed(M.handleEvent, {}, state, "", "TransportVehicleSystem", "OnCalcTicketPrice", entries)
	end

	-- all cargo of a type in the given stock lists
	local function sum(w, cargo, lists)
		local n = 0
		for _, sl in ipairs(lists) do
			for sid in pairs(w.items[sl]) do
				n = n + w.count(sl, sid, cargo)
			end
		end
		return n
	end

	-- a steel mill 100 m east of a warehouse with a universal module of 30 coal
	local function coalScene()
		local w, M, state = setup()
		local wh, wsl, wcon = w.warehouse(0, 0, { { 200 } })
		w.addItems(wsl, 0, COAL, 30)
		local mill, msl = w.industry(100, 0, { { COAL, 20 }, { IRON, 20 } }, { { STEEL, 50 } })
		return w, M, state, { wh = wh, wsl = wsl, wcon = wcon, mill = mill, msl = msl }
	end

	test("a warehouse fills a steel mill in reach with coal, nothing else", function()
		local w, M, state, s = coalScene()
		run(w, M, state, 30)
		assert(w.count(s.msl, 0, COAL) == 20, w.count(s.msl, 0, COAL))
		assert(w.count(s.wsl, 0, COAL) == 10)
		assert(w.count(s.msl, 1, COAL) == 0 and w.count(s.msl, 2, COAL) == 0, "only the coal input stock")
		assert(state.value.verified == true and state.value.moved == 20)
		assert(state.subscriptions.OnCalcTicketPrice, "subscribed to the game's prices")
		assert(#w.log == 0, "quiet without diagnostics: " .. tostring(w.log[1]))
	end)

	test("diagnostics option: reach and hand-outs in the game log", function()
		local w, M, state = coalScene()
		w.setOption("wdist_diagnostics", 2)
		run(w, M, state, 5)
		assert(w.logHas("1 buildings in reach"), w.log[1])
		assert(w.logHas("%-> industry %d+ %(stock 0%): %d+ coal.cargo"))
		assert(not w.logHas("error"))
	end)

	test("the first move of a game is a single item", function()
		local w, M, state, s = coalScene()
		w.setOption("wdist_speed", 5) -- no limit
		-- the first update starts the clock, the first tick comes a quarter day later
		run(w, M, state, 0.5)
		assert(w.count(s.msl, 0, COAL) == 1, w.count(s.msl, 0, COAL))
		run(w, M, state, 1)
		assert(w.count(s.msl, 0, COAL) == 20)
	end)

	test("cargo goes to the emptiest building first", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 3)
		local _, a = w.townBuilding(60, 0, { GOODS }, 4)
		local _, b = w.townBuilding(0, 60, { GOODS }, 4)
		local _, c = w.townBuilding(-60, 0, { GOODS }, 4)
		w.addItems(c, 0, GOODS, 2)
		run(w, M, state, 30)
		-- a and b (empty) first, one each, then a again (ties go to the first); c, half full, gets none
		assert(w.count(a, 0, GOODS) == 2 and w.count(b, 0, GOODS) == 1 and w.count(c, 0, GOODS) == 2,
			w.count(a, 0, GOODS) .. " " .. w.count(b, 0, GOODS) .. " " .. w.count(c, 0, GOODS))
	end)

	test("buildings out of reach get nothing; the radius option sets the reach", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		local _, near = w.townBuilding(150, 0, { GOODS }, 4)
		local _, far = w.townBuilding(400, 0, { GOODS }, 4)
		run(w, M, state, 30)
		assert(w.count(near, 0, GOODS) == 4 and w.count(far, 0, GOODS) == 0)

		w, M, state = setup()
		_, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		_, far = w.townBuilding(400, 0, { GOODS }, 4)
		w.setOption("wdist_radius", 5) -- 500 m
		run(w, M, state, 30)
		assert(w.count(far, 0, GOODS) == 4)
	end)

	test("with the radius off, a station's catchment area is the reach", function()
		local w, M, state = setup()
		w.setOption("wdist_radius", 1)
		local wh, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		local tbA, a = w.townBuilding(900, 0, { GOODS }, 4)
		local _, b = w.townBuilding(50, 0, { GOODS }, 4)
		w.station({ wh, tbA })
		run(w, M, state, 30)
		assert(w.count(a, 0, GOODS) == 4, "in the station's catchment area")
		assert(w.count(b, 0, GOODS) == 0, "close, but no radius and no station")

		-- and the station option off: nothing
		w, M, state = setup()
		w.setOption("wdist_radius", 1)
		w.setOption("wdist_stations", 1)
		wh, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		tbA, a = w.townBuilding(900, 0, { GOODS }, 4)
		w.station({ wh, tbA })
		run(w, M, state, 30)
		assert(w.count(a, 0, GOODS) == 0)
	end)

	test("a station's catchment area: an industry found through its construction", function()
		local w, M, state = setup()
		w.setOption("wdist_radius", 1)
		local _, wsl, wcon = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, COAL, 10)
		local _, msl, mcon = w.industry(2000, 0, { { COAL, 5 } })
		w.station({ wcon, mcon })
		run(w, M, state, 30)
		assert(w.count(msl, 0, COAL) == 5)
	end)

	test("only the player's own warehouses hand out cargo", function()
		local w, M, state = setup()
		local _, other = w.warehouse(0, 0, { { 50 } }, 99)
		local _, nobody = w.warehouse(0, 300, { { 50 } }, false)
		w.addItems(other, 0, GOODS, 10)
		w.addItems(nobody, 0, GOODS, 10)
		local _, a = w.townBuilding(60, 0, { GOODS }, 4)
		local _, b = w.townBuilding(60, 300, { GOODS }, 4)
		run(w, M, state, 30)
		assert(w.count(a, 0, GOODS) == 0 and w.count(b, 0, GOODS) == 0)
	end)

	test("only warehouses named with [D], if the option says so", function()
		local w, M, state = setup()
		w.setOption("wdist_which", 2)
		local _, tagged = w.warehouse(0, 0, { { 50 } }, nil, "Coal north [D]")
		local _, hub = w.warehouse(0, 1000, { { 50 } }, nil, "Coal hub")
		w.addItems(tagged, 0, GOODS, 10)
		w.addItems(hub, 0, GOODS, 10)
		local _, a = w.townBuilding(60, 0, { GOODS }, 4)
		local _, b = w.townBuilding(60, 1000, { GOODS }, 4)
		run(w, M, state, 30)
		assert(w.count(a, 0, GOODS) == 4 and w.count(b, 0, GOODS) == 0)
	end)

	test("a mixed warehouse keeps the cargo nobody in reach takes; no cargo is made or lost", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 200 }, { 100, FUEL } })
		w.addItems(wsl, 0, COAL, 10)
		w.addItems(wsl, 0, GOODS, 7)
		w.addItems(wsl, 0, IRON, 30)
		w.addItems(wsl, 1, FUEL, 9)
		local _, msl = w.industry(100, 0, { { COAL, 20 }, { IRON, 20 } }, { { STEEL, 50 } })
		w.house(50, 50)
		local lists = { wsl, msl }
		local before = {}
		for _, c in ipairs({ COAL, IRON, GOODS, FUEL, STEEL }) do
			before[c] = sum(w, c, lists)
		end
		run(w, M, state, 60)
		assert(w.count(msl, 0, COAL) == 10 and w.count(msl, 1, IRON) == 20)
		assert(w.count(wsl, 0, GOODS) == 7 and w.count(wsl, 1, FUEL) == 9 and w.count(wsl, 0, IRON) == 10)
		for _, c in ipairs({ COAL, IRON, GOODS, FUEL, STEEL }) do
			assert(sum(w, c, lists) == before[c], "cargo type " .. c .. " made or lost")
		end
	end)

	test("a town building whose stock takes two cargo types fills up once", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		w.addItems(wsl, 0, FUEL, 10)
		local _, tb = w.townBuilding(60, 0, { GOODS, FUEL }, 4)
		run(w, M, state, 30)
		assert(w.count(tb, 0) == 4, w.count(tb, 0))
	end)

	test("speed: at most the items per month of the option", function()
		local w, M, state = setup()
		w.setOption("wdist_speed", 1) -- 20 a month
		local _, wsl = w.warehouse(0, 0, { { 1000 } })
		w.addItems(wsl, 0, COAL, 500)
		local _, msl = w.industry(100, 0, { { COAL, 1000 } })
		run(w, M, state, 365 / 4) -- three months
		local moved = w.count(msl, 0, COAL)
		assert(moved >= 58 and moved <= 60, moved)
	end)

	test("several Lua states take turns without moving twice", function()
		local w = mock.new()
		local states = { env.load(SCRIPT), env.load(SCRIPT), env.load(SCRIPT) }
		local state = mock.state()
		local _, wsl = w.warehouse(0, 0, { { 1000 } })
		w.addItems(wsl, 0, COAL, 500)
		local _, msl = w.industry(100, 0, { { COAL, 1000 } })
		for i = 1, 8 * 30 do
			w.advance(DAY / 8)
			env.sandboxed(states[(i % 3) + 1].update, {}, state, 1)
		end
		local moved = w.count(msl, 0, COAL)
		-- 100 a month by default
		assert(moved >= 97 and moved <= 100, moved)
		assert(w.count(wsl, 0, COAL) + moved == 500)
	end)

	test("the command doing nothing stops the mod, with a reason, and it tries again a year later", function()
		local w, M, state, s = coalScene()
		w.setMode("noop")
		run(w, M, state, 30)
		assert(state.value.disabled ~= nil and state.value.disabled.kind == "noeffect")
		assert(w.logHas("Debug Mode"), "explains what to try")
		local sent = #w.commands
		run(w, M, state, 30)
		assert(#w.commands == sent, "stays off")
		w.setMode("typed")
		run(w, M, state, 365)
		assert(state.value.disabled == nil and w.count(s.msl, 0, COAL) == 20, "works again after a year")
	end)

	test("a deferred command stops the mod having lost at most one item", function()
		local w, M, state, s = coalScene()
		w.setMode("deferred")
		run(w, M, state, 5)
		assert(state.value.disabled ~= nil and state.value.disabled.kind == "noeffect")
		w.applyDeferred()
		assert(w.count(s.wsl, 0, COAL) >= 29)
	end)

	test("a command that ignores the cargo type is caught and the mod stops", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 200 } })
		w.addItems(wsl, 0, COAL, 5)
		w.addItems(wsl, 0, IRON, 10)
		w.industry(100, 0, { { COAL, 20 } })
		w.setMode("total")
		run(w, M, state, 10)
		local d = state.value.disabled
		assert(d ~= nil and d.kind == "unsafe", "stopped")
		assert(w.logHas("stopped"), "logged")
		local sent = #w.commands
		run(w, M, state, 400)
		assert(#w.commands == sent, "stays off, even after a year")
	end)

	test("a command that changes the wrong stock is caught and the mod stops", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 100, COAL }, { 100, IRON } })
		w.addItems(wsl, 0, COAL, 10)
		w.addItems(wsl, 1, IRON, 10)
		w.industry(100, 0, { { COAL, 20 } })
		w.setMode("offbyone")
		run(w, M, state, 10)
		assert(state.value.disabled ~= nil and state.value.disabled.kind == "unsafe")
	end)

	test("a building that refuses: the warehouse gets its cargo back, the building is skipped", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		local _, a = w.townBuilding(60, 0, { GOODS }, 4)
		w.limit[a] = 0
		run(w, M, state, 10)
		assert(w.count(wsl, 0, GOODS) == 10 and w.count(a, 0, GOODS) == 0)
		assert(state.value.disabled == nil)
		local _, b = w.townBuilding(0, 60, { GOODS }, 4)
		run(w, M, state, 20)
		assert(w.count(b, 0, GOODS) == 4, "other buildings still get cargo")
	end)

	test("a building that takes part: the rest goes back into the warehouse", function()
		local w, M, state = setup()
		w.setOption("wdist_speed", 5)
		local _, wsl = w.warehouse(0, 0, { { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		local _, a = w.townBuilding(60, 0, { GOODS }, 8)
		w.limit[a] = 3
		run(w, M, state, 2)
		assert(w.count(a, 0, GOODS) == 3 and w.count(wsl, 0, GOODS) == 7)
		assert(state.value.disabled == nil)
	end)

	test("a warehouse stock the command can't change is skipped once the command is known to work", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 50 }, { 50 } })
		w.addItems(wsl, 0, GOODS, 10)
		w.addItems(wsl, 1, FUEL, 10)
		local _, a = w.townBuilding(60, 0, { GOODS }, 4)
		local _, b = w.townBuilding(0, 60, { FUEL }, 4)
		run(w, M, state, 2)
		assert(state.value.verified)
		-- from now on fuel can't be changed
		local accept = w.acceptName
		w.acceptName = function(name)
			local c = accept(name)
			return c ~= FUEL and c or nil
		end
		run(w, M, state, 30)
		assert(state.value.disabled == nil, "not stopped")
		assert(w.count(a, 0, GOODS) == 4 and w.count(wsl, 1, FUEL) + w.count(b, 0, FUEL) == 10)
	end)

	test("no stock command in the game: the mod says so and does nothing", function()
		local w, M, state, s = coalScene()
		local cmd = getmetatable(api.cmd)
		setmetatable(api.cmd, nil)
		api.cmd.debug = nil
		setmetatable(api.cmd, cmd)
		run(w, M, state, 10)
		assert(w.count(s.msl, 0, COAL) == 0)
		assert(w.logHas("no makeStockSetCargoAmountCmd"))
		assert(not w.logHas("error"))
	end)

	---------------------------------------------------------------------------
	-- Town buildings
	---------------------------------------------------------------------------

	-- a warehouse with goods and coal in a town that needs goods (commercial)
	local function townScene()
		local w, M, state = setup()
		local town = w.town({ GOODS }, { FUEL })
		local _, wsl, wcon = w.warehouse(0, 0, { { 100 } })
		w.addItems(wsl, 0, GOODS, 20)
		w.addItems(wsl, 0, COAL, 20)
		return w, M, state, { town = town, wsl = wsl, wcon = wcon }
	end

	test("town: a building in reach gets the cargo its town needs, not other cargo its stock takes", function()
		local w, M, state, s = townScene()
		local _, b = w.townBuilding(80, 0, { COAL, GOODS }, 4, 0, { town = s.town })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4 and w.count(b, 0, COAL) == 0, w.count(b, 0, GOODS) .. " " .. w.count(b, 0, COAL))
	end)

	test("town: a building known only by its parcels is in reach", function()
		local w, M, state, s = townScene()
		w.octree = false
		local _, b = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town, position = "parcels" })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4)
	end)

	test("town: a building with no position is found by the engine's search around the warehouse", function()
		local w, M, state, s = townScene()
		local _, b = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town, position = "none" })
		local _, far = w.townBuilding(900, 0, { GOODS }, 4, 0, { town = s.town, position = "none" })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4 and w.count(far, 0, GOODS) == 0)
	end)

	test("town: a building with no position in a station's catchment area is supplied", function()
		local w, M, state, s = townScene()
		w.octree = false
		w.setOption("wdist_radius", 1)
		local tb, b = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town, position = "none" })
		w.station({ s.wcon, tb })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4)
	end)

	test("town: a catchment area that lists parcels or person capacities finds their buildings", function()
		local w, M, state, s = townScene()
		w.octree = false
		w.setOption("wdist_radius", 1)
		local tbA, a = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town, position = "parcels" })
		local _, b, pcB = w.townBuilding(0, 80, { GOODS }, 4, 0, { town = s.town, position = "none" })
		local parcel = w.comps[tbA].TOWN_BUILDING.parcels[1]
		w.station({ s.wcon, parcel, pcB })
		run(w, M, state, 30)
		assert(w.count(a, 0, GOODS) == 4 and w.count(b, 0, GOODS) == 4, w.count(a, 0, GOODS) .. " " .. w.count(b, 0, GOODS))
	end)

	test("town: a building that keeps its needs in a storage stock is supplied", function()
		local w, M, state, s = townScene()
		local _, b = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town, stockType = mock.STORAGE })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4)
	end)

	test("town: a building whose stock names a set of cargo types gets only what its town needs", function()
		local w, M, state, s = townScene()
		local _, b = w.townBuilding(80, 0, { GOODS, COAL }, 4, 0, { town = s.town, asSet = true })
		run(w, M, state, 30)
		assert(w.count(b, 0, GOODS) == 4 and w.count(b, 0, COAL) == 0)
	end)

	test("town: an industry's storage stock still gets nothing, only its input stocks", function()
		local w, M, state = setup()
		local _, wsl = w.warehouse(0, 0, { { 100 } })
		w.addItems(wsl, 0, COAL, 20)
		local sl = w.stockList({ { type = mock.STORAGE, cargoType = COAL, capacity = 50 } })
		local con = w.new({ CONSTRUCTION = {}, BOUNDING_VOLUME = { bbox = { min = { x = 60, y = -20, z = 0 }, max = { x = 100, y = 20, z = 10 } } } })
		w.new({ INDUSTRY = { stockList = sl, construction = con } })
		run(w, M, state, 30)
		assert(w.count(sl, 0, COAL) == 0)
	end)

	test("diagnostics say why a warehouse hands nothing out, building by building", function()
		local w, M, state, s = townScene()
		w.setOption("wdist_diagnostics", 2)
		local tb, b = w.townBuilding(80, 0, { GOODS }, 4, 0, { town = s.town })
		w.addItems(b, 0, GOODS, 4)
		w.house(0, 80)
		run(w, M, state, 5)
		assert(w.logHas("hands nothing out: no building in reach has room"), table.concat(w.log, "\n"))
		assert(w.logHas("town building " .. tb .. " of town " .. s.town .. ": stock 0 input %[goods.cargo%] 4/4"),
			table.concat(w.log, "\n"))
		assert(w.logHas("buildings: .*town building: takes cargo 1"), table.concat(w.log, "\n"))
		assert(w.logHas("town building: no stock that takes cargo 1"))
	end)

	---------------------------------------------------------------------------
	-- Payment
	---------------------------------------------------------------------------

	-- a coal mine 5 km west, a warehouse at 0 holding its coal brought by a
	-- truck of a line, a steel mill 100 m east of the warehouse
	local function paidScene()
		local w, M, state = setup()
		local mine, mineSl = w.industry(-5000, 0, {}, { { COAL, 100 } })
		local line, truck = w.line(), w.vehicle(0)
		local wh, wsl, wcon = w.warehouse(0, 0, { { 200 } })
		w.addItems(wsl, 0, COAL, 30, { sourceEntity = mine, pickupPoints = { { line = line, vehicle = truck } } })
		local mill, msl = w.industry(100, 0, { { COAL, 20 } })
		return w, M, state, { mine = mine, mineSl = mineSl, line = line, truck = truck, wh = wh, wsl = wsl,
			wcon = wcon, mill = mill, msl = msl }
	end

	test("the game's own deliveries teach the price; cargo handed out is paid like a delivery from its source", function()
		local w, M, state, s = paidScene()
		-- a delivery of coal from the mine to the mill: 5,100 m for 510
		assert(event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1)) == nil, "never changes the price")
		-- 100 per unit of the game's distance, which is 1/1000 of a metre of the mod's measure
		assert(math.abs(state.value.rates[COAL] - 100) < 1e-9, tostring(state.value.rates[COAL]))
		assert(math.abs(state.value.unit.value - 0.001) < 1e-12, tostring(state.value.unit.value))
		run(w, M, state, 40)
		assert(w.count(s.msl, 0, COAL) == 20)
		-- each item 5,100 m (mine to mill) at 0.1 a metre
		assert(w.booked(w.player) == 20 * 510, w.booked(w.player))
		assert(w.booked(s.line) == 20 * 510 and w.booked(s.truck) == 20 * 510, "line and vehicle statistics: "
			.. w.booked(s.line) .. ", " .. w.booked(s.truck))
		local first = nil
		for _, b in ipairs(w.bookings) do
			if b.account == w.player and first == nil then
				first = b
			end
		end
		assert(first.entry.category.type == "INCOME" and first.entry.category.carrier == "road")
		assert(first.pos.x == 0 and first.pos.y == 0, "shown above the warehouse")
	end)

	test("cargo handed out before a price is known is paid once it is", function()
		local w, M, state, s = paidScene()
		run(w, M, state, 40)
		assert(w.count(s.msl, 0, COAL) == 20)
		assert(w.booked(w.player) == 0 and state.value.owed[COAL] ~= nil)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 3)
		assert(w.booked(w.player) == 20 * 510, w.booked(w.player))
		assert(next(state.value.owed) == nil)
	end)

	test("a cargo type without its own price is paid at the average of the known ones", function()
		local w, M, state, s = paidScene()
		event(M, state, w.delivery(IRON, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 40)
		assert(w.booked(w.player) == 20 * 510, w.booked(w.player))
	end)

	test("payment option: 50% pays half, none pays nothing", function()
		local w, M, state, s = paidScene()
		w.setOption("wdist_payment", 2)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 40)
		assert(w.booked(w.player) == 10 * 510, w.booked(w.player))

		w, M, state, s = paidScene()
		w.setOption("wdist_payment", 1)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 40)
		assert(w.count(s.msl, 0, COAL) == 20 and #w.bookings == 0)
	end)

	test("infinite money: nothing is booked", function()
		local w, M, state, s = paidScene()
		w.balance = nil
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 40)
		assert(w.count(s.msl, 0, COAL) == 20 and #w.bookings == 0)
	end)

	test("a delivery whose ends are unknown still teaches the price per distance of the game's unit", function()
		local w, M, state, s = paidScene()
		-- known delivery: our 5,100 m, the event says 5.1 (a km figure)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		-- stock list -1 is no cargo delivery: nothing learned
		event(M, state, w.delivery(IRON, -1, -1, 510, 10.2))
		assert(state.value.rates[IRON] == nil)
		-- unknown source and destination: 510 for 10.2 units
		event(M, state, w.delivery(IRON, -1, 99999, 510, 10.2))
		assert(math.abs(state.value.rates[IRON] - 50) < 1e-9, tostring(state.value.rates[IRON]))
		-- iron handed out over 5,100 m: 50 x 5,100 x 0.001 = 255 each
		local _, wsl2 = w.warehouse(0, 2000, { { 50 } })
		w.addItems(wsl2, 0, IRON, 4, { sourceEntity = s.mine })
		local _, isl = w.industry(100, 2000, { { IRON, 4 } })
		run(w, M, state, 40)
		assert(w.count(isl, 0, IRON) == 4)
		assert(math.abs(w.booked(w.player) - 20 * 510 - 4 * 50 * w.metres({ x = -5000, y = 0 }, { x = 100, y = 2000 }) * 0.001) <= 2,
			w.booked(w.player))
	end)

	test("event data that is an engine object, not a plain table, teaches too", function()
		local w, M, state, s = paidScene()
		local entries = w.delivery(COAL, s.mine, s.msl, 510, 5.1)
		-- a proxy that answers only through __index, like engine userdata
		local function proxy(t)
			return setmetatable({}, { __index = function(_, k)
				local v = t[k]
				return type(v) == "table" and proxy(v) or v
			end })
		end
		event(M, state, proxy(entries))
		assert(state.value ~= nil and math.abs(state.value.rates[COAL] - 100) < 1e-9)
	end)

	---------------------------------------------------------------------------
	-- With the game's price code
	---------------------------------------------------------------------------

	-- the game's deliveries of each cargo type: young and old items, some with a frozen timer
	local function calibrate(w, M, state, s)
		for i = 1, 8 do
			event(M, state, w.gameDelivery(COAL, s.mine, s.msl, i * 400000, (i % 3) * 1000000, s.line))
		end
	end

	-- what the game would pay for the cargo the warehouse handed out to `dest`:
	-- its base price when it left, times `multiplier`
	local function expected(w, dest, multiplier)
		local sum, n = 0, 0
		for _, r in pairs(w.removed) do
			sum = sum + w.price(r.cargo, dest, r.time) * multiplier
			n = n + 1
		end
		return sum, n
	end

	-- the paid scene, its coal picked up long ago, partly frozen in a specialized warehouse
	local function gameScene(options)
		local w, M, state, s = paidScene()
		w.gameCode(options)
		-- game time is positive in a real game; -1 would mean "not picked up"
		w.advance(5000000)
		local list = w.items[s.wsl][0]
		for i, item in ipairs(list) do
			local sc = w.comps[item].SIM_CARGO
			sc.pickupTime = w.time - i * 50000
			sc.deliveryExtensionDuration = (i % 2) * 40000
		end
		w.setOption("wdist_speed", 5)
		return w, M, state, s
	end

	test("game price code: cargo handed out is paid exactly as the game prices a delivery", function()
		local w, M, state, s = gameScene()
		calibrate(w, M, state, s)
		local cal = state.value.calibration
		assert(math.abs(cal.frozen.value - 0.5) < 1e-9 and cal.frozen.dev < 1e-9, "the game's constant, measured")
		assert(cal.raw.dev > 0.05, "counting frozen time doesn't explain the game's prices")
		run(w, M, state, 5)
		assert(w.count(s.msl, 0, COAL) == 20)
		local want, n = expected(w, s.msl, 0.8)
		assert(n == 20)
		-- the player gets the money to the unit (fractions carried), line and vehicle the rounded amounts
		assert(math.abs(w.booked(w.player) - want) < 1, w.booked(w.player) .. " vs " .. want)
		assert(math.abs(w.booked(s.line) - want) < 2 and math.abs(w.booked(s.truck) - want) < 2)
	end)

	test("game price code: time counts, an older item pays less", function()
		local w, M, state, s = gameScene()
		calibrate(w, M, state, s)
		run(w, M, state, 5)
		local young, old = nil, nil
		for _, r in pairs(w.removed) do
			local p = w.price(r.cargo, s.msl, r.time)
			young = math.max(young or p, p)
			old = math.min(old or p, p)
		end
		assert(old < young * 0.9, "the items' ages make a difference in this scene")
		assert(math.abs(w.booked(w.player) - expected(w, s.msl, 0.8)) < 1)
	end)

	test("game price code: the subsidy script's bonus counts; it can't change the game", function()
		local w, M, state, s = gameScene()
		w.subsidyLines[s.line] = 2
		calibrate(w, M, state, s)
		run(w, M, state, 5)
		assert(math.abs(w.booked(w.player) - expected(w, s.msl, 0.8 * 2)) < 1, w.booked(w.player))
		assert(w.scriptCommands == 0, "the subsidy script's commands were dropped")
		assert(w.comps[w.gameScriptEntities["::/game_mechanics/subventions/subventions.gs"]].GAME_SCRIPT.state.counted == 0,
			"its state is untouched")
		assert(api.cmd.sendCommand ~= nil)
		local sent = #w.commands
		api.cmd.sendCommand({ kind = "book", account = 5, entry = { amount = 1 } })
		assert(#w.commands == sent + 1, "sendCommand works again afterwards")
	end)

	test("game price code: without the company script, its rank multiplier comes from company_progression_util", function()
		local w, M, state, s = gameScene({ noCompanyScript = true })
		w.companyMultiplier = 0.7
		calibrate(w, M, state, s)
		run(w, M, state, 5)
		assert(math.abs(w.booked(w.player) - expected(w, s.msl, 0.7)) < 1, w.booked(w.player))
	end)

	test("game price code: an item with no known line still pays the company rank's multiplier", function()
		local w, M, state, s = gameScene()
		for _, item in ipairs(w.items[s.wsl][0]) do
			w.comps[item].SIM_CARGO.pickupPoints = {}
		end
		calibrate(w, M, state, s)
		run(w, M, state, 5)
		assert(math.abs(w.booked(w.player) - expected(w, s.msl, 0.8)) < 1, w.booked(w.player))
	end)

	test("game price code: if the formula doesn't explain the game's prices, the learned price is used", function()
		local w, M, state, s = gameScene()
		-- prices the formula can't explain
		local real = w.price
		local i = 0
		w.price = function(sc, dest, at)
			i = i + 1
			local p, km = real(sc, dest, at)
			return p * (1 + 0.3 * math.sin(i)), km
		end
		calibrate(w, M, state, s)
		w.price = real
		assert(state.value.calibration.frozen.dev > 0.05)
		run(w, M, state, 5)
		-- 20 items at the learned price per distance, times the company multiplier
		local per = state.value.rates[COAL] * w.metres({ x = -5000, y = 0 }, { x = 100, y = 0 }) * state.value.unit.value
		assert(math.abs(w.booked(w.player) - 20 * per * 0.8) < 1, w.booked(w.player))
	end)

	test("game price code: a cargo type whose income function can't be called uses its learned price", function()
		local w, M, state, s = gameScene({ noIncomeFunction = true })
		calibrate(w, M, state, s)
		assert(next(state.value.calibration) == nil)
		run(w, M, state, 5)
		assert(w.count(s.msl, 0, COAL) == 20 and w.booked(w.player) > 0)
	end)

	test("passenger tickets teach nothing and the handler ignores other events", function()
		local w, M, state = paidScene()
		event(M, state, { { vehicleEntity = 1, lineEntity = 2, simEntity = 3, basePrice = 10, distance = 100 } })
		assert(state.value == nil or next(state.value.rates or {}) == nil)
		assert(env.sandboxed(M.handleEvent, {}, state, "", "TransportVehicleSystem", "OnArriveAtStop", {}) == nil)
		assert(not w.logHas("error"))
	end)

	test("one payment per warehouse and day, not one per item", function()
		local w, M, state, s = paidScene()
		w.setOption("wdist_speed", 5)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 5)
		local n = 0
		for _, b in ipairs(w.bookings) do
			if b.account == w.player then
				n = n + 1
			end
		end
		assert(n <= 2, n)
	end)

	test("the state stays small: payments and budgets of removed warehouses are cleaned up", function()
		local w, M, state, s = paidScene()
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		run(w, M, state, 10)
		w.comps[s.wh] = nil
		w.comps[s.wcon] = nil
		run(w, M, state, 3)
		assert(next(state.value.budget) == nil and next(state.value.unbooked) == nil)
	end)
end
