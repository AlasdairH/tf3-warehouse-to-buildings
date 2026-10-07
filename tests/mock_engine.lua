-- Mock of the parts of the Transport Fever 3 engine API the mod uses.
--
-- Stocks hold real cargo item entities (SIM_CARGO), so counts, item lists
-- and the stock command agree the way they do in the game. The stock
-- command's behaviour can be switched (world.setMode) to check the mod's
-- safety checks: "typed" (sets the count of one cargo type, the assumed
-- behaviour), "noop", "total" (ignores the cargo type), "deferred" (applied
-- only on world.applyDeferred) and "offbyone" (changes the next stock).

local mock = {}

local function copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = copy(x)
	end
	return out
end
mock.copy = copy

local CT = {}
for _, name in ipairs({ "GAME_TIME", "NAME", "STATION", "SIM_CARGO", "TOWN", "INDUSTRY", "STOCK_LIST",
	"TOWN_BUILDING", "TRANSPORT_VEHICLE", "BOUNDING_VOLUME", "CONSTRUCTION", "PLAYER_OWNED", "WAREHOUSE",
	"LINE" }) do
	CT[name] = name
end

local DAY = 2000
local YEAR = 365 * DAY
local MONTH = YEAR / 12
mock.DAY, mock.MONTH, mock.YEAR = DAY, MONTH, YEAR

local CARGO_NAMES = { [1] = "coal.cargo", [2] = "iron_ore.cargo", [3] = "steel.cargo", [4] = "goods.cargo",
	[5] = "fuel.cargo" }
mock.COAL, mock.IRON, mock.STEEL, mock.GOODS, mock.FUEL = 1, 2, 3, 4, 5

local INPUT, OUTPUT, STORAGE = 1, 2, 3

-- checks that a value can be saved with the game: plain data only
local function assertSavable(v, path)
	local t = type(v)
	if t == "table" then
		for k, x in pairs(v) do
			assert(type(k) == "number" or type(k) == "string", path .. ": key of type " .. type(k))
			assertSavable(x, path .. "." .. tostring(k))
		end
	elseif t == "number" then
		assert(v == v and v ~= math.huge and v ~= -math.huge, path .. ": " .. tostring(v))
	else
		assert(t == "string" or t == "boolean" or t == "nil", path .. ": value of type " .. t)
	end
end

function mock.state()
	local st = { value = nil, subscriptions = {}, writes = 0 }
	function st:get()
		return copy(self.value)
	end
	function st:set(v)
		assertSavable(v, "state")
		self.value = copy(v)
		self.writes = self.writes + 1
	end
	function st:hasEventSubscriptions()
		return next(self.subscriptions) ~= nil
	end
	function st:subscribeToEvent(name)
		self.subscriptions[name] = true
	end
	return st
end

function mock.new()
	ug_require = nil
	local w = {
		time = 0,
		nextId = 100,
		comps = {},
		items = {}, -- stock list -> stock id -> list of item entities
		catchables = {}, -- station -> list
		bookings = {},
		commands = {},
		deferred = {},
		log = {},
		mode = "typed",
		limit = {},
		balance = 1000000,
		modParams = { warehouse_distribution_1 = {} },
		acceptName = function(name)
			for id, n in pairs(CARGO_NAMES) do
				if n == name then
					return id
				end
			end
			return nil
		end,
	}
	w.player = 1
	w.world = 2
	w.comps[w.player] = {}
	w.comps[w.world] = { GAME_TIME = { gameTime = 0 } }

	function w.new(comps)
		w.nextId = w.nextId + 1
		w.comps[w.nextId] = comps or {}
		return w.nextId
	end

	function w.setMode(m)
		w.mode = m
	end

	function w.setOption(key, index)
		w.modParams.warehouse_distribution_1[key] = index
	end

	local function box(x, y, size, z)
		size = size or 10
		z = z or 0
		return { bbox = { min = { x = x - size / 2, y = y - size / 2, z = z }, max = { x = x + size / 2, y = y + size / 2, z = z + 10 } } }
	end

	-- stocks: list of { type, cargoType, cargoTypes (accepted list), capacity }
	function w.stockList(stocks)
		local list = {}
		for i, st in ipairs(stocks) do
			list[i] = { type = st.type, cargoType = st.cargoType or -1, capacity = st.capacity or 0, accepts = st.accepts }
		end
		local sl = w.new({ STOCK_LIST = { stocks = list } })
		w.items[sl] = {}
		for i = 1, #stocks do
			w.items[sl][i - 1] = {}
		end
		return sl
	end

	function w.addItems(sl, sid, cargo, n, fields)
		for _ = 1, n do
			local sc = { cargoType = cargo, sourceEntity = -1, pickupPoints = {}, startTime = w.time, pickupTime = w.time,
				deliveryExtensionDuration = 0 }
			for k, v in pairs(fields or {}) do
				sc[k] = copy(v)
			end
			local item = w.new({ SIM_CARGO = sc })
			table.insert(w.items[sl][sid], item)
		end
	end

	function w.count(sl, sid, cargo)
		local n = 0
		for _, item in ipairs(w.items[sl][sid]) do
			if cargo == nil or w.comps[item].SIM_CARGO.cargoType == cargo then
				n = n + 1
			end
		end
		return n
	end

	-- an industry at (x, y): inputs and outputs are lists of { cargo, capacity }
	function w.industry(x, y, inputs, outputs, size)
		local stocks = {}
		for _, s in ipairs(inputs or {}) do
			table.insert(stocks, { type = INPUT, cargoType = s[1], capacity = s[2] })
		end
		for _, s in ipairs(outputs or {}) do
			table.insert(stocks, { type = OUTPUT, cargoType = s[1], capacity = s[2] })
		end
		local sl = w.stockList(stocks)
		local con = w.new({ CONSTRUCTION = { industries = {}, townBuildings = {} }, BOUNDING_VOLUME = box(x, y, size or 40) })
		local ind = w.new({ INDUSTRY = { stockList = sl, construction = con } })
		w.comps[con].CONSTRUCTION.industries = { ind }
		return ind, sl, con
	end

	-- a town building with one input stock that takes `accepts` (list)
	function w.townBuilding(x, y, accepts, capacity, z)
		local sl = w.stockList({ { type = INPUT, accepts = accepts, capacity = capacity or 4,
			cargoType = #accepts == 1 and accepts[1] or -1 } })
		local tb = w.new({ TOWN_BUILDING = { stockList = sl, construction = -1 }, BOUNDING_VOLUME = box(x, y, 10, z) })
		return tb, sl
	end

	-- a residential building: no input stock
	function w.house(x, y)
		local sl = w.stockList({})
		return w.new({ TOWN_BUILDING = { stockList = sl, construction = -1 }, BOUNDING_VOLUME = box(x, y, 10) })
	end

	-- a warehouse at (x, y): modules is a list of { capacity, cargoType } (no cargoType: universal)
	function w.warehouse(x, y, modules, owner, name)
		local stocks = {}
		for _, m in ipairs(modules) do
			table.insert(stocks, { type = STORAGE, cargoType = m[2] or -1, capacity = m[1] })
		end
		local sl = w.stockList(stocks)
		local con = w.new({ CONSTRUCTION = {}, BOUNDING_VOLUME = box(x, y, 30), NAME = { name = name or "Warehouse" } })
		if owner ~= false then
			w.comps[con].PLAYER_OWNED = { player = owner or w.player }
		end
		local wh = w.new({ WAREHOUSE = { stockList = sl, construction = con } })
		if owner ~= false then
			w.comps[wh].PLAYER_OWNED = { player = owner or w.player }
		end
		return wh, sl, con
	end

	function w.station(catchables)
		local st = w.new({ STATION = {} })
		w.catchables[st] = catchables
		return st
	end

	function w.vehicle(carrier)
		return w.new({ TRANSPORT_VEHICLE = { carrier = carrier or 0 } })
	end

	function w.line(owner)
		return w.new({ LINE = {}, PLAYER_OWNED = { player = owner or w.player } })
	end

	-- items that left a stock: item -> { time, cargo = SimCargo }
	w.removed = {}
	local function destroy(item)
		w.removed[item] = { time = w.time, cargo = w.comps[item].SIM_CARGO }
		w.comps[item] = nil
	end

	-- sets how many items of `cargo` stock `sid` holds (the assumed command)
	local function setTyped(sl, sid, amount, cargo)
		local list = w.items[sl][sid]
		local have = w.count(sl, sid, cargo)
		if amount > have then
			local stock = w.comps[sl].STOCK_LIST.stocks[sid + 1]
			if w.clampToCapacity and stock.type == INPUT then
				amount = math.min(amount, have + math.max(0, stock.capacity - #list))
			end
			-- a stock that takes only this many more items (0: refuses)
			if w.limit[sl] ~= nil then
				amount = math.min(amount, have + w.limit[sl])
				w.limit[sl] = w.limit[sl] - (amount - have)
			end
			w.addItems(sl, sid, cargo, amount - have)
		else
			local toRemove = have - amount
			for i = #list, 1, -1 do
				if toRemove == 0 then
					break
				end
				if w.comps[list[i]].SIM_CARGO.cargoType == cargo then
					destroy(list[i])
					table.remove(list, i)
					toRemove = toRemove - 1
				end
			end
		end
	end

	local function setTotal(sl, sid, amount, cargo)
		local list = w.items[sl][sid]
		if amount > #list then
			w.addItems(sl, sid, cargo, amount - #list)
		else
			while #list > amount do
				destroy(list[#list])
				table.remove(list)
			end
		end
	end

	local function apply(cmd)
		if cmd.kind == "set" then
			local cargo = w.acceptName(cmd.name)
			if cargo == nil or w.items[cmd.stockList] == nil then
				return false
			end
			local sid = cmd.stockId
			if w.mode == "offbyone" then
				sid = sid + 1
				if w.items[cmd.stockList][sid] == nil then
					return false
				end
			end
			if w.mode == "noop" then
				return false
			elseif w.mode == "total" then
				setTotal(cmd.stockList, sid, cmd.amount, cargo)
			else
				setTyped(cmd.stockList, sid, cmd.amount, cargo)
			end
			return true
		elseif cmd.kind == "book" then
			table.insert(w.bookings, cmd)
			if cmd.account == w.player and w.balance ~= nil then
				w.balance = w.balance + cmd.entry.amount
			end
			return true
		end
	end

	function w.applyDeferred()
		local list = w.deferred
		w.deferred = {}
		for _, cmd in ipairs(list) do
			apply(cmd)
		end
	end

	function w.advance(ms)
		w.time = w.time + ms
		w.comps[w.world].GAME_TIME.gameTime = w.time
	end

	local function getComponent(e, ct)
		assert(type(ct) == "string", "unknown component type")
		local c = w.comps[e]
		return c ~= nil and copy(c[ct]) or nil
	end

	-- engine objects that raise an error for unknown keys, like the game's
	local function strict(t, name)
		return setmetatable(t, {
			__index = function(_, k)
				error(name .. " has no member " .. tostring(k), 2)
			end,
		})
	end

	api = {
		engine = {
			getComponent = getComponent,
			entityExists = function(e)
				return w.comps[e] ~= nil
			end,
			getEntitiesWithComponent = function(ct)
				local out = {}
				for e, c in pairs(w.comps) do
					if c[ct] ~= nil then
						table.insert(out, e)
					end
				end
				table.sort(out)
				return out
			end,
			config = {
				getModParams = function()
					return copy(w.modParams)
				end,
			},
			util = {
				getPlayer = function()
					return w.player
				end,
				getWorld = function()
					return w.world
				end,
				finance = {
					getPlayersBalance = function()
						return w.balance
					end,
				},
				stock = {
					getStockCargoTypes = function(sl, sid)
						local stock = w.comps[sl].STOCK_LIST.stocks[sid + 1]
						if stock.accepts ~= nil then
							return copy(stock.accepts)
						end
						return stock.cargoType >= 0 and { stock.cargoType } or {}
					end,
				},
			},
			system = {
				simEntityAtStockSystem = {
					getStockEntities = function(sl, sid)
						local out = {}
						for i, item in ipairs(w.items[sl] and w.items[sl][sid] or {}) do
							table.insert(out, { i, item })
						end
						return out
					end,
					getStockCount = function(sl, sid)
						return w.items[sl] and w.items[sl][sid] and #w.items[sl][sid] or 0
					end,
					getStockCountForCargoType = function(sl, sid, cargo)
						return w.items[sl] and w.items[sl][sid] and w.count(sl, sid, cargo) or 0
					end,
				},
				catchmentAreaSystem = {
					getStationCatchables = function(station, cargo)
						assert(cargo == true)
						return copy(w.catchables[station] or {})
					end,
				},
				streetConnectorSystem = {
					getConstructionEntityForSubconstruction = function()
						return -1
					end,
				},
			},
		},
		util = {
			getDefaultDayDuration = function()
				return DAY
			end,
			getDefaultMonthDuration = function()
				return MONTH
			end,
			getDefaultYearDuration = function()
				return YEAR
			end,
		},
		res = {
			cargoTypeRep = {
				getName = function(c)
					return CARGO_NAMES[c]
				end,
				getPassengerCargoTypeId = function()
					return 0
				end,
			},
		},
		cmd = strict({
			sendCommand = function(cmd, callback)
				assert(callback == nil, "game scripts must not pass a callback")
				if cmd.kind == "subsidy progress" then
					w.scriptCommands = w.scriptCommands + 1
					return
				end
				table.insert(w.commands, cmd)
				if w.mode == "deferred" and cmd.kind == "set" then
					table.insert(w.deferred, cmd)
					return
				end
				apply(cmd)
			end,
			debug = strict({
				makeStockSetCargoAmountCmd = function(sl, sid, amount, name)
					assert(type(amount) == "number" and amount >= 0 and amount == math.floor(amount), "amount " .. tostring(amount))
					return { kind = "set", stockList = sl, stockId = sid, amount = amount, name = name }
				end,
			}, "api.cmd.debug"),
			makeJournalBookAssetCmd = function(account, entry, pos)
				assert(type(entry.amount) == "number" and entry.amount == math.floor(entry.amount))
				return { kind = "book", account = account, entry = copy(entry), pos = copy(pos) }
			end,
		}, "api.cmd"),
		type = {
			ComponentType = CT,
			enum = {
				StockListType = { InputStock = INPUT, OutputStock = OUTPUT, StorageStock = STORAGE },
				Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, AIR = 3, WATER = 4 },
			},
			JournalEntry = {
				new = function()
					return { amount = 0, time = 0, category = {} }
				end,
				Type = { INCOME = "INCOME" },
				Carrier = { ROAD = "road", RAIL = "rail", TRAM = "tram", AIR = "air", WATER = "water", OTHER = "other" },
			},
			Vec3f = {
				new = function(x, y, z)
					return { x = x, y = y, z = z }
				end,
			},
		},
	}
	debugPrint = function(msg)
		table.insert(w.log, tostring(msg))
	end

	---------------------------------------------------------------------------
	-- The game's price code (w.gameCode()): cargo income functions, the
	-- difficulty constant, the company and subsidy scripts. The engine's base
	-- price for a delivery is difficulty x income function(params, time since
	-- pickup without frozen time) x distance in km, as w.price computes it.
	---------------------------------------------------------------------------

	w.difficulty = 0.5
	w.income = {
		[1] = { initialPrice = 3.5, finalPrice = 2.0, decayRate = 0.0005 },
		[2] = { initialPrice = 3.0, finalPrice = 2.5, decayRate = 0.0002 },
		[3] = { initialPrice = 5.0, finalPrice = 4.0, decayRate = 0.0001 },
		[4] = { initialPrice = 6.0, finalPrice = 5.0, decayRate = 0.0001 },
		[5] = { initialPrice = 4.0, finalPrice = 3.0, decayRate = 0.0001 },
	}
	local INCOME_REF = "::/economy/cargotype.script@incomeFactors.decayFn"
	function w.incomeFn(params, t)
		return math.max(params.finalPrice, params.initialPrice - params.decayRate * t / 1000)
	end

	function w.positionOf(e)
		local c = w.comps[e]
		if c == nil then
			return nil
		end
		if c.INDUSTRY ~= nil then
			return w.positionOf(c.INDUSTRY.construction)
		end
		local bv = c.BOUNDING_VOLUME
		if bv ~= nil then
			return { x = (bv.bbox.min.x + bv.bbox.max.x) / 2, y = (bv.bbox.min.y + bv.bbox.max.y) / 2, z = bv.bbox.min.z }
		end
		for owner, oc in pairs(w.comps) do
			local sl = (oc.INDUSTRY and oc.INDUSTRY.stockList) or (oc.TOWN_BUILDING and oc.TOWN_BUILDING.stockList)
			if sl == e then
				return w.positionOf(owner)
			end
		end
		return nil
	end

	-- metres, the game's rule: aerial distance plus eight times the climb
	function w.metres(a, b)
		local d = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		if (b.z or 0) > (a.z or 0) then
			d = d + 8 * (b.z - a.z)
		end
		return d
	end

	-- the engine's base price of a cargo item delivered to `dest` now
	function w.price(sc, dest, at)
		local t = math.max(0, (at or w.time) - sc.pickupTime - (sc.deliveryExtensionDuration or 0))
		local km = w.metres(w.positionOf(sc.sourceEntity), w.positionOf(dest)) / 1000
		return w.difficulty * w.incomeFn(w.income[sc.cargoType], t) * km, km
	end

	-- a delivery by one of the player's vehicles, as OnCalcTicketPrice reports it
	function w.gameDelivery(cargo, source, destStockList, age, frozen, line)
		local sc = { cargoType = cargo, sourceEntity = source, pickupPoints = {}, pickupTime = w.time - age,
			deliveryExtensionDuration = frozen or 0 }
		local item = w.new({ SIM_CARGO = sc })
		local price, km = w.price(sc, destStockList)
		return { { vehicleEntity = -1, lineEntity = line or -1, simEntity = item, stockListEntity = destStockList,
			basePrice = price, distance = km } }
	end

	w.companyMultiplier = 0.8
	w.subsidyLines = {} -- line -> multiplier the subsidy script answers
	w.scriptCommands = 0

	function w.gameCode(options)
		options = options or {}
		local company = w.new({ GAME_SCRIPT = { state = { multiplier = w.companyMultiplier } } })
		local subsidies = w.new({ GAME_SCRIPT = { state = { counted = 0 } } })
		local gs = {
			["::/game_mechanics/company/company_progression.gs"] = company,
			["::/game_mechanics/subventions/subventions.gs"] = subsidies,
		}
		w.gameScriptEntities = gs
		local refs = {
			[INCOME_REF] = w.incomeFn,
			-- the company script answers its rank's multiplier for the player's lines
			["::/game_mechanics/company/company_growth.script@handleEvent"] = function(_, state, _, _, name, param)
				if name ~= "OnCalcTicketPrice" then
					return nil
				end
				local out = {}
				for i, p in ipairs(param) do
					local po = w.comps[p.lineEntity] and w.comps[p.lineEntity].PLAYER_OWNED
					if po ~= nil and po.player == w.player then
						out[i] = state:get().multiplier
					end
				end
				return out
			end,
			-- the subsidy script counts deliveries (in its state) and answers its bonuses;
			-- it also tries to send a command, which must not reach the game
			["::/game_mechanics/subventions/subventions.script@handleEvent"] = function(_, state, _, _, name, param)
				if name ~= "OnCalcTicketPrice" then
					return nil
				end
				local st = state:get()
				st.counted = st.counted + #param
				state:set(st)
				api.cmd.sendCommand({ kind = "subsidy progress" })
				local out = {}
				for i, p in ipairs(param) do
					out[i] = w.subsidyLines[p.lineEntity]
				end
				return out
			end,
		}
		if options.noCompanyScript then
			refs["::/game_mechanics/company/company_growth.script@handleEvent"] = nil
		end
		if options.noIncomeFunction then
			refs[INCOME_REF] = nil
		end
		w.refs = refs
		local modules = {
			["::/scripts/util.tl"] = {
				useFn = function(ref)
					return refs[ref]
				end,
			},
			["::/game_mechanics/company/company_progression_util.tl"] = {
				getCompanyProgressionState = function(player)
					assert(player == w.player)
					return { ticketPriceMultiplier = w.companyMultiplier }
				end,
			},
		}
		ug_require = function(path)
			local m = modules[path]
			if m == nil then
				error("module not found: " .. tostring(path))
			end
			return m
		end
		api.type.ComponentType.GAME_SCRIPT = "GAME_SCRIPT"
		api.engine.system.gameScriptSystem = {
			getEntityForGameScript = function(name)
				return gs[name] or -1
			end,
		}
		api.res.cargoTypeRep.get = function(c)
			return { name = CARGO_NAMES[c], scriptRef = { fileName = INCOME_REF, params = copy(w.income[c]) } }
		end
		-- the subsidy script is found through its resource (relative handler), the company one by name
		api.res.gameScriptRep = {
			find = function(name)
				return name == "::/game_mechanics/subventions/subventions.gs" and 7 or -1
			end,
			getAsTable = function(id)
				assert(id == 7)
				return { handleEventScript = { fileName = "subventions.script@handleEvent" } }
			end,
		}
	end

	-- the money booked on an account
	function w.booked(account)
		local sum = 0
		for _, b in ipairs(w.bookings) do
			if b.account == account then
				sum = sum + b.entry.amount
			end
		end
		return sum
	end

	function w.logHas(pattern)
		for _, line in ipairs(w.log) do
			if string.find(line, pattern) then
				return true
			end
		end
		return false
	end

	-- a cargo delivery by a vehicle, as OnCalcTicketPrice reports it
	function w.delivery(cargo, source, destStockList, price, distance)
		local item = w.new({ SIM_CARGO = { cargoType = cargo, sourceEntity = source, pickupPoints = {} } })
		return { { vehicleEntity = -1, lineEntity = -1, simEntity = item, stockListEntity = destStockList,
			basePrice = price, distance = distance } }
	end

	return w
end

return mock
