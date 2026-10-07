-- Tests of rules.lua, the parts without game API.

return function(test, env)
	local r = env.load("warehouse_distribution/rules.lua")

	local function near(a, b)
		return math.abs(a - b) < 1e-6
	end

	test("options: 1-based index, default, clamped, found under any mod id", function()
		local values = { 0, 100, 200 }
		assert(r.option(nil, "k", values, 3) == 200)
		assert(r.option({ some_mod = { k = 1 } }, "k", values, 3) == 0)
		assert(r.option({ a = { other = 2 }, b = { k = 2 } }, "k", values, 3) == 100)
		assert(r.option({ m = { k = 9 } }, "k", values, 1) == 200)
		assert(r.option({ m = { k = 0 } }, "k", values, 3) == 0)
	end)

	test("gap between footprints", function()
		local a = { x0 = 0, y0 = 0, x1 = 10, y1 = 10 }
		assert(r.gap(a, { x0 = 5, y0 = 5, x1 = 20, y1 = 20 }) == 0, "overlap")
		assert(r.gap(a, { x0 = 20, y0 = 0, x1 = 30, y1 = 10 }) == 10)
		assert(near(r.gap(a, { x0 = 13, y0 = 14, x1 = 20, y1 = 20 }), 5))
	end)

	test("paid distance adds eight times the climb, not the descent", function()
		assert(r.paidDistance({ x = 0, y = 0, z = 0 }, { x = 300, y = 400, z = 0 }) == 500)
		assert(r.paidDistance({ x = 0, y = 0, z = 0 }, { x = 300, y = 400, z = 10 }) == 580)
		assert(r.paidDistance({ x = 0, y = 0, z = 10 }, { x = 300, y = 400, z = 0 }) == 500)
	end)

	local function total(plan)
		local n = 0
		for _, t in ipairs(plan) do
			n = n + t.amount
		end
		return n
	end

	test("plan: the emptiest stock first", function()
		local supply = { { cargo = 1, stockId = 0, count = 10 } }
		local a = { cargo = 1, free = 4, capacity = 4 }
		local b = { cargo = 1, free = 1, capacity = 4 }
		local plan, n = r.plan(supply, { b, a }, 3)
		assert(n == 3 and total(plan) == 3)
		for _, t in ipairs(plan) do
			if t.demand == b then
				error("the fuller stock got cargo before the empty one had caught up")
			end
		end
		-- with more, both fill up
		plan = r.plan(supply, { b, a }, 10)
		assert(total(plan) == 5, total(plan))
	end)

	test("plan: never more than supply, free space or budget", function()
		local supply = { { cargo = 1, stockId = 0, count = 3 }, { cargo = 2, stockId = 1, count = 50 } }
		local demands = {
			{ cargo = 1, free = 10, capacity = 10 },
			{ cargo = 2, free = 2, capacity = 10 },
			{ cargo = 3, free = 10, capacity = 10 },
		}
		local plan = r.plan(supply, demands, 100)
		local by = {}
		for _, t in ipairs(plan) do
			by[t.demand.cargo] = (by[t.demand.cargo] or 0) + t.amount
			assert(t.supply.cargo == t.demand.cargo)
		end
		assert(by[1] == 3 and by[2] == 2 and by[3] == nil)
		assert(total(r.plan(supply, demands, 4)) == 4)
		assert(#r.plan(supply, demands, 0) == 0)
	end)

	test("plan: one stock taking two cargo types shares its space", function()
		local supply = { { cargo = 1, stockId = 0, count = 10 }, { cargo = 2, stockId = 0, count = 10 } }
		local demands = {
			{ cargo = 1, free = 4, capacity = 4, pool = "s" },
			{ cargo = 2, free = 4, capacity = 4, pool = "s" },
		}
		assert(total(r.plan(supply, demands, 100)) == 4)
	end)

	test("plan: takes from the fullest warehouse stock of the cargo", function()
		local supply = { { cargo = 1, stockId = 0, count = 2 }, { cargo = 1, stockId = 1, count = 8 } }
		local plan = r.plan(supply, { { cargo = 1, free = 5, capacity = 5 } }, 5)
		assert(#plan == 1 and plan[1].supply.stockId == 1 and plan[1].amount == 5)
	end)

	test("budget: grows with time, capped; no limit gives the cap", function()
		assert(near(r.addBudget(nil, 0.001, 500, 10), 0.5))
		assert(r.addBudget(9.5, 0.001, 5000, 10) == 10)
		assert(r.addBudget(0, math.huge, 1, 200) == 200)
		assert(r.addBudget(2, 0.001, -100, 10) == 2, "time going back adds nothing")
	end)

	test("learned price: average of the first samples, then follows changes", function()
		local rate, n = r.learnRate(nil, nil, 2, 4)
		assert(rate == 2 and n == 1)
		rate, n = r.learnRate(rate, n, 4, 4)
		assert(rate == 3 and n == 2)
		rate, n = r.learnRate(rate, n, 6, 4)
		assert(rate == 4 and n == 3)
		for _ = 1, 50 do
			rate, n = r.learnRate(rate, n, 10, 4)
		end
		assert(near(rate, 10) or math.abs(rate - 10) < 1e-3, rate)
	end)

	test("price of a cargo type: its own, else the average, else unknown", function()
		assert(r.rateFor({ [1] = 2, [2] = 4 }, 1) == 2)
		assert(r.rateFor({ [1] = 2, [2] = 4 }, 3) == 3)
		assert(r.rateFor({}, 3) == nil)
	end)

	test("tagged warehouses", function()
		assert(r.selected("anything", false))
		assert(r.selected(nil, false))
		assert(r.selected("Coal [D]", true))
		assert(r.selected("coal [d] north", true))
		assert(not r.selected("Coal hub", true))
		assert(not r.selected(nil, true))
	end)

	test("spellings of a cargo type", function()
		local n = r.cargoNames("coal.cargo")
		assert(n[1] == "coal.cargo" and n[2] == "coal" and n[3] == "COAL" and #n == 3, table.concat(n, ","))
		n = r.cargoNames("cargo/iron_ore.cargo.lua")
		assert(n[1] == "cargo/iron_ore.cargo.lua" and n[2] == "iron_ore.cargo.lua" and n[3] == "iron_ore.cargo"
			and n[4] == "iron_ore" and n[5] == "IRON_ORE", table.concat(n, ","))
		assert(#r.cargoNames(nil) == 0)
	end)
end
