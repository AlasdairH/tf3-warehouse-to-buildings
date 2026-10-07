-- Warehouse Distribution
--
-- Your warehouses hand their cargo to the industries and town buildings
-- around them that take it, so a warehouse works as a buffer: a train or
-- truck fills it, and it keeps the buildings in reach supplied.
--
-- The base game has no way for a building to take cargo out of a warehouse
-- (wiki: "Town buildings and factories do not have access to the
-- warehouse's content"), and the script API has no command that moves a
-- cargo item. The only command that changes what a stock holds is
-- api.cmd.debug.makeStockSetCargoAmountCmd(stockList, stockId, amount,
-- cargoType), which sets how many items of a cargo type a stock holds. So a
-- move is two commands: the warehouse stock is set to n - k, the building's
-- input stock to m + k.
--
-- Commands sent from the engine state run at once (api.cmd docs), so every
-- command is checked by reading the stocks again. If a command does
-- nothing, the next spelling of the cargo type is tried; if it changes
-- anything else than asked, the change is undone and the mod stops
-- (state.disabled) and says why in the game log. The first move of a game
-- is a single item.
--
-- Payment: the base game pays only when a vehicle drops cargo at its final
-- destination, so cargo that leaves a warehouse this way would never be
-- paid. The mod pays it instead, like a delivery from where the cargo was
-- produced to the building that took it, with the game's own price code:
-- the cargo type's income function (time since pickup included), the
-- company rank's multiplier and subsidy bonuses (see "The game's own price
-- calculation"). Until a price is known the distance is kept (state.owed)
-- and paid later. The money is booked as transport income of the line and
-- vehicle that brought the cargo to the warehouse, like Paid Warehouse
-- Deliveries (GlcrTE, MIT) does.
--
-- Reach: the buildings within a radius of the warehouse (mod option), and
-- optionally all buildings in the catchment area of every station whose
-- catchment area holds the warehouse.
--
-- The game runs game scripts in several Lua states, so everything that
-- must survive a call lives in the script state (state:get / state:set);
-- module variables are only caches.
--
-- Written for the game's Lua 5.2 sandbox (no unpack, rawget, goto or //).

local rules = require("/warehouse_distribution/rules.lua")

local TAG = "[Warehouse Distribution]"
-- raise when a release fixes something that made the mod stop for safety,
-- so savegames try again
local REVISION = 1

local CONFIG = {
	-- distribution runs this often per in-game day
	ticksPerDay = 4,
	-- the list of warehouses is read again this often per day
	warehouseRefreshPerDay = 2,
	-- the buildings in reach are found again after this many days
	reachRefreshDays = 15,
	-- at most this many items per warehouse and tick
	maxItemsPerTick = 200,
	-- an idle warehouse saves up at most this share of a month's items
	budgetCapMonths = 0.25,
	-- a warehouse's payments are booked as one amount after this many days
	bookAfterDays = 1,
	-- learned prices follow the last this many deliveries of a cargo type
	rateSamples = 20,
	-- the constant of the game's price formula and the distance unit follow
	-- the last this many deliveries
	calibrationSamples = 50,
	unitSamples = 50,
	-- the formula is used once this many deliveries agree on its constant
	-- within this share
	minCalibrationSamples = 5,
	maxCalibrationDeviation = 0.05,
	-- multipliers of the game's price scripts above this are ignored
	maxMultiplier = 20,
	-- deliveries shorter than this (metres, the mod's measure) don't teach
	-- the distance unit, and teach nothing if the game reports no distance
	minSampleDistance = 500,
	-- a stock that refused cargo is skipped this many days
	refusedDays = 30,
	-- after the stock command had no effect, try again after this many years
	retryAfterYears = 1,
	-- book the income on the line and vehicle that brought the cargo too
	bookOnVehicle = true,
	-- at most this many diagnostic lines per Lua state
	diagnosticsLimit = 300,
}

-- mod options (mod.json params): key, values by 1-based index, default index
local OPTIONS = {
	radius = { "wdist_radius", { 0, 100, 200, 300, 500 }, 3 },
	stations = { "wdist_stations", { false, true }, 2 },
	perMonth = { "wdist_speed", { 20, 50, 100, 200, math.huge }, 3 },
	payment = { "wdist_payment", { 0, 0.5, 1.0 }, 3 },
	onlyTagged = { "wdist_which", { false, true }, 1 },
	diagnostics = { "wdist_diagnostics", { false, true }, 1 },
}

---------------------------------------------------------------------------
-- Logging
---------------------------------------------------------------------------

local options = nil
local diagCount = 0
local reported = {}

-- written once per Lua state and message key, always
local function report(key, msg)
	if not reported[key] then
		reported[key] = true
		debugPrint(TAG .. " " .. msg)
	end
end

local function diag(fmt, ...)
	if options ~= nil and options.diagnostics and diagCount < CONFIG.diagnosticsLimit then
		diagCount = diagCount + 1
		debugPrint(TAG .. " " .. string.format(fmt, ...))
	end
end

---------------------------------------------------------------------------
-- Reading the game
---------------------------------------------------------------------------

local function CT()
	return api.type.ComponentType
end

local function valid(entity)
	return type(entity) == "number" and entity >= 0
end

-- a field of an engine object; nil if it has none (some engine objects raise
-- an error for unknown keys)
local function field(t, k)
	local ok, v = pcall(function()
		return t[k]
	end)
	if ok then
		return v
	end
	return nil
end

-- a function of the api by its path, e.g. apiFn("res", "gameScriptRep",
-- "find"); nil if the game doesn't have it
local function apiFn(...)
	local t = api
	for _, k in ipairs({ ... }) do
		t = t ~= nil and field(t, k) or nil
	end
	return t
end

local function exists(entity)
	if not valid(entity) then
		return false
	end
	local ok, r = pcall(api.engine.entityExists, entity)
	return ok and r == true
end

local function comp(entity, componentType)
	if not valid(entity) then
		return nil
	end
	local ok, c = pcall(api.engine.getComponent, entity, componentType)
	if ok then
		return c
	end
	return nil
end

local function entitiesWith(componentType)
	local ok, list = pcall(api.engine.getEntitiesWithComponent, componentType)
	if ok and type(list) == "table" then
		return list
	end
	return {}
end

local function gameTime()
	local t = comp(api.engine.util.getWorld(), CT().GAME_TIME)
	return t.gameTime
end

local function day()
	return api.util.getDefaultDayDuration()
end

local function month()
	return api.util.getDefaultMonthDuration()
end

local function year()
	return api.util.getDefaultYearDuration()
end

local function readOptions()
	local ok, params = pcall(api.engine.config.getModParams)
	if not ok then
		params = nil
	end
	local out = {}
	for name, o in pairs(OPTIONS) do
		out[name] = rules.option(params, o[1], o[2], o[3])
	end
	return out
end

local function ownerOf(entity)
	local po = comp(entity, CT().PLAYER_OWNED)
	return po ~= nil and po.player or nil
end

-- the construction an entity belongs to, or the entity itself
local function parentConstruction(entity)
	local ok, parent = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction, entity)
	if ok and valid(parent) then
		return parent
	end
	return entity
end

local function nameOf(entity)
	local n = comp(entity, CT().NAME)
	return n ~= nil and n.name or nil
end

local function vec(v)
	if v == nil then
		return nil
	end
	local ok, x, y, z = pcall(function()
		return v.x, v.y, v.z
	end)
	if ok and type(x) == "number" and type(y) == "number" then
		return { x = x, y = y, z = type(z) == "number" and z or 0 }
	end
	return nil
end

local function translation(m)
	if m == nil then
		return nil
	end
	local ok, p = pcall(function()
		return m:getTransl()
	end)
	if ok and vec(p) ~= nil then
		return vec(p)
	end
	ok, p = pcall(function()
		return { x = m[13], y = m[14], z = m[15] }
	end)
	if ok and type(p.x) == "number" and type(p.y) == "number" then
		return p
	end
	return nil
end

-- footprint of an entity's own geometry: its bounding box, or the position
-- of its construction; x0, y0, x1, y1 and z (ground)
local function ownFootprint(entity)
	local bv = comp(entity, CT().BOUNDING_VOLUME)
	if bv ~= nil and bv.bbox ~= nil then
		local mn, mx = vec(bv.bbox.min), vec(bv.bbox.max)
		if mn ~= nil and mx ~= nil and mx.x >= mn.x and mx.y >= mn.y then
			return { x0 = mn.x, y0 = mn.y, x1 = mx.x, y1 = mx.y, z = mn.z }
		end
	end
	local con = comp(entity, CT().CONSTRUCTION)
	local p = con ~= nil and translation(con.transf) or nil
	if p ~= nil then
		return { x0 = p.x, y0 = p.y, x1 = p.x, y1 = p.y, z = p.z }
	end
	return nil
end

-- stock list -> the industry or town building that owns it (cache)
local ownerOfStockList = {}

-- footprint of an industry, town building, warehouse (their construction)
-- or stock list; nil if unknown
local function footprintOf(entity)
	if not valid(entity) then
		return nil
	end
	local owner = ownerOfStockList[entity]
	if owner ~= nil and owner ~= entity then
		return footprintOf(owner)
	end
	local ind = comp(entity, CT().INDUSTRY)
	local wh = comp(entity, CT().WAREHOUSE)
	local con = (ind ~= nil and ind.construction) or (wh ~= nil and wh.construction) or nil
	local f = valid(con) and ownFootprint(con) or nil
	if f == nil then
		f = ownFootprint(entity)
	end
	if f == nil then
		local tb = comp(entity, CT().TOWN_BUILDING)
		if tb ~= nil then
			if valid(tb.construction) then
				f = ownFootprint(tb.construction)
			end
			-- the parcels it stands on
			for _, parcel in ipairs(f == nil and tb.parcels or {}) do
				local pf = ownFootprint(parcel)
				if pf ~= nil then
					if f == nil then
						f = pf
					else
						f = { x0 = math.min(f.x0, pf.x0), y0 = math.min(f.y0, pf.y0), x1 = math.max(f.x1, pf.x1),
							y1 = math.max(f.y1, pf.y1), z = math.min(f.z or 0, pf.z or 0) }
					end
				end
			end
			if f == nil and valid(tb.personCapacity) then
				f = ownFootprint(tb.personCapacity)
			end
		end
	end
	return f
end

-- ground point of a footprint, for distances
local function spot(f)
	local c = rules.centre(f)
	c.z = f.z or 0
	return c
end

local passengerCargo = nil

local function cargoType(c)
	if type(c) ~= "number" or c < 0 then
		return false
	end
	if passengerCargo == nil then
		local ok, p = pcall(api.res.cargoTypeRep.getPassengerCargoTypeId)
		passengerCargo = ok and type(p) == "number" and p or -1
	end
	return c ~= passengerCargo
end

local function cargoName(c)
	local ok, n = pcall(api.res.cargoTypeRep.getName, c)
	if ok and type(n) == "string" then
		return n
	end
	return tostring(c)
end

local stockTypes = nil

local function stockType(name)
	if stockTypes == nil then
		local e = api.type["enum"].StockListType
		stockTypes = { input = field(e, "InputStock"), output = field(e, "OutputStock"), storage = field(e, "StorageStock") }
	end
	return stockTypes[name]
end

local function isInput(stock)
	return stock.type == stockType("input")
end

local function stockTypeName(stock)
	for _, name in ipairs({ "input", "output", "storage" }) do
		if stock.type == stockType(name) then
			return name
		end
	end
	return "type " .. tostring(stock.type)
end

-- Stocks a building takes cargo into: input stocks; a town building also
-- any stock that isn't an output (where it keeps its needs isn't documented).
local function receives(kind, stock)
	if isInput(stock) then
		return true
	end
	return kind == "town building" and stock.type ~= stockType("output")
end

local function stocksOf(stockList)
	local sl = comp(stockList, CT().STOCK_LIST)
	return sl ~= nil and sl.stocks or {}
end

-- the cargo types a town needs (all its districts), nil if unknown; cached
-- until the reach is found again
local townNeedsCache = {}

local function townNeeds(town)
	if not valid(town) then
		return nil
	end
	local cached = townNeedsCache[town]
	if cached == nil then
		cached = false
		local t = comp(town, CT().TOWN)
		local needs = t ~= nil and field(t, "cargoNeeds") or nil
		if type(needs) == "table" then
			local set, any = {}, false
			for _, district in pairs(needs) do
				for _, need in pairs(type(district) == "table" and district or {}) do
					local c = type(need) == "table" and need[1] or need
					if cargoType(c) then
						set[c] = true
						any = true
					end
				end
			end
			if any then
				cached = set
			end
		end
		townNeedsCache[town] = cached
	end
	return cached or nil
end

-- Cargo types a building's stock takes: what the game says the stock takes,
-- else its cargo type, else its set of cargo types. For a town building only
-- those its town needs. Second result: before that filter.
local function acceptedCargo(stockList, stockId, stock, consumer)
	local out, seen = {}, {}
	local function add(c)
		if cargoType(c) and not seen[c] then
			seen[c] = true
			table.insert(out, c)
		end
	end
	local ok, list = pcall(apiFn("engine", "util", "stock", "getStockCargoTypes"), stockList, stockId)
	if ok and type(list) == "table" then
		for _, c in ipairs(list) do
			add(c)
		end
	end
	if #out == 0 then
		add(stock.cargoType)
	end
	local set = field(stock, "cargoTypes")
	if #out == 0 and set ~= nil then
		pcall(apiFn("res", "cargoTypeRep", "forEachCargoType"), set, add)
	end
	if consumer == nil or consumer.kind ~= "town building" then
		return out, out
	end
	local needs = townNeeds(consumer.town)
	if needs == nil then
		return out, out
	end
	local needed = {}
	for _, c in ipairs(out) do
		if needs[c] then
			table.insert(needed, c)
		end
	end
	return needed, out
end

local function countOf(stockList, stockId, c)
	local n = api.engine.system.simEntityAtStockSystem.getStockCountForCargoType(stockList, stockId, c)
	return type(n) == "number" and n or 0
end

local function totalOf(stockList, stockId)
	local n = api.engine.system.simEntityAtStockSystem.getStockCount(stockList, stockId)
	return type(n) == "number" and n or 0
end

-- the cargo items in a stock: entity -> SimCargo. getStockEntities returns
-- pairs; the cargo item is the element with a SIM_CARGO component.
local function itemsIn(stockList, stockId)
	local out = {}
	local ok, entries = pcall(api.engine.system.simEntityAtStockSystem.getStockEntities, stockList, stockId)
	if not ok or type(entries) ~= "table" then
		return out
	end
	for _, entry in ipairs(entries) do
		local candidates = type(entry) == "table" and { entry[2], entry[1] } or { entry }
		for _, e in ipairs(candidates) do
			local sc = comp(e, CT().SIM_CARGO)
			if sc ~= nil then
				out[e] = sc
				break
			end
		end
	end
	return out
end

-- where a cargo item was produced, nil if unknown
local function originOf(simCargo)
	local f = footprintOf(simCargo.sourceEntity)
	return f ~= nil and spot(f) or nil
end

-- the line and vehicle that brought a cargo item to where it is
local function lastCarrierOf(simCargo)
	local points = simCargo.pickupPoints
	local ok, n = pcall(function()
		return #points
	end)
	if ok and n ~= nil and n > 0 then
		local p = points[n]
		local line, vehicle = p.line, p.vehicle
		return valid(line) and line or -1, valid(vehicle) and vehicle or -1
	end
	return -1, -1
end

---------------------------------------------------------------------------
-- Warehouses and the buildings in their reach (caches of this Lua state)
---------------------------------------------------------------------------

local cache = {
	warehouses = nil, -- list of { entity, construction, stockList, name, footprint }
	warehousesAt = nil,
	reach = nil, -- warehouse construction -> list of consumers, closest first
	reachAt = nil,
	reachKey = nil, -- warehouses and options the reach was found for
	consumers = {}, -- consumer entity -> { entity, kind, stockList, footprint, town }
	explained = {}, -- warehouse construction -> true once its idle buildings were described
	refused = {}, -- "stockList:stockId" -> game time until which it is skipped
}

local function readWarehouses(now)
	local player = api.engine.util.getPlayer()
	local out = {}
	for _, e in ipairs(entitiesWith(CT().WAREHOUSE)) do
		local wh = comp(e, CT().WAREHOUSE)
		if wh ~= nil and valid(wh.stockList) and valid(wh.construction) then
			local a, b = ownerOf(e), ownerOf(wh.construction)
			-- only the player's own: warehouses without an owner (e.g. placed by a map) don't count
			if (a == player or b == player) and (a == nil or a == player) and (b == nil or b == player) then
				table.insert(out, {
					entity = e,
					construction = wh.construction,
					stockList = wh.stockList,
					name = nameOf(wh.construction) or nameOf(e),
					footprint = footprintOf(e),
				})
			end
		end
	end
	table.sort(out, function(x, y)
		return x.construction < y.construction
	end)
	cache.warehouses = out
	cache.warehousesAt = now
	return out
end

-- what the last search for buildings found, for the diagnostics
local census = nil

local function count(key)
	if census ~= nil then
		census[key] = (census[key] or 0) + 1
	end
end

-- The building as a consumer, nil if it takes no cargo. Its footprint may be
-- unknown (nil): then it can only be in reach through a station's catchment
-- area or the engine's search around the warehouse.
local function addConsumer(entity, kind, stockList, town)
	if not valid(stockList) then
		count(kind .. ": no stock list")
		return nil
	end
	ownerOfStockList[stockList] = entity
	local c = cache.consumers[entity]
	if c ~= nil then
		return c
	end
	local takes = false
	for _, st in ipairs(stocksOf(stockList)) do
		if receives(kind, st) then
			takes = true
			break
		end
	end
	if not takes then
		count(kind .. ": no stock that takes cargo")
		return nil
	end
	c = { entity = entity, kind = kind, stockList = stockList, footprint = footprintOf(entity), town = town }
	count(kind .. (c.footprint ~= nil and ": takes cargo" or ": takes cargo, position unknown"))
	cache.consumers[entity] = c
	return c
end

local personCapacityOwners = nil

-- The consumers (industries and town buildings that take cargo) an entity
-- stands for: the building itself, the buildings of its construction, or the
-- building of its stock list, parcel or person capacity. Returns true if the
-- entity is a building at all (even one that takes nothing).
local function consumersOf(entity, out, depth)
	depth = depth or 0
	local c = cache.consumers[entity]
	if c ~= nil then
		table.insert(out, c)
		return true
	end
	local ind = comp(entity, CT().INDUSTRY)
	if ind ~= nil then
		c = addConsumer(entity, "industry", ind.stockList)
		if c ~= nil then
			table.insert(out, c)
		end
		return true
	end
	local tb = comp(entity, CT().TOWN_BUILDING)
	if tb ~= nil then
		c = addConsumer(entity, "town building", tb.stockList, tb.town)
		if c ~= nil then
			table.insert(out, c)
		end
		return true
	end
	local con = comp(entity, CT().CONSTRUCTION) or comp(parentConstruction(entity), CT().CONSTRUCTION)
	local found = false
	if con ~= nil then
		for _, e in ipairs(con.industries or {}) do
			found = consumersOf(e, out, depth + 1) or found
		end
		for _, e in ipairs(con.townBuildings or {}) do
			found = consumersOf(e, out, depth + 1) or found
		end
	end
	if found or depth > 0 then
		return found
	end
	-- a stock list, parcel or person capacity of a building
	local owner = ownerOfStockList[entity]
	if owner == nil then
		local ok, b = pcall(apiFn("engine", "system", "townBuildingSystem", "getBuilding"), entity)
		if ok and valid(b) and b ~= entity then
			owner = b
		end
	end
	if owner == nil then
		if personCapacityOwners == nil then
			local ok, map = pcall(apiFn("engine", "system", "townBuildingSystem", "getPersonCapacity2townBuildingMap"))
			personCapacityOwners = ok and type(map) == "table" and map or {}
		end
		owner = personCapacityOwners[entity]
	end
	if valid(owner) and owner ~= entity then
		return consumersOf(owner, out, depth + 1)
	end
	return false
end

-- every industry and town building that takes cargo; also fills
-- ownerOfStockList, which the price learning needs
local function readConsumers()
	cache.consumers = {}
	townNeedsCache = {}
	personCapacityOwners = nil
	census = {}
	local all = {}
	for _, e in ipairs(entitiesWith(CT().INDUSTRY)) do
		local ind = comp(e, CT().INDUSTRY)
		local c = ind ~= nil and addConsumer(e, "industry", ind.stockList) or nil
		if c ~= nil then
			table.insert(all, c)
		end
	end
	for _, e in ipairs(entitiesWith(CT().TOWN_BUILDING)) do
		local tb = comp(e, CT().TOWN_BUILDING)
		local c = tb ~= nil and addConsumer(e, "town building", tb.stockList, tb.town) or nil
		if c ~= nil then
			table.insert(all, c)
		end
	end
	local parts = {}
	for k, n in pairs(census) do
		table.insert(parts, k .. " " .. n)
	end
	table.sort(parts)
	diag("buildings: %s", #parts > 0 and table.concat(parts, ", ") or "none")
	census = nil
	return all
end

local function vec2(x, y)
	local ok, v = pcall(apiFn("type", "Vec2f", "new"), x, y)
	if ok and v ~= nil and field(v, "x") == x and field(v, "y") == y then
		return v
	end
	ok, v = pcall(apiFn("type", "Vec2f", "new"))
	if ok and v ~= nil and pcall(function()
		v.x = x
		v.y = y
	end) then
		return v
	end
	return { x = x, y = y }
end

-- entities with a component within r of (x, y), from the engine's own
-- spatial search; nil if the game has none
local function inCircle(x, y, r, componentType)
	local find = apiFn("engine", "util", "octree", "findEntitiesInCircle")
	if find == nil then
		return nil
	end
	local ok, list = pcall(find, vec2(x, y), r, componentType)
	if ok and type(list) == "table" then
		return list
	end
	return nil
end

local function reachKey(warehouses)
	local parts = { tostring(options.radius), tostring(options.stations) }
	for _, w in ipairs(warehouses) do
		table.insert(parts, tostring(w.construction))
	end
	return table.concat(parts, ",")
end

local function readReach(warehouses, now)
	local all = readConsumers()
	local sets = {}
	local gaps = {}
	for _, w in ipairs(warehouses) do
		sets[w.construction] = {}
		gaps[w.construction] = {}
	end

	local how = {}
	if options.radius > 0 then
		for _, w in ipairs(warehouses) do
			if w.footprint ~= nil then
				-- the engine's search, around the warehouse's centre out to its edge plus the radius
				local f = w.footprint
				local ctr = rules.centre(f)
				local r = options.radius + math.max(f.x1 - f.x0, f.y1 - f.y0) / 2
				for _, ct in ipairs({ CT().INDUSTRY, CT().TOWN_BUILDING }) do
					local hits = inCircle(ctr.x, ctr.y, r, ct)
					if hits ~= nil then
						how[w.construction] = "engine search"
						for _, e in ipairs(hits) do
							local list = {}
							consumersOf(e, list)
							for _, c in ipairs(list) do
								sets[w.construction][c.entity] = c
							end
						end
					end
				end
				-- and the buildings whose footprint is known
				for _, c in ipairs(all) do
					if c.footprint ~= nil then
						local g = rules.gap(w.footprint, c.footprint)
						if g <= options.radius then
							sets[w.construction][c.entity] = c
							gaps[w.construction][c.entity] = g
						end
					end
				end
				how[w.construction] = (how[w.construction] and how[w.construction] .. " and " or "") .. "footprints"
			else
				how[w.construction] = "warehouse position unknown"
			end
		end
	end

	if options.stations then
		-- a warehouse is known by its entity, stock list and construction
		local whOf = {}
		for _, w in ipairs(warehouses) do
			whOf[w.entity] = w.construction
			whOf[w.stockList] = w.construction
			whOf[w.construction] = w.construction
		end
		for _, station in ipairs(entitiesWith(CT().STATION)) do
			local ok, catchables = pcall(api.engine.system.catchmentAreaSystem.getStationCatchables, station, true)
			if ok and type(catchables) == "table" then
				local inReach, consumers, unknown = {}, {}, {}
				for _, e in ipairs(catchables) do
					local w = whOf[e] or whOf[parentConstruction(e)]
					if w ~= nil then
						inReach[w] = true
					elseif not consumersOf(e, consumers) and #unknown < 5 then
						table.insert(unknown, e)
					end
				end
				for w in pairs(inReach) do
					for _, c in ipairs(consumers) do
						sets[w][c.entity] = c
					end
					diag("station %d reaches warehouse %d: %d of its %d catchables take cargo%s", station, w, #consumers,
						#catchables, #unknown > 0 and (", not buildings: " .. table.concat(unknown, ", ")) or "")
				end
			end
		end
	end

	cache.reach = {}
	for _, w in ipairs(warehouses) do
		local list = {}
		for _, c in pairs(sets[w.construction]) do
			table.insert(list, c)
		end
		local g = gaps[w.construction]
		local function gapOf(c)
			if g[c.entity] == nil then
				g[c.entity] = (w.footprint ~= nil and c.footprint ~= nil) and rules.gap(w.footprint, c.footprint) or 0
			end
			return g[c.entity]
		end
		table.sort(list, function(x, y)
			local gx, gy = gapOf(x), gapOf(y)
			if gx ~= gy then
				return gx < gy
			end
			return x.entity < y.entity
		end)
		cache.reach[w.construction] = list
		local kinds = {}
		for _, c in ipairs(list) do
			kinds[c.kind] = (kinds[c.kind] or 0) + 1
		end
		diag("warehouse %d (%s): %d buildings in reach (%d industries, %d town buildings; radius: %s)", w.construction,
			tostring(w.name), #list, kinds["industry"] or 0, kinds["town building"] or 0, how[w.construction] or "off")
		cache.explained[w.construction] = nil
	end
	cache.reachAt = now
	cache.reachKey = reachKey(warehouses)
end

local function refresh(now)
	local stale = cache.warehousesAt == nil or now < cache.warehousesAt
		or now - cache.warehousesAt >= day() / CONFIG.warehouseRefreshPerDay
	if stale then
		options = readOptions()
		readWarehouses(now)
	end
	if cache.reach == nil or now < cache.reachAt or now - cache.reachAt >= CONFIG.reachRefreshDays * day()
			or cache.reachKey ~= reachKey(cache.warehouses) then
		readReach(cache.warehouses, now)
	end
	return cache.warehouses
end

---------------------------------------------------------------------------
-- Moving cargo
---------------------------------------------------------------------------

local function stockCommand()
	local d = field(api.cmd, "debug") or field(api.cmd, "Debug")
	return (d ~= nil and field(d, "makeStockSetCargoAmountCmd")) or field(api.cmd, "makeStockSetCargoAmountCmd")
end

local function setAmount(stockList, stockId, amount, name)
	api.cmd.sendCommand(stockCommand()(stockList, stockId, amount, name))
end

-- counts of every stock of a stock list: "stockId:cargo" for the given
-- cargo types and "stockId:all" for the total
local function snapshot(stockList, types)
	local snap = {}
	for i in ipairs(stocksOf(stockList)) do
		local sid = i - 1
		for c in pairs(types) do
			snap[sid .. ":" .. c] = countOf(stockList, sid, c)
		end
		snap[sid .. ":all"] = totalOf(stockList, sid)
	end
	return snap
end

-- what changed between two snapshots: key -> difference
local function changes(before, after)
	local d = {}
	for k, v in pairs(after) do
		local delta = v - (before[k] or 0)
		if delta ~= 0 then
			d[k] = delta
		end
	end
	for k, v in pairs(before) do
		if after[k] == nil and v ~= 0 then
			d[k] = -v
		end
	end
	return d
end

-- true if the only change is `delta` items of `c` in stock `sid`
local function onlyChange(d, sid, c, delta)
	for k, v in pairs(d) do
		if not ((k == sid .. ":" .. c or k == sid .. ":all") and v == delta) then
			return false
		end
	end
	return d[sid .. ":" .. c] == delta
end

local function describe(d)
	local parts = {}
	for k, v in pairs(d) do
		table.insert(parts, k .. " " .. (v > 0 and "+" or "") .. v)
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- the spellings of cargo type c, the one that worked before first
local function namesFor(s, c)
	local names = rules.cargoNames(cargoName(c))
	local form = s.nameForm
	if form ~= nil and names[form] ~= nil then
		local out = { names[form] }
		for i, n in ipairs(names) do
			if i ~= form then
				table.insert(out, n)
			end
		end
		return out, names
	end
	return names, names
end

local function formOf(names, name)
	for i, n in ipairs(names) do
		if n == name then
			return i
		end
	end
	return nil
end

-- the cargo types a snapshot counted
local function typesIn(snap)
	local types = {}
	for key in pairs(snap) do
		local c = string.match(key, ":(%d+)$")
		if c ~= nil then
			types[tonumber(c)] = true
		end
	end
	return types
end

-- puts the counts of `before` back where `after` differs, spelling the cargo
-- types in the form `form` (index into rules.cargoNames); true if it worked
local function restore(stockList, before, after, form)
	for key in pairs(changes(before, after)) do
		local sid, c = string.match(key, "^(%d+):(%d+)$")
		if sid ~= nil then
			sid, c = tonumber(sid), tonumber(c)
			local names = rules.cargoNames(cargoName(c))
			setAmount(stockList, sid, before[key], names[form] or names[1])
		end
	end
	return next(changes(before, snapshot(stockList, typesIn(before)))) == nil
end

-- Moves `t.amount` items of t.supply.cargo from the warehouse stock to the
-- building's input stock. Returns the number of items the building got, the
-- SimCargo of the items that left the warehouse and the items that arrived
-- at the building (entities); or nil and a failure:
-- "noeffect" (the command changed nothing), "refused" (the building took
-- nothing; the warehouse got its cargo back) or "unsafe" (something else
-- changed; it was undone if possible).
local function move(s, w, t, warehouseTypes)
	local c = t.supply.cargo
	local wsl, wsid = w.stockList, t.supply.stockId
	local csl, csid = t.demand.stockList, t.demand.stockId
	local before = snapshot(wsl, warehouseTypes)
	local have = before[wsid .. ":" .. c] or 0
	local k = math.min(t.amount, have)
	if k <= 0 then
		return 0, {}
	end
	local items = options.payment > 0 and itemsIn(wsl, wsid) or {}

	-- 1. take k items out of the warehouse, trying the spellings of the cargo type
	local names, all = namesFor(s, c)
	local used = nil
	for _, name in ipairs(names) do
		setAmount(wsl, wsid, have - k, name)
		local after = snapshot(wsl, warehouseTypes)
		local d = changes(before, after)
		if next(d) ~= nil then
			if onlyChange(d, wsid, c, -k) then
				used = name
				break
			end
			local undone = restore(wsl, before, after, formOf(all, name))
			return nil, "unsafe", string.format("taking %d %s from warehouse stock %d with \"%s\" changed: %s%s",
				k, cargoName(c), wsid, name, describe(d), undone and " (undone)" or " (could not undo)")
		end
	end
	if used == nil then
		return nil, "noeffect", string.format("the stock command changed nothing (cargo %s, tried %s)",
			cargoName(c), table.concat(names, ", "))
	end
	s.nameForm = formOf(all, used)

	-- 2. give them to the building
	local consumerTypes = { [c] = true }
	local cItems = options.payment > 0 and itemsIn(csl, csid) or {}
	local cBefore = snapshot(csl, consumerTypes)
	local m = cBefore[csid .. ":" .. c] or 0
	setAmount(csl, csid, m + k, used)
	local cAfter = snapshot(csl, consumerTypes)
	local cd = changes(cBefore, cAfter)
	local got = cd[csid .. ":" .. c] or 0
	local ok = true
	for key, v in pairs(cd) do
		if not ((key == csid .. ":" .. c or key == csid .. ":all") and v >= 0 and v <= k) then
			ok = false
		end
	end
	if not ok then
		local undone = restore(csl, cBefore, cAfter, s.nameForm)
		local back = countOf(wsl, wsid, c) + k
		setAmount(wsl, wsid, back, used)
		undone = undone and countOf(wsl, wsid, c) == back
		return nil, "unsafe", string.format("giving %d %s to stock %d of %d changed: %s%s",
			k, cargoName(c), csid, csl, describe(cd), undone and " (undone)" or " (could not undo)")
	end

	-- 3. what the building didn't take goes back into the warehouse
	if got < k then
		local now = countOf(wsl, wsid, c)
		setAmount(wsl, wsid, now + (k - got), used)
		if countOf(wsl, wsid, c) ~= now + (k - got) then
			return nil, "unsafe", string.format("could not put %d %s back into warehouse stock %d",
				k - got, cargoName(c), wsid)
		end
		if got == 0 then
			return nil, "refused", string.format("stock %d of %d took no %s", csid, csl, cargoName(c))
		end
	end

	-- the items that left the warehouse and those that arrived, for the payment
	local left, arrived = {}, {}
	if options.payment > 0 then
		local still = itemsIn(wsl, wsid)
		local ids = {}
		for e, sc in pairs(items) do
			if still[e] == nil and sc.cargoType == c then
				table.insert(ids, e)
			end
		end
		table.sort(ids)
		for i = 1, math.min(got, #ids) do
			table.insert(left, items[ids[i]])
		end
		for e, sc in pairs(itemsIn(csl, csid)) do
			if cItems[e] == nil and sc.cargoType == c then
				table.insert(arrived, e)
			end
		end
		table.sort(arrived)
	end
	return got, left, arrived
end

---------------------------------------------------------------------------
-- The game's own price calculation
---------------------------------------------------------------------------

-- What the base game pays for delivering a cargo item (wiki, Modding Manual
-- > Misc > Cargos; the OnCalcTicketPrice event):
--
--   base price = income function of the cargo type (its params, time since
--                pickup) x distance x a constant (difficulty)
--   paid       = base price x what the game scripts answer to
--                OnCalcTicketPrice: the company rank's ticket price
--                multiplier and subsidy bonuses
--
-- The mod calls the same code: each cargo type's income function (its
-- resource's scriptRef, resolved with the game's util.useFn like the game
-- resolves script references), and the handlers of the base game's scripts
-- that answer OnCalcTicketPrice (company progression, subsidies), with a
-- made-up event for the cargo handed out and a throw-away copy of their
-- state, so nothing changes in them. The company rank's multiplier is also
-- read from company_progression_util if its handler can't be called.
--
-- Two numbers aren't exposed and are measured from the game's own
-- deliveries: the constant, and the unit of the event's distance (the
-- event's distance against the mod's own measure). The formula is only used
-- once the constant agrees across deliveries (CONFIG.maxCalibrationDeviation),
-- which shows it explains the game's prices. Until then, or if a cargo
-- type's income function can't be called, the price per distance learned
-- for the cargo type is used, which misses the effect of time.

-- per Lua state: what was found of the game's code (false: tried, not there)
local game = { util = nil, income = {}, scripts = nil, progression = nil }

local function gameRequire(paths)
	for _, path in ipairs(paths) do
		local ok, m = pcall(ug_require, path)
		if ok and type(m) == "table" then
			return m
		end
	end
	return nil
end

-- resolves a script reference "file@function.path" with the game's util.useFn
local function useFn(ref)
	if game.util == nil then
		local util = gameRequire({ "::/scripts/util.tl", "::/scripts/util.lua", "::/scripts/util" })
		game.util = (util ~= nil and field(util, "useFn") ~= nil) and util or false
	end
	if not game.util then
		return nil
	end
	local ok, f = pcall(game.util.useFn, ref)
	if ok and f ~= nil then
		return f
	end
	return nil
end

local function positive(v, max)
	return type(v) == "number" and v == v and v > 0 and v <= (max or math.huge) and v < math.huge
end

-- the income function of cargo type c at time t (ms since pickup), as its
-- resource names it; nil if it can't be called
local function incomeFactor(c, t)
	local entry = game.income[c]
	if entry == nil then
		entry = false
		local ok, ct = pcall(apiFn("res", "cargoTypeRep", "get"), c)
		local ref = ok and ct ~= nil and field(ct, "scriptRef") or nil
		local file = ref ~= nil and field(ref, "fileName") or nil
		local fn = type(file) == "string" and file ~= "" and useFn(file) or nil
		if fn ~= nil then
			entry = { fn = fn, params = field(ref, "params"), ref = file }
		end
		game.income[c] = entry
	end
	if not entry or t == nil then
		return nil
	end
	local ok, v = pcall(entry.fn, entry.params, t)
	if ok and positive(v) then
		return v
	end
	return nil
end

-- Time since pickup in ms, as the income function takes it. "frozen" leaves
-- out the time a specialized warehouse froze the delivery timer
-- (SimCargo.deliveryExtensionDuration), "raw" counts it. Which one the game
-- uses is measured: the right one makes the constant agree.
local AGES = { "frozen", "raw" }

local function ageOf(sc, now, how)
	local pickup = field(sc, "pickupTime")
	if type(pickup) ~= "number" or pickup < 0 or pickup > now then
		return nil
	end
	local t = now - pickup
	if how == "frozen" then
		local ext = field(sc, "deliveryExtensionDuration")
		if type(ext) == "number" and ext > 0 then
			t = t - ext
		end
	end
	return math.max(0, t)
end

local function copyOf(v, seen)
	if type(v) ~= "table" then
		return v
	end
	seen = seen or {}
	if seen[v] ~= nil then
		return seen[v]
	end
	local out = {}
	seen[v] = out
	for k, x in pairs(v) do
		out[copyOf(k, seen)] = copyOf(x, seen)
	end
	return out
end

-- base game scripts that answer OnCalcTicketPrice: the name of their game
-- script (its state) and spellings of their event handler
local PRICE_SCRIPTS = {
	{
		key = "company",
		gs = "::/game_mechanics/company/company_progression.gs",
		handlers = {
			"::/game_mechanics/company/company_growth.script@handleEvent",
			"::/game_mechanics/company/company_progression.script@handleEvent",
		},
	},
	{
		key = "subsidies",
		gs = "::/game_mechanics/subventions/subventions.gs",
		handlers = { "::/game_mechanics/subventions/subventions.script@handleEvent" },
	},
}

-- the handler a game script's resource names, resolved next to its .gs file
local function handlerFromResource(gs)
	local ok, id = pcall(apiFn("res", "gameScriptRep", "find"), gs)
	if not ok or type(id) ~= "number" or id < 0 then
		return nil
	end
	local okDesc, desc = pcall(apiFn("res", "gameScriptRep", "getAsTable"), id)
	local ref = okDesc and desc ~= nil and field(field(desc, "handleEventScript") or {}, "fileName") or nil
	if type(ref) ~= "string" or ref == "" then
		return nil
	end
	if string.find(ref, "::", 1, true) == nil then
		ref = (string.match(gs, "^(.*/)") or "") .. ref
	end
	return useFn(ref), ref
end

local function priceScripts()
	if game.scripts == nil then
		game.scripts = {}
		for _, p in ipairs(PRICE_SCRIPTS) do
			local fn, ref = handlerFromResource(p.gs)
			for _, r in ipairs(p.handlers) do
				if fn ~= nil then
					break
				end
				fn, ref = useFn(r), r
			end
			if fn ~= nil then
				table.insert(game.scripts, { key = p.key, gs = p.gs, fn = fn, ref = ref })
			end
			diag("game price script %s: %s", p.key, fn ~= nil and ("handler " .. tostring(ref)) or "not found")
		end
	end
	return game.scripts
end

local function scriptState(gs)
	local ok, e = pcall(apiFn("engine", "system", "gameScriptSystem", "getEntityForGameScript"), gs)
	local c = ok and comp(e, field(CT(), "GAME_SCRIPT")) or nil
	local st = c ~= nil and field(c, "state") or nil
	if type(st) == "table" then
		return st
	end
	local okId, id = pcall(apiFn("res", "gameScriptRep", "find"), gs)
	if okId and type(id) == "number" and id >= 0 then
		local okGet, res = pcall(apiFn("res", "gameScriptRep", "get"), id)
		local okState, s = false, nil
		if okGet and res ~= nil then
			okState, s = pcall(function()
				return res:getState()
			end)
		end
		if okState and type(s) == "table" then
			return s
		end
	end
	return nil
end

-- Runs fn with api.cmd.sendCommand replaced by a function that drops the
-- command, so that asking a game script can't change the game. Returns
-- false if sendCommand can't be replaced (fn is not run then).
local function withoutCommands(fn)
	local cmd = api.cmd
	local real = field(cmd, "sendCommand")
	local dropped = 0
	local replaced = pcall(function()
		cmd.sendCommand = function()
			dropped = dropped + 1
		end
	end)
	if not replaced or field(cmd, "sendCommand") == real then
		pcall(function()
			cmd.sendCommand = real
		end)
		return false
	end
	local ok, result = pcall(fn)
	pcall(function()
		cmd.sendCommand = real
	end)
	if field(cmd, "sendCommand") ~= real then
		error("could not restore api.cmd.sendCommand")
	end
	if dropped > 0 and not game.droppedLogged then
		game.droppedLogged = true
		diag("a game price script sent %d commands while asked about a price; they were dropped (logged once)", dropped)
	end
	return true, ok, result
end

-- What the base game's price scripts answer for `entries` (OnCalcTicketPrice
-- entries): list of answers (index -> multiplier). Also says which scripts answered.
local function askPriceScripts(entries)
	local answers, asked = {}, {}
	for _, script in ipairs(priceScripts()) do
		local st = scriptState(script.gs)
		if st ~= nil then
			local fake = {
				value = copyOf(st),
				get = function(self)
					return self.value
				end,
				get_native = function(self)
					return self.value
				end,
				set = function() end,
				set_native = function() end,
				hasEventSubscriptions = function()
					return true
				end,
				subscribeToEvent = function() end,
				subscribeToAllEvents = function() end,
				subscribeToNoEvents = function() end,
			}
			local run, ok, answer = withoutCommands(function()
				return script.fn({}, fake, "", "TransportVehicleSystem", "OnCalcTicketPrice", entries)
			end)
			if run and ok then
				table.insert(answers, type(answer) == "table" and answer or {})
				asked[script.key] = true
			elseif run then
				report("price " .. script.key, "could not ask the game's " .. script.key .. " script about a price: " .. tostring(answer))
			else
				report("block", "can't block commands while asking the game's price scripts; leaving them out")
			end
		end
	end
	return answers, asked
end

-- the company rank's ticket price multiplier, from company_progression_util
local function companyMultiplier()
	if game.progression == nil then
		game.progression = gameRequire({ "::/game_mechanics/company/company_progression_util.tl",
			"::/game_mechanics/company/company_progression_util.lua" }) or false
	end
	if not game.progression then
		return nil
	end
	local ok, data = pcall(game.progression.getCompanyProgressionState, api.engine.util.getPlayer())
	local m = ok and data ~= nil and field(data, "ticketPriceMultiplier") or nil
	return positive(m, 10) and m or nil
end

-- distance unit of the game's price events per metre of the mod's measure;
-- nil while unknown (the game reported distances, but none could be compared yet)
local function unitOf(s)
	if s.unit ~= nil and s.unit.value ~= nil then
		return s.unit.value
	end
	if s.sawEventDistance then
		return nil
	end
	return 1
end

-- the base price (before multipliers) of a cargo item handed out over
-- `d` metres now; nil if it isn't known yet. Also says how it was found.
local function basePriceOf(s, c, sc, d, now)
	local unit = unitOf(s)
	if unit == nil then
		return nil
	end
	local cal, how = rules.bestCalibration(s.calibration, CONFIG.minCalibrationSamples, CONFIG.maxCalibrationDeviation)
	if cal ~= nil then
		local f = incomeFactor(c, ageOf(sc, now, how))
		if f ~= nil then
			return cal.value * f * d * unit, "game formula (" .. how .. ")"
		end
	end
	local rate = rules.rateFor(s.rates, c)
	if rate ~= nil then
		return rate * d * unit, "learned price per distance"
	end
	return nil
end

---------------------------------------------------------------------------
-- Payment
---------------------------------------------------------------------------

local function journalCarrier(vehicle)
	local tv = comp(vehicle, CT().TRANSPORT_VEHICLE)
	if tv == nil then
		return nil
	end
	local c = api.type["enum"].Carrier
	local j = api.type.JournalEntry.Carrier
	for _, name in ipairs({ "ROAD", "RAIL", "TRAM", "AIR", "WATER" }) do
		local from = field(c, name)
		if from ~= nil and from == tv.carrier then
			return field(j, name) or field(j, "OTHER")
		end
	end
	return field(j, "OTHER")
end

local function book(account, amount, carrier, at)
	local entry = api.type.JournalEntry.new()
	entry.amount = amount
	entry.time = -1
	entry.category.type = api.type.JournalEntry.Type.INCOME
	if carrier ~= nil then
		entry.category.carrier = carrier
	end
	local pos = at ~= nil and api.type.Vec3f.new(at.x, at.y, at.z or 0) or api.type.Vec3f.new(0, 0, 0)
	api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(account, entry, pos))
end

-- Notes the money for cargo that `w` handed to `consumer`: `left` are the
-- SimCargo of the items that left the warehouse, `arrived` the items the
-- building got (they stand in for them in the price scripts' event).
local function charge(s, w, consumer, c, left, arrived, now)
	-- a building whose position is unknown is within reach of the warehouse: measure to the warehouse
	local at = consumer.footprint or w.footprint
	if at == nil then
		report("nopos", "can't price cargo handed out: neither the warehouse's nor the building's position is known")
		return
	end
	local to = spot(at)
	local from0 = w.footprint ~= nil and spot(w.footprint) or to
	local items, entries = {}, {}
	for i, sc in ipairs(left) do
		local d = rules.paidDistance(originOf(sc) or from0, to)
		local line, vehicle = lastCarrierOf(sc)
		local base, how = basePriceOf(s, c, sc, d, now)
		items[i] = { d = d, line = line, vehicle = vehicle, base = base, how = how }
		local unit = unitOf(s) or 1
		entries[i] = {
			vehicleEntity = vehicle,
			lineEntity = line,
			simEntity = arrived[i] or arrived[#arrived] or -1,
			stockListEntity = consumer.stockList,
			basePrice = base or 0,
			distance = d * unit,
		}
	end
	if #items == 0 then
		return
	end

	-- multipliers: the game's price scripts, else the company rank alone
	local answers, asked = askPriceScripts(entries)
	local company = nil
	if not asked.company then
		company = companyMultiplier()
	end

	local total, n = 0, 0
	local hows = {}
	for i, it in ipairs(items) do
		local m = rules.combine(answers, i, CONFIG.maxMultiplier) * (company or 1) * options.payment
		if asked.company and not valid(it.line) then
			-- the company script answers for the player's lines; an item with no
			-- known line still pays the rank's multiplier
			m = m * (companyMultiplier() or 1)
		end
		if it.base == nil then
			-- price not known yet: keep the distance, with the multipliers of now
			s.owed[c] = (s.owed[c] or 0) + it.d * m
		else
			local amount = it.base * m
			local u = s.unbooked[w.construction]
			if u == nil then
				u = { amount = 0, since = now, vehicles = {} }
				s.unbooked[w.construction] = u
			end
			local g = u.vehicles[it.vehicle]
			if g == nil then
				g = { line = it.line, amount = 0 }
				u.vehicles[it.vehicle] = g
			end
			g.amount = g.amount + amount
			u.amount = u.amount + amount
			total, n = total + amount, n + 1
			hows[it.how] = true
		end
	end
	if n > 0 then
		local parts = {}
		for h in pairs(hows) do
			table.insert(parts, h)
		end
		table.sort(parts)
		local scripts = {}
		for k in pairs(asked) do
			table.insert(scripts, k)
		end
		table.sort(scripts)
		diag("price of %d %s handed out: %.0f (%s; multipliers from %s%s)", n, cargoName(c), total,
			table.concat(parts, ", "), #scripts > 0 and table.concat(scripts, ", ") or "no game script",
			company ~= nil and string.format(", company rank x%.3f", company) or "")
	end
end

-- distances owed for cargo types whose price is known now
local function settleOwed(s, now)
	local unit = unitOf(s)
	if unit == nil then
		return
	end
	for c, d in pairs(s.owed) do
		local rate = rules.rateFor(s.rates, c)
		if rate ~= nil then
			local u = s.unbooked[0]
			if u == nil then
				u = { amount = 0, since = now, vehicles = {} }
				s.unbooked[0] = u
			end
			u.amount = u.amount + d * rate * unit
			s.owed[c] = nil
			diag("paying %.0f m of %s handed out before its price was known", d, cargoName(c))
		end
	end
end

-- books the money of warehouses whose last delivery is a day old
local function flush(s, now, warehouseByKey)
	local finite = api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer()) ~= nil
	local done = {}
	for key, u in pairs(s.unbooked) do
		if now - u.since >= CONFIG.bookAfterDays * day() or now < u.since or (key ~= 0 and warehouseByKey[key] == nil) then
			table.insert(done, key)
			local total = u.amount + (s.pending or 0)
			local amount = math.floor(total)
			s.pending = total - amount
			if amount > 0 and finite then
				local w = warehouseByKey[key]
				-- shown above the warehouse, as income of the carrier that brought most of it
				local main, mainAmount = nil, -1
				for vehicle, g in pairs(u.vehicles) do
					if g.amount > mainAmount and exists(vehicle) then
						main, mainAmount = vehicle, g.amount
					end
				end
				local at = w ~= nil and w.footprint ~= nil and rules.centre(w.footprint) or nil
				if at ~= nil then
					at.z = w.footprint.z or 0
				end
				book(api.engine.util.getPlayer(), amount, main ~= nil and journalCarrier(main) or nil, at)
				if CONFIG.bookOnVehicle then
					for vehicle, g in pairs(u.vehicles) do
						-- statistics only: rounded, the player's money carries its fractions
						local a = math.floor(g.amount + 0.5)
						local carrier = journalCarrier(vehicle)
						if a > 0 and carrier ~= nil then
							if exists(g.line) then
								book(g.line, a, carrier, nil)
							end
							book(vehicle, a, carrier, nil)
						end
					end
				end
				s.paid = (s.paid or 0) + amount
				diag("income %d for cargo handed out by warehouse %d", amount, key)
			end
		end
	end
	for _, key in ipairs(done) do
		s.unbooked[key] = nil
	end
end

-- Measures the game's prices from its own cargo deliveries: the unit of the
-- event's distance, the price per distance of each cargo type, and the
-- constant of the formula for each way of counting time.
local function learn(s, entries, now)
	local changed = false
	for _, p in ipairs(entries) do
		local sl, sim = field(p, "stockListEntity"), field(p, "simEntity")
		local price, e = field(p, "basePrice"), field(p, "distance")
		local sc = valid(sl) and comp(sim, CT().SIM_CARGO) or nil
		if sc ~= nil and cargoType(sc.cargoType) and positive(price) then
			local c = sc.cargoType
			local from = originOf(sc)
			local dest = footprintOf(sl)
			local d = (from ~= nil and dest ~= nil) and rules.paidDistance(from, spot(dest)) or nil
			if positive(e) then
				s.sawEventDistance = true
				if d ~= nil and d >= CONFIG.minSampleDistance then
					s.unit = rules.calibrate(s.unit, e / d, CONFIG.unitSamples)
				end
			else
				e = nil
			end
			-- the delivery's distance in the event's unit: the game's own, else ours converted
			local dist = e
			if dist == nil and d ~= nil and d >= CONFIG.minSampleDistance then
				dist = d * (unitOf(s) or 1)
			end
			if dist ~= nil then
				local before = s.rates[c]
				s.rates[c], s.rateSamples[c] = rules.learnRate(s.rates[c], s.rateSamples[c], price / dist, CONFIG.rateSamples)
				local ks = {}
				for _, how in ipairs(AGES) do
					local f = incomeFactor(c, ageOf(sc, now, how))
					if f ~= nil then
						s.calibration[how] = rules.calibrate(s.calibration[how], price / (f * dist), CONFIG.calibrationSamples)
						table.insert(ks, string.format("%s %.4g (spread %.1f%%)", how, s.calibration[how].value,
							100 * s.calibration[how].dev))
					end
				end
				changed = true
				if before == nil or diagCount < CONFIG.diagnosticsLimit / 2 then
					diag("game delivery of %s: base price %.1f for distance %.4g (%s m measured); constant: %s",
						cargoName(c), price, dist, d ~= nil and string.format("%.0f", d) or "not",
						#ks > 0 and table.concat(ks, ", ") or "income function not found")
				end
			end
		end
	end
	return changed
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function newState(now)
	return {
		version = 1,
		lastTick = now,
		verified = false,
		nameForm = nil,
		disabled = nil,
		budget = {},
		rates = {},
		rateSamples = {},
		calibration = {},
		unit = nil,
		sawEventDistance = false,
		owed = {},
		unbooked = {},
		pending = 0,
		moved = 0,
		paid = 0,
	}
end

-- the script state; true as second result if it is new (not saved yet)
local function readState(state, now)
	local s = state:get()
	local fresh = false
	if type(s) ~= "table" or s.version == nil then
		s = newState(now)
		fresh = true
	end
	for _, k in ipairs({ "budget", "rates", "rateSamples", "calibration", "owed", "unbooked" }) do
		if type(s[k]) ~= "table" then
			s[k] = {}
		end
	end
	return s, fresh
end

local function disable(s, now, kind, reason)
	s.disabled = { kind = kind, reason = reason, at = now, revision = REVISION }
	debugPrint(TAG .. " stopped: " .. reason)
	if kind == "noeffect" then
		debugPrint(TAG .. " The game did not apply api.cmd.debug.makeStockSetCargoAmountCmd. If Debug Mode is off "
			.. "(Settings > Advanced), turn it on and load the game again; the mod also tries again in a year.")
	else
		debugPrint(TAG .. " To be safe the mod stays off in this game. Please report this line and the one above.")
	end
end

-- true if the mod may distribute; clears a stop that may retry
local function active(s, now)
	local d = s.disabled
	if d == nil then
		return true
	end
	if d.revision ~= REVISION or (d.kind == "noeffect" and (now - d.at >= CONFIG.retryAfterYears * year() or now < d.at)) then
		s.disabled = nil
		s.verified = false
		report("retry" .. tostring(d.at), "trying again after: " .. tostring(d.reason))
		return true
	end
	report("off" .. tostring(d.at), "is off in this game: " .. tostring(d.reason))
	return false
end

---------------------------------------------------------------------------
-- One distribution tick
---------------------------------------------------------------------------

local function refusedNow(stockList, stockId, now)
	local until_ = cache.refused[stockList .. ":" .. stockId]
	return until_ ~= nil and now < until_
end

-- the stocks of the buildings in reach that take cargo the warehouse holds
local function demandsFor(w, holds, now)
	local demands = {}
	for _, consumer in ipairs(cache.reach[w.construction] or {}) do
		for i, st in ipairs(stocksOf(consumer.stockList)) do
			local sid = i - 1
			if receives(consumer.kind, st) and not refusedNow(consumer.stockList, sid, now) then
				local wanted = {}
				for _, c in ipairs((acceptedCargo(consumer.stockList, sid, st, consumer))) do
					if holds[c] then
						table.insert(wanted, c)
					end
				end
				if #wanted > 0 then
					local capacity = st.capacity or 0
					local free = capacity - totalOf(consumer.stockList, sid)
					if free > 0 then
						for _, c in ipairs(wanted) do
							table.insert(demands, {
								cargo = c,
								free = free,
								capacity = capacity,
								pool = consumer.stockList .. ":" .. sid,
								stockList = consumer.stockList,
								stockId = sid,
								consumer = consumer,
							})
						end
					end
				end
			end
		end
	end
	return demands
end

-- the cargo a warehouse holds: list of { cargo, stockId, count }
local function supplyOf(w, now)
	local supply, holds = {}, {}
	for i in ipairs(stocksOf(w.stockList)) do
		local sid = i - 1
		local seen = {}
		local items = refusedNow(w.stockList, sid, now) and {} or itemsIn(w.stockList, sid)
		for _, sc in pairs(items) do
			local c = sc.cargoType
			if cargoType(c) and not seen[c] then
				seen[c] = true
				local n = countOf(w.stockList, sid, c)
				if n > 0 then
					table.insert(supply, { cargo = c, stockId = sid, count = n })
					holds[c] = true
				end
			end
		end
	end
	table.sort(supply, function(x, y)
		if x.stockId ~= y.stockId then
			return x.stockId < y.stockId
		end
		return x.cargo < y.cargo
	end)
	return supply, holds
end

-- one building's stocks as the mod sees them, for the diagnostics
local function describeConsumer(c)
	local parts = {}
	for i, st in ipairs(stocksOf(c.stockList)) do
		local sid = i - 1
		local takes, all = acceptedCargo(c.stockList, sid, st, c)
		local names = {}
		for _, x in ipairs(all) do
			local needed = false
			for _, y in ipairs(takes) do
				needed = needed or y == x
			end
			table.insert(names, cargoName(x) .. (needed and "" or " (not needed)"))
		end
		table.insert(parts, string.format("stock %d %s%s [%s] %d/%s%s", sid, stockTypeName(st),
			receives(c.kind, st) and "" or " (not filled)", table.concat(names, ", "), totalOf(c.stockList, sid),
			tostring(st.capacity), refusedNow(c.stockList, sid, gameTime()) and " (refused, skipped)" or ""))
	end
	return string.format("%s %d%s%s: %s", c.kind, c.entity, valid(c.town) and (" of town " .. c.town) or "",
		c.footprint == nil and " (position unknown)" or "", #parts > 0 and table.concat(parts, "; ") or "no stocks")
end

-- says once per search for buildings why a warehouse that holds cargo hands
-- none out: what its buildings in reach take, town buildings first
local function explainIdle(w, holds, why)
	if options == nil or not options.diagnostics or cache.explained[w.construction] then
		return
	end
	cache.explained[w.construction] = true
	local held = {}
	for c in pairs(holds) do
		table.insert(held, cargoName(c))
	end
	table.sort(held)
	local list = cache.reach[w.construction] or {}
	diag("warehouse %d holds %s but hands nothing out: %s", w.construction, table.concat(held, ", "), why)
	local shown = 0
	for _, kind in ipairs({ "town building", "industry" }) do
		for _, c in ipairs(list) do
			if c.kind == kind and shown < 8 then
				shown = shown + 1
				diag("  %s", describeConsumer(c))
			end
		end
	end
end

local function distribute(s, w, now, dt)
	local perMonth = options.perMonth
	local cap = math.min(CONFIG.maxItemsPerTick, math.max(1, perMonth * CONFIG.budgetCapMonths))
	local perMs = perMonth == math.huge and math.huge or perMonth / month()
	local budget = rules.addBudget(s.budget[w.construction], perMs, dt, cap)
	s.budget[w.construction] = budget
	local n = math.floor(budget)
	if not s.verified then
		-- the first move of a game is a single item
		n = math.min(n, 1)
	end
	if n < 1 or not rules.selected(w.name, options.onlyTagged) then
		return true
	end
	local supply, holds = supplyOf(w, now)
	if #supply == 0 then
		return true
	end
	local demands = demandsFor(w, holds, now)
	if #demands == 0 then
		explainIdle(w, holds, #(cache.reach[w.construction] or {}) == 0 and "no buildings in reach"
			or "no building in reach has room for what it holds")
		return true
	end
	local plan = rules.plan(supply, demands, n)
	for _, t in ipairs(plan) do
		local got, left, why = move(s, w, t, holds)
		local arrived = why
		if got == nil then
			if left == "refused" or (left == "noeffect" and s.verified) then
				-- the command worked elsewhere, so this stock won't take part: the
				-- building's (refused) or the warehouse's (no effect); leave it alone for a while
				local key = left == "refused" and (t.demand.stockList .. ":" .. t.demand.stockId)
					or (w.stockList .. ":" .. t.supply.stockId)
				cache.refused[key] = now + CONFIG.refusedDays * day()
				diag("skipping stock %s for %d days: %s", key, CONFIG.refusedDays, tostring(why))
			else
				disable(s, now, left, why)
				return false
			end
		elseif got > 0 then
			s.verified = true
			s.moved = (s.moved or 0) + got
			s.budget[w.construction] = math.max(0, s.budget[w.construction] - got)
			if options.payment > 0 then
				local okCharge, err = pcall(charge, s, w, t.demand.consumer, t.supply.cargo, left, arrived, now)
				if not okCharge then
					report("charge", "error while pricing cargo handed out (it is not paid): " .. tostring(err))
				end
			end
			diag("warehouse %d -> %s %d (stock %d): %d %s", w.construction, t.demand.consumer.kind,
				t.demand.consumer.entity, t.demand.stockId, got, cargoName(t.supply.cargo))
		end
	end
	return true
end

local function tick(s, now, dt)
	local warehouses = refresh(now)
	local byKey = {}
	for _, w in ipairs(warehouses) do
		byKey[w.construction] = w
	end
	-- forget the budgets of removed warehouses
	for key in pairs(s.budget) do
		if byKey[key] == nil then
			s.budget[key] = nil
		end
	end
	if active(s, now) and stockCommand() ~= nil then
		for _, w in ipairs(warehouses) do
			if not distribute(s, w, now, dt) then
				break
			end
		end
	elseif stockCommand() == nil then
		report("nocommand", "this game version has no makeStockSetCargoAmountCmd; the mod does nothing")
	end
	if next(s.owed) ~= nil then
		settleOwed(s, now)
	end
	if next(s.unbooked) ~= nil then
		flush(s, now, byKey)
	end
end

---------------------------------------------------------------------------
-- Game script
---------------------------------------------------------------------------

local M = {}

-- game time this Lua state may skip to; only saves reading the state on
-- every update
local nextCheck = nil

function M.update(_userParams, state, dt)
	if not state:hasEventSubscriptions() then
		state:subscribeToEvent("OnCalcTicketPrice")
	end
	if dt == 0 then
		return nil
	end
	local ok, err = pcall(function()
		local now = gameTime()
		local interval = day() / CONFIG.ticksPerDay
		if nextCheck ~= nil and now < nextCheck and nextCheck - now <= interval then
			return
		end
		local s, fresh = readState(state, now)
		if fresh then
			-- first update with the mod: start the clock
			state:set(s)
		end
		local last = s.lastTick or now
		if now >= last and now - last < interval then
			nextCheck = last + interval
			return
		end
		if options == nil then
			options = readOptions()
		end
		-- after a long pause or a jump back in time, don't make up for lost time
		local elapsed = math.min(math.max(0, now - last), day())
		s.lastTick = now
		nextCheck = now + interval
		-- cargo moved before an error must still be counted: save the state either way
		local okTick, err = pcall(tick, s, now, elapsed)
		state:set(s)
		if not okTick then
			error(err, 0)
		end
	end)
	if not ok then
		report("error", "error: " .. tostring(err))
	end
	return nil
end

-- the entries of an event's list, read by index so that engine objects
-- (userdata) work as well as Lua tables; a single entry is a list of one
local function entriesOf(param)
	if field(param, "basePrice") ~= nil then
		return { param }
	end
	local out = {}
	local i = 1
	while true do
		local p = field(param, i)
		if p == nil then
			break
		end
		out[i] = p
		i = i + 1
	end
	return out
end

function M.handleEvent(_userParams, state, _src, id, name, param)
	if name ~= "OnCalcTicketPrice" or (type(param) ~= "table" and type(param) ~= "userdata") then
		return nil
	end
	local ok, err = pcall(function()
		local entries = entriesOf(param)
		local cargo = false
		for _, p in ipairs(entries) do
			if field(p, "stockListEntity") ~= nil then
				cargo = true
				break
			end
		end
		if not cargo then
			return
		end
		if next(ownerOfStockList) == nil then
			-- the destinations' positions are needed to measure the delivery
			readConsumers()
		end
		local s = readState(state, gameTime())
		if options == nil then
			options = readOptions()
		end
		if learn(s, entries, gameTime()) then
			state:set(s)
		end
	end)
	if not ok then
		report("error", "error: " .. tostring(err))
	end
	-- never changes the price
	return nil
end

-- exposed for tests
M.CONFIG = CONFIG
M.REVISION = REVISION
M._reset = function()
	options = nil
	diagCount = 0
	reported = {}
	ownerOfStockList = {}
	passengerCargo = nil
	stockTypes = nil
	townNeedsCache = {}
	personCapacityOwners = nil
	nextCheck = nil
	cache.warehouses, cache.warehousesAt = nil, nil
	cache.reach, cache.reachAt, cache.reachKey = nil, nil, nil
	cache.consumers, cache.refused, cache.explained = {}, {}, {}
end

function data()
	return M
end

return M
