-- Runs the tests: lua tests/run.lua (from the repository root; Lua 5.1 or later).
-- Every tests/*_test.lua returns function(test, env), and calls
-- test(name, fn) for each test.

package.path = "tests/?.lua;" .. package.path

local CONTENT = "mod/warehouse_distribution_1/content"
local rawLoadfile = loadfile

-- In the game, require("/x.lua") resolves in the content folder of the mod
-- that owns the calling file.
local loaders = package.loaders or package.searchers
table.insert(loaders, 2, function(name)
	if string.sub(name, 1, 1) ~= "/" then
		return nil
	end
	local path = CONTENT .. name
	local chunk, err = rawLoadfile(path)
	if not chunk then
		return "\n\tno file '" .. path .. "' (" .. tostring(err) .. ")"
	end
	return chunk
end)

-- The game's Lua 5.2 sandbox has none of these; the mod must not use them.
local sandboxed = { "unpack", "rawget", "loadstring", "setfenv", "getfenv", "module", "collectgarbage", "dofile", "loadfile" }
local saved = {}
for _, name in ipairs(sandboxed) do
	saved[name] = _G[name]
end
local function sandbox(on)
	for _, name in ipairs(sandboxed) do
		_G[name] = (not on) and saved[name] or nil
	end
end

local env = {}

-- a fresh copy of a mod file, as a new Lua state of the game would load it
function env.load(file)
	local chunk = assert(saved.loadfile(CONTENT .. "/" .. file))
	sandbox(true)
	package.loaded["/warehouse_distribution/rules.lua"] = nil
	local ok, result = pcall(chunk)
	sandbox(false)
	assert(ok, result)
	return result
end

-- runs fn with the sandbox's globals removed
function env.sandboxed(fn, ...)
	sandbox(true)
	local results = { pcall(fn, ...) }
	sandbox(false)
	if not results[1] then
		error(results[2], 0)
	end
	return select(2, (saved.unpack or table.unpack)(results))
end

local files = {}
local p = io.popen("ls tests/*_test.lua")
for line in p:lines() do
	table.insert(files, line)
end
p:close()

local passed, failed = 0, 0
local only = arg[1]
for _, file in ipairs(files) do
	local register = saved.dofile(file)
	register(function(name, fn)
		if only ~= nil and not string.find(name, only, 1, true) then
			return
		end
		local ok, err = xpcall(fn, debug.traceback)
		if ok then
			passed = passed + 1
			print("ok   " .. name)
		else
			failed = failed + 1
			print("FAIL " .. name .. "\n     " .. string.gsub(tostring(err), "\n", "\n     "))
		end
	end, env)
end
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
