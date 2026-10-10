-- Lua calls the Volt library through voltc bindings --lang lua (a C module): an error is raised as
-- a table with its name and code, owned text comes back as a string, an export struct is a userdata
-- (close() or a to-be-closed variable frees it now; otherwise it's freed when collected)
local m = require("mathlib")

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if math.type(v) == "float" and v == math.floor(v) then
            v = string.format("%d", v)
        end
        parts[#parts + 1] = tostring(v)
    end
    print(table.concat(parts, " "))
end

say("add", m.ml_add(2, 3))
local a, b = { x = 1, y = 2 }, { x = 3, y = 4 }
say("dot", m.ml_dot(a, b))
m.ml_scale(a, 2)
say("scale", a.x, a.y)
say("len", m.ml_len("hello"))
say("clash", m.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14))
local tg = m.ml_tags_make()
local from, ty, self, int = tg.from, tg.type, tg.self, tg.int
tg.int = 5
say("tags", from, ty, self, int, m.ml_tags_sum(tg))
local bp, bq = { 7 }, { 2.5 }
m.ml_bump(bp, bq)
say("bump", bp[1], bq[1])
say("next", m.ml_next(m.color.GREEN))
say("sqrt", m.ml_sqrt(9), 1)
local ok, err = pcall(m.ml_sqrt, -1)
say("error", (not ok and err.name == m.math_error.NEGATIVE) and "negative" or "?")
say("greet", m.ml_greet("volt"))
say("repeat", m.ml_repeat("ab", 2))
ok, err = pcall(m.ml_repeat, "ab", -1)
say("repeat", tostring(err):lower())
say("sum", m.ml_sum({ 1, 2, 3.5 }))
local ys = { 4, 5, 6 }
say("find", m.ml_find(ys, 6), m.ml_find(ys, 9) == nil and "none" or "?")
local seen, total = {}, 0
m.ml_each(ys, function(x)
    seen[#seen + 1] = x
    total = total + x
end)
say("each", table.concat(seen, " "), "=", total)
do
    local c <close> = m.counter.new("clicks")
    c:add(2)
    say("counter", c:name(), c:add(3))
    ok, err = pcall(c.take, c, 9)
    say("take", err.name:lower())
end
-- structs with text, an array and a struct in them (in, out, in a sequence, from a function), one
-- with a pointer, E!T as a parameter (a value, or an error the module raised)
local la = { name = "ab", sizes = { 1, 2, 3 }, at = { x = 7, y = 0 } }
say("label", m.ml_label_len(la))
local lb = m.ml_label_of("ab", 3)
say("label_of", lb.name, lb.sizes[1], lb.sizes[2], lb.sizes[3], lb.at.x)
say("labels", m.ml_labels_len({ la, lb }))
say("holder", m.ml_holder_k({ p = nil, k = 3 }))
local _, negative = pcall(m.ml_sqrt, -1)
say("or", m.ml_or(4.5, 9.5), m.ml_or(negative, 9.5))
say("ask", m.ml_ask(function(k) return { name = "abc", sizes = { k, k, k }, at = { x = 3, y = 0 } } end))
m.ml_relabel(lb, 4)
say("relabel", lb.name, lb.sizes[1], lb.sizes[2], lb.sizes[3])
say("count", m.ml_labels_count({ la, lb }))
say("note", m.ml_note_len({ str = "abc", c = 1, k = 3 }))
say("or_label", m.ml_or_label(la), m.ml_or_label(negative))
say("given", m.ml_sum_given(3, function(k) return { k, 10 * k } end), m.ml_area_given(function(k) return { { x = 1.5, y = k }, { x = 2, y = 3.25 } } end))
local deep = { { { 1, 2 }, { 3 } }, { { 4 } } }
local d = m.ml_deep(deep)
say("deep", d, deep[1][1][2], deep[2][1][1], "words", m.ml_words({ { "ab", "c" }, {}, { "def" } }))
say("text_given", m.ml_text_given(function(k) return { "ab", "cde" } end), m.ml_labels_given(function(k) return { { name = "abc", sizes = { k, k, k }, at = { x = 3, y = 0 } }, { name = "de", sizes = { 1, 1, 1 }, at = { x = 0, y = 0 } } } end))
say("turn", m.ml_turn(function(a) return { a[3], a[2], a[1] } end))
say("turner", m.ml_turned({ turn = function(_, a) return { a[3], a[2], a[1] } end }), "flipped", m.ml_flipped(m.ml_flipper()))
local po = m.ml_pair_of("ab", "cd")
local shelf = { labels = { { name = "abc", sizes = { 2, 2, 2 }, at = { x = 3, y = 0 } }, { name = "de", sizes = { 1, 1, 1 }, at = { x = 0, y = 0 } } }, k = 1 }
local bk = m.ml_labels_back(shelf.labels)
say("pair", m.ml_pair_len({ names = { "ab", "cde" }, n = 1 }), po.names[1], po.names[2], "shelf", m.ml_shelf_len(shelf), "back", #bk, bk[1].name)

-- what the module rejects: numbers that don't fit, wrong types, a closed counter; and a callback's
-- error comes out of the call (the later calls are skipped)
assert(not pcall(m.ml_add, 5000000000, 1), "too big for i32")
assert(not pcall(m.ml_add, 1.5, 1), "fraction for i32")
assert(not pcall(m.ml_add, {}, 1), "table for a number")
assert(not pcall(m.ml_dot, { x = 1 }, b), "a field missing")
local c = m.counter.new("x")
c:close()
assert(not pcall(c.add, c, 1), "closed counter")
assert(not pcall(m.counter.new("y").add, {}, 1), "not a counter")
local calls = 0
ok, err = pcall(m.ml_each, ys, function(x)
    calls = calls + 1
    error("stop at " .. x)
end)
assert(not ok and tostring(err):find("stop at 4") and calls == 1, "callback error")
