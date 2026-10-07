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
		assert(math.abs(state.value.rates[COAL] - 0.1) < 1e-9, tostring(state.value.rates[COAL]))
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

	test("a delivery whose ends are unknown is measured with the event's distance, scaled", function()
		local w, M, state, s = paidScene()
		-- known delivery: our 5,100 m, the event says 5.1 (a km figure)
		event(M, state, w.delivery(COAL, s.mine, s.msl, 510, 5.1))
		-- unknown destination: the event's 10.2 is 10,200 m with the learned scale, so 0.05 a metre
		event(M, state, w.delivery(IRON, -1, -1, 510, 10.2))
		-- (stock list -1 is no cargo delivery; use an unknown one)
		event(M, state, w.delivery(IRON, -1, 99999, 510, 10.2))
		assert(math.abs(state.value.rates[IRON] - 0.05) < 1e-6, tostring(state.value.rates[IRON]))
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
		assert(state.value ~= nil and math.abs(state.value.rates[COAL] - 0.1) < 1e-9)
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
