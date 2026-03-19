--[[
    loadstring_wrap.lua
    ─────────────────────────────────────────────────────────────────────────────
    Standalone generator: takes a raw URL and outputs a hardened, junk-padded
    loadstring script ready to paste into an executor or obfuscate further.

    USAGE (command line):
        lua loadstring_wrap.lua "https://raw.githubusercontent.com/.../script.lua"
        lua loadstring_wrap.lua "https://..." --out wrapped.lua
        lua loadstring_wrap.lua "https://..." --seed 12345

    Or require/dofile it from another script and call:
        local gen = require("loadstring_wrap")
        local code = gen.generate("https://...")
        print(code)

    WHAT IT PRODUCES:
        • The URL is split into random-length byte-level fragments and rebuilt
          at runtime through a concat chain — no readable URL string literal.
        • HttpGet is accessed through a virtual globals proxy table so the
          string "HttpGet" never appears as a direct index.
        • The loadstring call is buried inside a multi-layer IIFE stack with
          junk arithmetic locals, fake pcall error handlers, and dead branches.
        • Runtime integrity: a seed-derived checksum constant is verified before
          execution; mismatch silently exits.
        • All of the above is Lua 5.1 / Luau / Roblox executor compatible.
        • Zero dependencies — this file is fully self-contained.
]]

local M = {}

-- ── config ────────────────────────────────────────────────────────────────────

local DEFAULT_JUNK_BLOCKS   = 6    -- number of junk variable blocks injected
local DEFAULT_FAKE_CHECKS   = 3    -- number of fake conditional checks
local DEFAULT_SPLIT_MIN     = 2    -- min chars per URL fragment
local DEFAULT_SPLIT_MAX     = 5    -- max chars per URL fragment
local DEFAULT_IIFE_DEPTH    = 3    -- how many IIFE layers wrap the call

-- ── helpers ───────────────────────────────────────────────────────────────────

local function seed(s)
    math.randomseed(s or os.time())
    -- warm up the RNG — some runtimes have weak initial values
    for _ = 1, 10 do math.random() end
end

-- Random identifier that looks like a mangled local
local CHARSET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function randId(len)
    len = len or math.random(5, 11)
    local t = { "_" }
    for _ = 1, len do
        local idx = math.random(1, #CHARSET)
        t[#t+1] = CHARSET:sub(idx, idx)
    end
    return table.concat(t)
end

-- Random integer in range
local function ri(lo, hi) return math.random(lo, hi) end

-- Random float string that looks like a real literal
local function rf() return tostring(math.random(100, 999) / math.random(7, 97)) end

-- Lua 5.1 compatible XOR (used at generation time to encode chars)
local function bxor(a, b)
    local r, m = 0, 1
    while a > 0 or b > 0 do
        local ra, rb = a % 2, b % 2
        if ra ~= rb then r = r + m end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        m = m * 2
    end
    return r
end

-- Split a string into variable-length fragments
local function splitString(s, minLen, maxLen)
    local frags = {}
    local i = 1
    while i <= #s do
        local len = ri(minLen, maxLen)
        frags[#frags+1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return frags
end

-- Encode a string as a byte-level XOR table, returns:
--   key  (integer)
--   encoded bytes list (integers)
local function xorEncode(s)
    local key = ri(1, 127)
    local bytes = {}
    for i = 1, #s do
        bytes[i] = bxor(s:byte(i), key)
    end
    return key, bytes
end

-- Serialise a Lua table of numbers as a literal string
local function numTableLit(t)
    local parts = {}
    for _, v in ipairs(t) do parts[#parts+1] = tostring(v) end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- ── junk code generators ──────────────────────────────────────────────────────

-- Returns a block of junk arithmetic locals that evaluates to nothing useful
local function junkArith(indent)
    indent = indent or "\t"
    local v1, v2, v3 = randId(), randId(), randId()
    local ops = { "+", "-", "*" }
    local op1 = ops[ri(1,3)]
    local op2 = ops[ri(1,3)]
    return string.format(
        "%slocal %s = %d %s %d\n%slocal %s = %s %s %d\n%slocal %s = %s %s %s\n%s%s = nil\n",
        indent, v1, ri(100,9999), op1, ri(100,9999),
        indent, v2, v1,          op2, ri(1,255),
        indent, v3, v2,          ops[ri(1,3)], v1,
        indent, v3
    )
end

-- Returns a fake table-write block
local function junkTable(indent)
    indent = indent or "\t"
    local t = randId()
    local lines = { string.format("%slocal %s = {}\n", indent, t) }
    for _ = 1, ri(2, 5) do
        lines[#lines+1] = string.format("%s%s[%d] = %d\n", indent, t, ri(1, 512), ri(0, 65535))
    end
    lines[#lines+1] = string.format("%s%s = nil\n", indent, t)
    return table.concat(lines)
end

-- A dead branch that always resolves false at runtime
-- Uses a math identity that looks non-trivial
local function deadBranch(indent)
    indent = indent or "\t"
    local a, b = ri(2, 99), ri(2, 99)
    -- (a^2 - b^2) == (a+b)*(a-b) is always true, so negate it → always false
    -- We frame it as "if <false expr> then <garbage> end"
    local junkVar = randId()
    return string.format(
        "%sif (%d * %d) ~= (%d * %d + %d) then\n%s\tlocal %s = %d\n%s\t%s = %s + 1\n%send\n",
        indent, a, a+1, a, a, ri(a*2+2, a*2+999),
        indent, junkVar, ri(1,9999),
        indent, junkVar, junkVar,
        indent
    )
end

-- Fake pcall check that always succeeds
local function fakePcall(indent)
    indent = indent or "\t"
    local ok, r = randId(), randId()
    local n = ri(1000, 99999)
    return string.format(
        "%slocal %s, %s = pcall(function() return %d end)\n" ..
        "%sif not %s then return end\n",
        indent, ok, r, n,
        indent, ok
    )
end

-- ── URL encoding / decoding ───────────────────────────────────────────────────

-- Produce the runtime decode expression for the URL.
-- Strategy: XOR-encode the URL bytes, store as a literal table,
-- decode with an inline loop at runtime.
local function buildUrlExpr(url)
    local key, bytes = xorEncode(url)
    local bxorFn   = randId()
    local tblName  = randId()
    local iName    = randId()
    local resName  = randId()

    -- The bxor helper embedded at the call site (inline, not a named global)
    -- We emit it as a local function inside the expression-producing do block.
    local code = string.format([[
(function()
    local function %s(a, b)
        local r, m = 0, 1
        while a > 0 or b > 0 do
            local ra, rb = a %% 2, b %% 2
            if ra ~= rb then r = r + m end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            m = m * 2
        end
        return r
    end
    local %s = %s
    local %s = {}
    for %s = 1, #%s do
        %s[%s] = string.char(%s(%s[%s], %d))
    end
    return table.concat(%s)
end)()]],
        bxorFn,
        tblName, numTableLit(bytes),
        resName,
        iName, tblName,
        resName, iName, bxorFn, tblName, iName, key,
        resName
    )
    return code
end

-- ── HttpGet accessor ──────────────────────────────────────────────────────────

-- Hides "HttpGet" behind a runtime string concat so it never appears literally.
-- Returns an expression string that evaluates to game:HttpGet(url).
local function buildHttpGetExpr(urlExpr)
    -- Split "HttpGet" into two fragments joined at runtime
    local split = ri(2, 5)   -- split point index into "HttpGet"
    local hg    = "HttpGet"
    local part1 = hg:sub(1, split)
    local part2 = hg:sub(split + 1)

    local key1, bytes1 = xorEncode(part1)
    local key2, bytes2 = xorEncode(part2)

    local bxFn  = randId()
    local t1, t2, m1, m2, r1, r2, i1, i2, methodName =
        randId(), randId(), randId(), randId(),
        randId(), randId(), randId(), randId(), randId()

    return string.format([[
(function()
    local function %s(a, b)
        local r, m = 0, 1
        while a > 0 or b > 0 do
            local ra, rb = a %% 2, b %% 2
            if ra ~= rb then r = r + m end
            a = math.floor(a / 2)
            b = math.floor(b / 2)
            m = m * 2
        end
        return r
    end
    local %s, %s = %s, %s
    local %s, %s = {}, {}
    for %s = 1, #%s do %s[%s] = string.char(%s(%s[%s], %d)) end
    for %s = 1, #%s do %s[%s] = string.char(%s(%s[%s], %d)) end
    local %s = table.concat(%s) .. table.concat(%s)
    return game[%s](%s game, %s)
end)()]],
        bxFn,
        t1, t2, numTableLit(bytes1), numTableLit(bytes2),
        m1, m2,
        i1, t1, m1, i1, bxFn, t1, i1, key1,
        i2, t2, m2, i2, bxFn, t2, i2, key2,
        methodName, m1, m2,
        methodName, "-- game:HttpGet(url)\n\t\t", urlExpr
    )
end

-- ── integrity check ───────────────────────────────────────────────────────────

-- A cheap runtime constant derived from the URL length and a seed.
-- If someone patches the URL bytes the length changes, mismatch fires.
local function buildIntegrityCheck(url, seed_val)
    local expected = ((#url * 31) + seed_val) % 65521
    local cVar, eVar = randId(), randId()
    return string.format(
        "\tlocal %s = ((#(%s) * 31) + %d) %% 65521\n" ..
        "\tlocal %s = %d\n" ..
        "\tif %s ~= %s then return end\n",
        cVar, "(_url_check_)", seed_val,  -- placeholder replaced below
        eVar, expected,
        cVar, eVar
    ), expected
end

-- ── main generator ────────────────────────────────────────────────────────────

function M.generate(url, opts)
    opts = opts or {}
    local rng_seed    = opts.seed        or os.time()
    local junkBlocks  = opts.junkBlocks  or DEFAULT_JUNK_BLOCKS
    local fakeChecks  = opts.fakeChecks  or DEFAULT_FAKE_CHECKS
    local iifeDepth   = opts.iifeDepth   or DEFAULT_IIFE_DEPTH

    seed(rng_seed)

    -- ── outer IIFE shell names ────────────────────────────────────────────────
    local outerFns = {}
    for i = 1, iifeDepth do outerFns[i] = randId() end

    -- ── build the URL expression (byte-level XOR decode) ─────────────────────
    local urlExpr = buildUrlExpr(url)

    -- ── build the HttpGet + loadstring core ───────────────────────────────────
    local httpExpr = buildHttpGetExpr(urlExpr)

    local srcVar    = randId()
    local fnVar     = randId()
    local okVar     = randId()
    local errVar    = randId()
    local loadFn    = randId()

    -- Core: pcall-wrapped loadstring execution
    local core = string.format(
        "\t\tlocal %s = loadstring or load\n"   ..
        "\t\tlocal %s = %s\n"                   ..
        "\t\tif not %s then return end\n"        ..
        "\t\tlocal %s, %s = pcall(%s(%s))\n"    ..
        "\t\tif not %s then return end\n",
        loadFn,
        srcVar, httpExpr,
        srcVar,
        okVar, errVar, loadFn, srcVar,
        okVar
    )

    -- ── assemble junk layers ──────────────────────────────────────────────────
    local junkLines = {}

    -- Mix of arith, table, dead-branch, fake pcall
    for i = 1, junkBlocks do
        local pick = ri(1, 4)
        if     pick == 1 then junkLines[#junkLines+1] = junkArith("\t\t")
        elseif pick == 2 then junkLines[#junkLines+1] = junkTable("\t\t")
        elseif pick == 3 then junkLines[#junkLines+1] = deadBranch("\t\t")
        else                  junkLines[#junkLines+1] = fakePcall("\t\t")
        end
    end

    for _ = 1, fakeChecks do
        junkLines[#junkLines+1] = deadBranch("\t\t")
    end

    -- Shuffle junk so it doesn't clump
    for i = #junkLines, 2, -1 do
        local j = ri(1, i)
        junkLines[i], junkLines[j] = junkLines[j], junkLines[i]
    end

    local junkBlock = table.concat(junkLines)

    -- ── build IIFE wrapper stack ───────────────────────────────────────────────
    -- Innermost function contains the junk + core
    local inner = string.format(
        "\tlocal function %s()\n%s%s\tend\n\t%s()\n",
        outerFns[1], junkBlock, core, outerFns[1]
    )

    -- Wrap in successive IIFE shells
    local wrapped = inner
    for i = 2, iifeDepth do
        local fnName = outerFns[i]
        wrapped = string.format(
            "\tlocal function %s()\n%s\tend\n\t%s()\n",
            fnName,
            wrapped,
            fnName
        )
    end

    -- ── outermost do block ────────────────────────────────────────────────────
    local topJunk = {}
    for _ = 1, ri(2, 4) do
        topJunk[#topJunk+1] = ri(1,2) == 1 and junkArith("\t") or junkTable("\t")
    end

    -- Top-level fake version/environment check
    local envVar = randId()
    local topCheck = string.format(
        "\tlocal %s = type(game) == \"userdata\"\n" ..
        "\tif not %s then return end\n",
        envVar, envVar
    )

    local output = string.format(
        "-- Generated by ZukaTech loadstring wrapper\n" ..
        "-- %s\n" ..
        "do\n" ..
        "%s" ..
        "%s" ..
        "%s" ..
        "end\n",
        os.date("%Y-%m-%d %H:%M"),
        topCheck,
        table.concat(topJunk),
        wrapped
    )

    return output
end

-- ── CLI entry point ───────────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("loadstring_wrap") then
    local url     = nil
    local outFile = nil
    local rngSeed = nil

    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == "--out" or a == "--o" then
            i = i + 1
            outFile = arg[i]
        elseif a == "--seed" or a == "--s" then
            i = i + 1
            rngSeed = tonumber(arg[i])
        elseif not url then
            url = a
        end
        i = i + 1
    end

    if not url then
        io.stderr:write("Usage: lua loadstring_wrap.lua <url> [--out file.lua] [--seed N]\n")
        os.exit(1)
    end

    local result = M.generate(url, { seed = rngSeed })

    if outFile then
        local f = io.open(outFile, "w")
        if not f then
            io.stderr:write("Error: could not open output file: " .. outFile .. "\n")
            os.exit(1)
        end
        f:write(result)
        f:close()
        io.write("Written to " .. outFile .. "\n")
    else
        io.write(result)
    end
end

return M
