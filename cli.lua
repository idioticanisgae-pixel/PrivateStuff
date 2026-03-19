-- ╔══════════════════════════════════════════════════════════════════════╗
-- ║              ZukaTech V2  –  Triple-Engine Obfuscator CLI           ║
-- ║     IronBrew2 (bytecode VM) + ZukaTech (AST) + Hercules (token)     ║
-- ╚══════════════════════════════════════════════════════════════════════╝

local function script_path()
	local str = debug.getinfo(2, "S").source:sub(2)
	return str:match("(.*[/\\])") or ""
end
local BASE = script_path()
package.path = BASE .. "?.lua;" .. BASE .. "src/?.lua;" .. package.path

-- ── Core modules ──────────────────────────────────────────────────────────
local ZukaTech    = require("src.ZukaTech")
local Presets     = require("src.presets")
local colors      = ZukaTech.colors
local Logger      = ZukaTech.Logger
Logger.logLevel   = Logger.LogLevel.Info
colors.enabled    = true

-- ── Utility ───────────────────────────────────────────────────────────────
local function file_exists(f)
	local h = io.open(f, "rb")
	if h then h:close() end
	return h ~= nil
end

local function read_file(path)
	local h = assert(io.open(path, "r"))
	local data = h:read("*all")
	h:close()
	return data
end

local function write_file(path, data)
	local h = assert(io.open(path, "w"))
	h:write(data)
	h:close()
end

local function filesize(path)
	local h = io.open(path, "r")
	if not h then return 0 end
	local sz = h:seek("end") or 0
	h:close()
	return sz
end

local function bytes_fmt(n)
	if n >= 1024*1024 then return string.format("%.2f MB", n / (1024*1024))
	elseif n >= 1024  then return string.format("%.2f KB", n / 1024)
	else                   return n .. " B"
	end
end

-- ── Banner ────────────────────────────────────────────────────────────────
local C = {
	r   = "\27[0m",
	b   = "\27[34m",
	c   = "\27[36m",
	g   = "\27[32m",
	y   = "\27[33m",
	m   = "\27[35m",
	w   = "\27[97m",
	rd  = "\27[31m",
	dim = "\27[2m",
}

local BANNER = C.b .. [[
 ______       _         _____         _   __   __  ____
|___  /      | |       |_   _|       | |  \ \ / / |___ \
   / / _   _ | | __  __ | |  ___  ___| |__ \ V /    __) |
  / / | | | || |/ / / _`| | / _ \/ __| '_ \ > <    |__ <
 / /__| |_| ||   < | (_| | ||  __/ (__| | | / . \   ___) |
/_____|\\__,_||_|\\_\ \\__,_\_/ \___|\\___|_| |/_/ \_\ |____/
]] .. C.r
.. C.dim .. C.w .. "  Triple-Engine: IronBrew2 VM + ZukaTech AST + Hercules Token" .. C.r .. "\n"

-- ── Help ──────────────────────────────────────────────────────────────────
local function printHelp()
	print(BANNER)
	print(C.w .. "Usage:" .. C.r .. "  " .. C.c .. "lua cli.lua <input.lua> [options]" .. C.r)
	print("")
	print(C.w .. "Presets  " .. C.dim .. "(--preset / --p)" .. C.r)
	local presetOrder = { "Minify","Weak","Medium","Strong","Tier1","ZuraphMax","HttpGet","NoVmMax" }
	local descs = {
		Minify    = "Lightweight - VM + string encrypt only",
		Weak      = "VM + constant array, no hercules",
		Medium    = "AST + Hercules control-flow / garbage",
		Strong    = "Double VM + Hercules rename & CF",
		Tier1     = "Full ZukaTech pipeline + mid Hercules",
		ZuraphMax = "Everything ON - maximum protection",
		HttpGet   = "Executor-safe web-loader preset",
		NoVmMax   = "Max strength, no VM (executor compat)",
	}
	for _, name in ipairs(presetOrder) do
		local tag = (name == "ZuraphMax") and (C.m .. "* ") or "  "
		print(string.format("  %s%s%-16s%s%s", tag, C.c, name, C.r, C.dim .. (descs[name] or "") .. C.r))
	end
	print("")
	print(C.w .. "Options" .. C.r)
	local opts = {
		{ "--preset <n>",    "Use a named preset  (alias: --p)" },
		{ "--config <file>", "Load config from a .lua file" },
		{ "--out <file>",    "Output path  (default: input.obfuscated.lua)" },
		{ "--LuaU",          "Parse source as LuaU  (default)" },
		{ "--Lua51",         "Parse source as Lua 5.1 (strict)" },
		{ "--pretty",        "Enable pretty-print in unparsed output" },
		{ "--noironbrew",    "Skip the IronBrew2 bytecode VM pass" },
		{ "--nohercules",    "Skip the Hercules pass entirely" },
		{ "--nocolors",      "Disable ANSI colors" },
		{ "--saveerrors",    "Write parse errors to <input>.error.txt" },
	}
	for _, o in ipairs(opts) do
		print(string.format("  %s%-22s%s%s", C.c, o[1], C.r .. "  ", C.dim .. o[2] .. C.r))
	end
	print("")
	os.exit(0)
end

-- ── Arg parse ─────────────────────────────────────────────────────────────
local sourceFile, outFile, luaVersion, prettyPrint
local skipHercules = false
local skipIronBrew = false
local config

local i = 1
while i <= #arg do
	local curr = arg[i]
	if curr == "--help" or curr == "-h" then
		printHelp()
	elseif curr == "--preset" or curr == "--p" then
		i = i + 1
		local name = arg[i]
		config = Presets[name]
		if not config then
			Logger:error(string.format("Preset \"%s\" not found. Available: %s",
				tostring(name), table.concat((function()
					local t = {}
					for k in pairs(Presets) do t[#t+1] = k end
					table.sort(t)
					return t
				end)(), ", ")))
		end
	elseif curr == "--config" or curr == "--c" then
		i = i + 1
		local filename = arg[i]
		if not file_exists(filename) then
			Logger:error(string.format("Config file \"%s\" not found.", filename))
		end
		local fn = loadstring and loadstring(read_file(filename)) or load(read_file(filename))
		setfenv(fn, {})
		config = fn()
	elseif curr == "--out" or curr == "--o" then
		i = i + 1
		outFile = arg[i]
	elseif curr == "--nocolors" then
		colors.enabled = false
	elseif curr == "--Lua51" then
		luaVersion = "Lua51"
	elseif curr == "--LuaU" then
		luaVersion = "LuaU"
	elseif curr == "--pretty" then
		prettyPrint = true
	elseif curr == "--nohercules" then
		skipHercules = true
	elseif curr == "--noironbrew" then
		skipIronBrew = true
	elseif curr == "--saveerrors" then
		Logger.errorCallback = function(msg)
			print(colors(ZukaTech.Config.NameUpper .. ": " .. msg, "red"))
			if sourceFile then
				local errFile = sourceFile:sub(-4) == ".lua"
					and sourceFile:sub(1, -5) .. ".error.txt"
					or  sourceFile .. ".error.txt"
				write_file(errFile, msg)
			end
			os.exit(1)
		end
	elseif curr:sub(1, 2) == "--" then
		Logger:warn(string.format("Unknown option \"%s\" (ignored)", curr))
	else
		if sourceFile then
			Logger:error(string.format("Unexpected argument \"%s\"", curr))
		end
		sourceFile = curr
	end
	i = i + 1
end

if not sourceFile then
	print(BANNER)
	Logger:error("No input file specified. Run with --help for usage.")
end

if not file_exists(sourceFile) then
	Logger:error(string.format("File \"%s\" not found.", sourceFile))
end

if not config then
	Logger:warn("No preset/config specified - falling back to Tier1")
	config = Presets.Tier1
end

config.LuaVersion  = luaVersion  or config.LuaVersion  or "LuaU"
config.PrettyPrint = prettyPrint ~= nil and prettyPrint or config.PrettyPrint

if not outFile then
	outFile = sourceFile:sub(-4) == ".lua"
		and sourceFile:sub(1, -5) .. ".obfuscated.lua"
		or  sourceFile .. ".obfuscated.lua"
end

-- ── Run ───────────────────────────────────────────────────────────────────
local source     = read_file(sourceFile)
local totalStart = os.clock()

print(BANNER)

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 0: IronBrew2 - Lua 5.1 Bytecode VM
-- Compiles source to luac5.1 bytecode, generates a custom Lua VM around it.
-- We strip IB2's final executor call and re-wrap the whole blob in our
-- standard return(function(...)...end)(...) closure before passing forward.
-- ══════════════════════════════════════════════════════════════════════════

-- Find ironbrew.exe next to cli.lua or inside bin/publish/
local function find_exe(name)
	local candidates = {
		BASE .. name,
		BASE .. "bin\\publish\\" .. name,
		BASE .. "bin/publish/" .. name,
		name,
	}
	for _, p in ipairs(candidates) do
		if file_exists(p) then return p end
	end
	return nil
end

local ibExe   = find_exe("ironbrew.exe")
local luacExe = find_exe("luac5.1.exe") or (BASE .. "luac5.1.exe")
local ibOut   = source   -- fallback if Phase 0 skipped or fails

-- Windows-safe temp files: place them next to cli.lua, not in \tmp
local function tmp_path(suffix)
	return BASE .. "_zuka_tmp_" .. suffix
end

if skipIronBrew then
	print(C.dim .. " Phase 0 skipped (--noironbrew)" .. C.r)
elseif not ibExe then
	print(C.dim .. " Phase 0 skipped (ironbrew.exe not found - build IronBrew2CLI first)" .. C.r)
else
	print(C.w .. " Phase 0 " .. C.r .. C.dim .. "IronBrew2 bytecode VM ..." .. C.r)

	-- Write source to temp file next to cli.lua (avoids Windows \tmp path issues)
	local ibTmpIn  = tmp_path("ib_in.lua")
	local ibTmpOut = tmp_path("ib_out.lua")

	write_file(ibTmpIn, source)

	local ibStart = os.clock()
	local cmd = string.format('cmd /c ""%s" "%s" "%s" --luac "%s""',
		ibExe, ibTmpIn, ibTmpOut, luacExe)

	local handle = io.popen(cmd)
	local ibLog  = handle:read("*all")
	handle:close()
	local ibTime = os.clock() - ibStart

	os.remove(ibTmpIn)

	if file_exists(ibTmpOut) and filesize(ibTmpOut) > 0 then
		local raw = read_file(ibTmpOut)
		os.remove(ibTmpOut)

		-- Pass raw IB2 output straight into ZukaTech AST pipeline.
		-- No pre-wrapping here — the single return(function(...)...end)(...)
		-- closure is applied after ALL passes complete (same as normal source).
		ibOut = raw

		print(string.format("  %s+%s IronBrew2 done in %s%.3fs%s", C.g, C.r, C.y, ibTime, C.r))
	else
		print(string.format("  %s!%s IronBrew2 failed - falling back to source-only pipeline", C.y, C.r))
		if ibLog and #ibLog > 0 then
			for line in ibLog:gmatch("[^\n]+") do
				print(C.dim .. "    " .. line .. C.r)
			end
		end
		os.remove(ibTmpOut)
		ibOut = source
	end
end

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 1: ZukaTech AST pipeline
-- Runs on the IB2 VM output (or raw source if Phase 0 was skipped/failed).
-- ══════════════════════════════════════════════════════════════════════════
print(C.w .. " Phase 1 " .. C.r .. C.dim .. "ZukaTech AST pipeline ..." .. C.r)

local pipeline = ZukaTech.Pipeline:fromConfig(config)
local ztStart  = os.clock()
local ztOut    = pipeline:apply(ibOut, sourceFile)
local ztTime   = os.clock() - ztStart

print(string.format("  %s+%s ZukaTech done in %s%.3fs%s", C.g, C.r, C.y, ztTime, C.r))

-- Strip ALL return(function(...)...end)(...) wrappers ZukaTech stacked,
-- then apply exactly one clean outer wrapper.
-- NOTE: Use greedy match via lazy+anchor — finds the OUTERMOST end)(...) at EOF.
do
	local stripped = true
	while stripped do
		-- Match: return(function(...) BODY [\n|;]end)(...)
		-- The lazy .* with $ causes backtracking to find the LAST end)(...) = outermost
		local body = ztOut:match("^%s*return%s*%(function%s*%(%.%.%.%)(.-)%s*end%)%s*%(%.%.%.%)[^\n]*$")
		if body then
			ztOut = body
		else
			stripped = false
		end
	end
end
ztOut = "return (function(...)\n" .. ztOut .. "\nend)(...)"

-- ══════════════════════════════════════════════════════════════════════════
-- Phase 2: Hercules token pipeline
-- ══════════════════════════════════════════════════════════════════════════
local finalOut = ztOut

if not skipHercules and config.Hercules then
	print(C.w .. " Phase 2 " .. C.r .. C.dim .. "Hercules token pipeline ..." .. C.r)

	local ok_bridge, HerculesBridge = pcall(function()
		local bridgePath = BASE .. "src/hercules_bridge.lua"
		local chunk, err = loadfile(bridgePath)
		if not chunk then error(err) end
		return chunk()
	end)

	if not ok_bridge then
		Logger:warn("Hercules bridge failed to load - skipping.\n  " .. tostring(HerculesBridge))
	else
		local hStart = os.clock()
		local ok_hpass, result = pcall(function()
			return HerculesBridge.process(ztOut, config.Hercules)
		end)
		local hTime = os.clock() - hStart

		if ok_hpass then
			finalOut = result
			print(string.format("  %s+%s Hercules done in %s%.3fs%s", C.g, C.r, C.y, hTime, C.r))
		else
			Logger:warn("Hercules pass error - using ZukaTech-only output.\n  " .. tostring(result))
		end
	end
else
	if skipHercules then
		print(C.dim .. " Phase 2 skipped (--nohercules)" .. C.r)
	else
		print(C.dim .. " Phase 2 skipped (preset has no Hercules config)" .. C.r)
	end
end

-- ── Write output ──────────────────────────────────────────────────────────
write_file(outFile, finalOut)
local totalTime = os.clock() - totalStart

-- ── Summary ───────────────────────────────────────────────────────────────
local origBytes = #source
local outBytes  = #finalOut
local ratio     = origBytes > 0 and string.format("%.1f%%", (outBytes / origBytes) * 100) or "N/A"
local line      = C.dim .. string.rep("-", 62) .. C.r

print("")
print(line)
print(string.format("  %sZukaTech V2%s  complete in %s%.3fs%s",
	C.m, C.r, C.y, totalTime, C.r))
print(line)
print(string.format("  %-20s %s%s%s -> %s%s%s  (%s)",
	"Size:",
	C.c, bytes_fmt(origBytes), C.r,
	C.g, bytes_fmt(outBytes),  C.r,
	C.y .. ratio .. C.r))
print(string.format("  %-20s %s%s%s", "Output:", C.c, outFile, C.r))
print(string.format("  %-20s %s%s%s", "Preset/Config:",
	C.c, config.Name or "(custom)", C.r))

-- Engines line
local engines = {}

if not skipIronBrew and ibExe then
	engines[#engines+1] = C.g .. "IronBrew2" .. C.r .. C.dim .. " [bytecode VM]" .. C.r
else
	engines[#engines+1] = C.dim .. "IronBrew2 (off)" .. C.r
end

engines[#engines+1] = C.g .. "ZukaTech" .. C.r
	.. C.dim .. " [" .. #config.Steps .. " steps, "
	.. (config.NameGenerator or "?") .. " names]" .. C.r

if not skipHercules and config.Hercules then
	local hlist = {}
	for k, v in pairs(config.Hercules) do
		if v == true then hlist[#hlist+1] = k end
	end
	table.sort(hlist)
	engines[#engines+1] = C.g .. "Hercules" .. C.r
		.. C.dim .. " [" .. table.concat(hlist, ", ") .. "]" .. C.r
else
	engines[#engines+1] = C.dim .. "Hercules (off)" .. C.r
end

print(string.format("  %-20s %s", "Engines:", table.concat(engines, " -> ")))
print(line)
print("")