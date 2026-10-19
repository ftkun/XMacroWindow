local addonName, ns = ...

------------------------------------------------------------------------
-- Macro code coloring
------------------------------------------------------------------------
-- Colorize(text) returns the macro text with |cff..|r color codes. Only a FontString drawn over
-- the edit box shows it (Editor.lua); the macro text itself is never changed.
local L = ns.L
local ipairs, pairs, unpack = ipairs, pairs, unpack
local schar, floor, tconcat = string.char, math.floor, table.concat

-- Color themes ---------------------------------------------------------
local DEFAULT_PRESET = "DarkModeDefault"
ns.PRESET_ORDER = { "DarkModeDefault", "Dark", "Monokai", "Solarized Dark", "High contrast" }
local PRESETS = {
    ["DarkModeDefault"] = {     -- Notepad++ DarkModeDefault theme (Lua lexer colors)
        text = { 0.86, 0.86, 0.80 },                            -- DEFAULT DCDCCC
        command = "DFC47D", directive = "FFCFAF", bracket = "FFCFAF", cond = "CEDF99",
        unit = "DCA3A3", value = "8CD0D3", spell = "CC9393", string = "CC9393",
        keyword = "DFC47D", comment = "7F9F7F", func = "CEDF99", punct = "9F9D6D",
        error = "FF5555",
    },
    ["Dark"] = {      -- VS Code Dark+
        text = { 0.83, 0.83, 0.83 },
        command = "569CD6", directive = "6A9955", bracket = "FFD700", cond = "4EC9B0",
        unit = "9CDCFE", value = "B5CEA8", spell = "DCDCAA", string = "CE9178",
        keyword = "C586C0", comment = "6A9955", func = "DCDCAA", punct = "808080",
        error = "FF5555",
    },
    ["Monokai"] = {
        text = { 0.97, 0.97, 0.95 },
        command = "F92672", directive = "75715E", bracket = "FD971F", cond = "66D9EF",
        unit = "A6E22E", value = "AE81FF", spell = "E6DB74", string = "E6DB74",
        keyword = "F92672", comment = "75715E", func = "A6E22E", punct = "75715E",
        error = "FF3030",
    },
    ["Solarized Dark"] = {
        text = { 0.51, 0.58, 0.59 },
        command = "268BD2", directive = "586E75", bracket = "CB4B16", cond = "2AA198",
        unit = "6C71C4", value = "859900", spell = "B58900", string = "2AA198",
        keyword = "859900", comment = "586E75", func = "268BD2", punct = "586E75",
        error = "FF4040",
    },
    ["High contrast"] = {
        text = { 1, 1, 1 },
        command = "00BFFF", directive = "00FF7F", bracket = "FFFF00", cond = "00FFFF",
        unit = "87CEFF", value = "98FB98", spell = "FFEB99", string = "FFA07A",
        keyword = "FF82FF", comment = "7CFC00", func = "FFFF99", punct = "C0C0C0",
        error = "FF3030",
    },
}
ns.PRESETS = PRESETS

-- the active theme; the table stays the same, only its contents change
local COLOR = {}
ns.COLOR = COLOR

function ns.ApplyPreset(name)
    local p = PRESETS[name] or PRESETS[DEFAULT_PRESET]
    for k in pairs(COLOR) do COLOR[k] = nil end
    for k, v in pairs(p) do COLOR[k] = v end
end
ns.ApplyPreset(DEFAULT_PRESET)

-- Lua (/run, /script ...) ----------------------------------------------
local LUA_KW = {} -- Lua keywords
for w in ("and break do else elseif end false for function if in local nil not or repeat return"
    .. " then true until while"):gmatch("%a+") do
    LUA_KW[w] = true
end

local LUA_CMD = { run = true, script = true, dump = true, eval = true }

local function col(hex, s) return "|cff" .. hex .. s .. "|r" end
local function E(s) return (s:gsub("|", "||")) end -- the overlay is a FontString, so escape pipes

local function ColorizeLua(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if s:sub(i, i + 1) == "--" then
            out[#out + 1] = col(COLOR.comment, E(s:sub(i)))
            break
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = s:sub(j, j)
                if d == "\\" then
                    j = j + 2
                elseif d == c then
                    break
                else
                    j = j + 1
                end
            end
            if j > n then j = n end -- string never closed: color to the end of the line
            out[#out + 1] = col(COLOR.string, E(s:sub(i, j)))
            i = j + 1
        elseif c:find("%d") then
            local num = s:match("^%d+%.?%d*", i)
            out[#out + 1] = col(COLOR.value, E(num))
            i = i + #num
        elseif c:find("[%a_]") then
            local word = s:match("^[%a_][%w_]*", i)
            local after = s:match("^%s*(.)", i + #word)
            if LUA_KW[word] then
                out[#out + 1] = col(COLOR.keyword, word)
            elseif after == "(" then
                out[#out + 1] = col(COLOR.func, word)
            else
                out[#out + 1] = word
            end
            i = i + #word
        else
            out[#out + 1] = E(c)
            i = i + 1
        end
    end
    return tconcat(out)
end

-- [conditions] ---------------------------------------------------------
-- one condition: @unit, target=unit, mod:shift, combat
local function ColorCondPart(part)
    local ws, body, tail = part:match("^(%s*)(.-)(%s*)$")
    if body == "" then return part end
    local out
    if body:sub(1, 1) == "@" then
        out = col(COLOR.unit, E(body))
    elseif body:find("=", 1, true) then
        local k, v = body:match("^([^=]*)=(.*)$")
        out = col(COLOR.cond, E(k)) .. "=" .. col(COLOR.unit, E(v))
    else
        local k, v = body:match("^([^:]*):(.*)$")
        if k then
            out = col(COLOR.cond, E(k)) .. ":" .. col(COLOR.value, E(v))
        else
            out = col(COLOR.cond, E(body))
        end
    end
    return ws .. out .. tail
end

local function ColorizeCond(inner)
    local out = {}
    for part, sep in inner:gmatch("([^,]*)(,?)") do
        out[#out + 1] = ColorCondPart(part) .. sep
    end
    return tconcat(out)
end

-- Spell / item names ---------------------------------------------------
-- A rank at the end, "Fireball(Rank 3)" or "Огненный шар(Уровень 3)", gets the word in the
-- condition color and the number in the value color.
local function ColorSpell(s)
    local name, open, word, num, close = s:match("^(.-)(%(%s*)([^%d%(%)]*)(%d+)(%s*%))$")
    if not name then return col(COLOR.spell, E(s)) end
    local wordPart = word ~= "" and col(COLOR.cond, E(word)) or ""
    return (name ~= "" and col(COLOR.spell, E(name)) or "") .. col(COLOR.punct, open)
        .. wordPart .. col(COLOR.value, num) .. col(COLOR.punct, close)
end

-- comma separated names (castsequence), reset=... option, plain numbers (bag slot, item slot)
local function ColorNames(seg)
    if seg:match("^%s*$") then return seg end
    local out = {}
    for part, sep in seg:gmatch("([^,]*)(,?)") do
        local ws, body, tail = part:match("^(%s*)(.-)(%s*)$")
        local piece
        if body == "" then
            piece = ""
        elseif body:find("^reset=") then
            local rv, sp, rest = body:match("^reset=(%S*)(%s*)(.*)$")
            piece = col(COLOR.cond, "reset") .. "=" .. col(COLOR.value, E(rv)) .. sp
            if rest ~= "" then piece = piece .. ColorSpell(rest) end
        elseif body:find("^[%d%s]+$") then
            piece = col(COLOR.value, body)
        else
            piece = ColorSpell(body)
        end
        out[#out + 1] = ws .. piece .. tail .. sep
    end
    return tconcat(out)
end

-- everything after a slash command: [conditions] names; [conditions] names ...
local function ColorizeArgs(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "[" then
            local j = s:find("]", i, true)
            if j then
                out[#out + 1] = col(COLOR.bracket, "[") .. ColorizeCond(s:sub(i + 1, j - 1)) .. col(COLOR.bracket, "]")
                i = j + 1
            else
                out[#out + 1] = col(COLOR.error, "[") -- opening bracket that is never closed
                i = i + 1
            end
        elseif c == "]" then
            out[#out + 1] = col(COLOR.error, "]")     -- closing bracket without an opening one
            i = i + 1
        elseif c == ";" then
            out[#out + 1] = col(COLOR.punct, ";")
            i = i + 1
        else
            local j = s:find("[%[%];]", i) or (n + 1)
            out[#out + 1] = ColorNames(s:sub(i, j - 1))
            i = j
        end
    end
    return tconcat(out)
end

-- one line: #directive, /command or plain text
local function ColorizeLine(line)
    if line == "" then return "" end

    local lead, dir, rest = line:match("^(%s*)(#%a+)(.*)$")
    if dir then
        -- typos are shown in the error color (ns.IsUnknownDirective / ns.IsUnknownCommand: Extras.lua)
        local bad = ns.IsUnknownDirective and ns.IsUnknownDirective(dir)
        return lead .. col(bad and COLOR.error or COLOR.directive, dir) .. ColorizeArgs(rest)
    end

    local lead2, cmd, rest2 = line:match("^(%s*)(/[^%s%[]+)(.*)$")
    if cmd then
        local isLua = LUA_CMD[cmd:sub(2):lower()]
        local body = isLua and ColorizeLua(rest2) or ColorizeArgs(rest2)
        local bad = ns.IsUnknownCommand and ns.IsUnknownCommand(cmd)
        return lead2 .. col(bad and COLOR.error or COLOR.command, E(cmd)) .. body
    end

    return E(line)
end

-- Escape sequences --------------------------------------------------------
-- Escape sequences the edit box renders itself (links, colors, textures, "||") are cut out
-- before coloring and put back unchanged, so the overlay shows exactly what the edit box shows.
-- Placeholder: \1 + two chars from \14-\31 (not %s, %w, %p or digits, so no colorizer splits it).
local ESC_PATTERNS = {
    "^|c%x%x%x%x%x%x%x%x.-|r",  -- colored text, incl. a whole |c..|H..|h[..]|h|r link
    "^|cn[%w_]+:.-|r",          -- named color
    "^|H.-|h.-|h",              -- link without a color
    "^|T.-|t", "^|A.-|a",       -- texture / atlas
    "^||",                      -- literal pipe
}
local MAX_CHUNKS = 18 * 18 -- placeholders available per line

local function Protect(line, chunks)
    if not line:find("|", 1, true) then return line end
    local out, i, n = {}, 1, #line
    while i <= n do
        local j = line:find("|", i, true)
        if not j then out[#out + 1] = line:sub(i); break end
        out[#out + 1] = line:sub(i, j - 1)
        local m
        for _, pat in ipairs(ESC_PATTERNS) do
            m = line:match(pat, j)
            if m then break end
        end
        if m and #chunks < MAX_CHUNKS then
            chunks[#chunks + 1] = m
            local k = #chunks - 1
            out[#out + 1] = "\1" .. schar(14 + floor(k / 18), 14 + k % 18)
            i = j + #m
        else
            out[#out + 1] = "|" -- lone pipe: E() escapes it later
            i = j + 1
        end
    end
    return tconcat(out)
end

local function Restore(s, chunks)
    if #chunks == 0 then return s end
    return (s:gsub("\1([\14-\31])([\14-\31])", function(a, b)
        return chunks[(a:byte() - 14) * 18 + (b:byte() - 14) + 1]
    end))
end

local function Colorize(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local chunks = {}
        lines[#lines + 1] = Restore(ColorizeLine(Protect(line, chunks)), chunks)
    end
    return tconcat(lines, "\n")
end
ns.Colorize = Colorize

------------------------------------------------------------------------
-- Macro text in a tooltip (colored when coloring is on)
------------------------------------------------------------------------
function ns.AddBodyLines(tt, body)
    if body == "" then
        tt:AddLine(L["(empty)"], 0.6, 0.6, 0.6)
    elseif ns.db.colors then
        local t = COLOR.text
        tt:AddLine(Colorize(body), t[1], t[2], t[3], true)
    else
        tt:AddLine(body, 1, 0.82, 0, true)
    end
end

-- color a FontString drawn over an edit box (macro editor, copy window)
function ns.PaintOverlay(fs, text)
    fs:SetTextColor(unpack(COLOR.text))
    fs:SetText(Colorize(text))
end
