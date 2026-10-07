-- Warehouse Distribution: rules without game API, so they can be tested
-- outside the game. Loaded by warehouse_distribution.script.lua with
-- require("/warehouse_distribution/rules.lua").
--
-- Written for the game's Lua 5.2 sandbox (no unpack, rawget, goto or //).

local rules = {}

---------------------------------------------------------------------------
-- Mod options
---------------------------------------------------------------------------

-- The value of a mod option. The game hands options to scripts as 1-based
-- indices into the option's values (the mod.json defaultIndex is 0-based).
-- `params` is api.engine.config.getModParams(): mod id -> key -> index. The
-- keys of this mod are unique, so they are found regardless of how the game
-- names the mod in that table.
function rules.option(params, key, values, defaultIndex)
	local index = defaultIndex
	for _, modParams in pairs(params or {}) do
		local v = type(modParams) == "table" and modParams[key] or nil
		if type(v) == "number" then
			index = math.floor(v)
		end
	end
	if index < 1 then
		index = 1
	elseif index > #values then
		index = #values
	end
	return values[index]
end

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

-- Horizontal gap between two footprints (axis-aligned boxes with x0, y0,
-- x1, y1); 0 if they overlap. A building is in reach of a warehouse if any
-- part of it is within the radius of any part of the warehouse.
function rules.gap(a, b)
	local dx = math.max(0, math.max(a.x0, b.x0) - math.min(a.x1, b.x1))
	local dy = math.max(0, math.max(a.y0, b.y0) - math.min(a.y1, b.y1))
	return math.sqrt(dx * dx + dy * dy)
end

function rules.centre(f)
	return { x = (f.x0 + f.x1) * 0.5, y = (f.y0 + f.y1) * 0.5, z = f.z or 0 }
end

-- Distance a cargo item is paid for, like the base game: the aerial distance
-- between pickup and drop-off, plus eight times the height difference if the
-- drop-off is higher (wiki: Modding Manual > Misc > Cargos).
function rules.paidDistance(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	local d = math.sqrt(dx * dx + dy * dy)
	local dz = (to.z or 0) - (from.z or 0)
	if dz > 0 then
		d = d + 8 * dz
	end
	return d
end

---------------------------------------------------------------------------
-- Allocation
---------------------------------------------------------------------------

-- Plans which cargo goes where.
--
-- `supply`: list of { cargo, stockId, count }, one per warehouse stock and
-- cargo type it holds.
-- `demands`: list of { cargo, free, capacity, pool, ... }, one per input
-- stock of a building in reach and cargo type it takes. `free` is how many
-- more items it takes. Demands with the same `pool` (one stock that takes
-- several cargo types) share their free space.
-- `budget`: how many items may move.
--
-- Items go one by one to the emptiest stock (lowest fill), so a small budget
-- is shared fairly instead of going to the first building found. Ties go to
-- the stock listed first. Returns a list of { supply = s, demand = d,
-- amount = n } with amount > 0, and the number of items planned.
function rules.plan(supply, demands, budget)
	local left = {}
	local byCargo = {}
	for i, s in ipairs(supply) do
		left[i] = s.count
		local list = byCargo[s.cargo]
		if list == nil then
			list = {}
			byCargo[s.cargo] = list
		end
		table.insert(list, i)
	end
	-- free space and items already in, per pool (a demand without a pool is its own)
	local poolOf, free, filled = {}, {}, {}
	for j, d in ipairs(demands) do
		local p = d.pool or ("#" .. j)
		poolOf[j] = p
		if free[p] == nil then
			free[p] = d.free
			filled[p] = math.max(0, (d.capacity or d.free) - d.free)
		end
	end

	local amounts = {}
	local planned = 0
	while planned < budget do
		-- the emptiest stock that still takes cargo and has some in supply
		local best, bestFill, bestSource = nil, nil, nil
		for j, d in ipairs(demands) do
			local p = poolOf[j]
			if free[p] > 0 then
				local source = nil
				for _, i in ipairs(byCargo[d.cargo] or {}) do
					if left[i] > 0 and (source == nil or left[i] > left[source]) then
						source = i
					end
				end
				if source ~= nil then
					local capacity = d.capacity or 0
					local fill = capacity > 0 and filled[p] / capacity or filled[p]
					if best == nil or fill < bestFill then
						best, bestFill, bestSource = j, fill, source
					end
				end
			end
		end
		if best == nil then
			break
		end
		left[bestSource] = left[bestSource] - 1
		free[poolOf[best]] = free[poolOf[best]] - 1
		filled[poolOf[best]] = filled[poolOf[best]] + 1
		local key = bestSource .. ":" .. best
		local a = amounts[key]
		if a == nil then
			a = { source = bestSource, demand = best, amount = 0 }
			amounts[key] = a
		end
		a.amount = a.amount + 1
		planned = planned + 1
	end

	local out = {}
	for _, a in pairs(amounts) do
		table.insert(out, { supply = supply[a.source], demand = demands[a.demand], amount = a.amount,
			sourceIndex = a.source, demandIndex = a.demand })
	end
	-- deterministic order: by demand, then by source
	table.sort(out, function(x, y)
		if x.demandIndex ~= y.demandIndex then
			return x.demandIndex < y.demandIndex
		end
		return x.sourceIndex < y.sourceIndex
	end)
	return out, planned
end

-- Items a warehouse may move now: its unused budget plus what it earned
-- since the last tick, capped so an idle warehouse can't save up for a
-- burst. `perMs` is items per millisecond of game time (math.huge for no
-- limit); returns the new budget.
function rules.addBudget(budget, perMs, dt, cap)
	if perMs == math.huge then
		return cap
	end
	return math.min(cap, (budget or 0) + perMs * math.max(0, dt))
end

---------------------------------------------------------------------------
-- Payment
---------------------------------------------------------------------------

-- Running average of what a cargo type pays per metre, learned from the
-- game's own deliveries. The first `cap` samples weigh equally, later ones
-- move the average by 1/cap, so it follows price changes over the years.
function rules.learnRate(rate, samples, sample, cap)
	samples = samples or 0
	if rate == nil or samples <= 0 then
		return sample, 1
	end
	local n = math.min(samples + 1, cap)
	return rate + (sample - rate) / n, samples + 1
end

-- A constant measured from samples: running average `value`, the number of
-- samples `n` and `dev`, the average relative deviation of the samples from
-- the average. A constant that a formula should explain exactly has dev
-- near 0; a large dev means the formula doesn't explain the samples.
function rules.calibrate(cal, sample, cap)
	if type(cal) ~= "table" or cal.value == nil or (cal.n or 0) <= 0 then
		return { value = sample, n = 1, dev = 0 }
	end
	local n = math.min(cal.n + 1, cap)
	local dev = cal.dev + (math.abs(sample / cal.value - 1) - cal.dev) / n
	return { value = cal.value + (sample - cal.value) / n, n = cal.n + 1, dev = dev }
end

-- The calibration to use among `cals` (key -> calibration): the one whose
-- samples agree best, if it has at least `minSamples` and agrees within
-- `maxDeviation`; nil if none does. Returns it and its key.
function rules.bestCalibration(cals, minSamples, maxDeviation)
	local best, bestKey = nil, nil
	for key, cal in pairs(cals or {}) do
		if type(cal) == "table" and cal.value ~= nil and cal.n >= minSamples and cal.dev <= maxDeviation then
			if best == nil or cal.dev < best.dev or (cal.dev == best.dev and tostring(key) < tostring(bestKey)) then
				best, bestKey = cal, key
			end
		end
	end
	return best, bestKey
end

-- Product of the multipliers game scripts answer for one event entry, like
-- the game combines them. `answers` is a list of the scripts' results
-- (index -> multiplier, or nil for no change); values outside (0, maxValue]
-- are ignored.
function rules.combine(answers, index, maxValue)
	local m = 1
	for _, answer in ipairs(answers) do
		local v = type(answer) == "table" and answer[index] or nil
		if type(v) == "number" and v > 0 and v <= maxValue then
			m = m * v
		end
	end
	return m
end

-- Rate per metre for a cargo type: its own, else the average of the known
-- ones, else nil (not known yet).
function rules.rateFor(rates, cargo)
	if rates == nil then
		return nil
	end
	local own = rates[cargo]
	if own ~= nil then
		return own
	end
	local sum, n = 0, 0
	for _, r in pairs(rates) do
		sum = sum + r
		n = n + 1
	end
	if n == 0 then
		return nil
	end
	return sum / n
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

-- The tag that opts a warehouse in when only tagged warehouses distribute.
rules.TAG = "[D]"

function rules.selected(name, onlyTagged)
	if not onlyTagged then
		return true
	end
	return type(name) == "string" and string.find(string.upper(name), rules.TAG, 1, true) ~= nil
end

-- Spellings of a cargo type for the stock command, most likely first. The
-- command takes a "cargo type URI"; the resource name is the likely one,
-- the others cover a shorter form. The script remembers which one works.
function rules.cargoNames(resName)
	local out, seen = {}, {}
	local function add(s)
		if s ~= nil and s ~= "" and not seen[s] then
			seen[s] = true
			table.insert(out, s)
		end
	end
	if type(resName) ~= "string" then
		return out
	end
	add(resName)
	local base = string.match(resName, "([^/:]+)$") or resName
	add(base)
	local noLua = string.gsub(base, "%.lua$", "")
	add(noLua)
	local bare = string.gsub(noLua, "%.cargo$", "")
	add(bare)
	add(string.upper(bare))
	return out
end

return rules
