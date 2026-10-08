-- Lua calls shapelib (voltc bindings --lang lua): a generic's instances, a struct held by a userdata
-- with methods, owned values passed in, a Volt trait as any object with its methods both ways,
-- callbacks taking and giving text and handles, closures given back as callable userdata, and lists
local m = require("shapelib")

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

-- Lua's own shape: Volt closes one it was given when it's done with it
local Circle = {}
Circle.__index = Circle
function Circle.new(r)
    return setmetatable({ r = r }, Circle)
end
function Circle:area()
    return 3 * self.r * self.r
end
function Circle:name()
    return "circle"
end
function Circle:grow(by)
    self.r = self.r + by
end
function Circle:close()
    print("circle gone")
end
Circle.__close = Circle.close

-- what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
local function extras()
    local ok = pcall(m.checked, function(x)
        if x <= 0 then
            return nil, m.bank_error.OVERDRAWN
        end
    end, 1)
    local _, err = pcall(m.checked, function()
        return nil, m.bank_error.OVERDRAWN
    end, 1)
    say("checked", ok, err.name)
    local lim <close> = m.limiter()
    local _, err2 = pcall(lim, 12)
    say("limit", (pcall(lim, 3)), err2.name)
    local sign = m.labeler()
    say("sign", sign(5), sign(-1))
end

-- lists (sequences both ways), sequences of text and handles, nil for optional text and handles
local function lists()
    local a, b = m.account.open("ann"), m.account.open("bobby")
    a:deposit(5)
    b:deposit(9)
    local os = m.owners({ a, b })
    say("owners", #os, os[1], os[2])
    local r = m.richest({ a, b })
    say("richest", r, "after", a:get(), b:get())
    local opened = m.open_all({ "cy", "dee" })
    say("opened", #opened, opened[2]:owner())
    for _, x in ipairs(opened) do
        x:close()
    end
    local sq = m.squares_upto(4)
    say("squares", #sq, sq[4], "sum", m.sum_all(sq))
    local parts = { "a", "b", "c" }
    say("joined", m.joined(parts, "-"), "total", m.total_len(parts))
    print(m.greeting("ann") .. "; " .. m.greeting(nil))
    local n1, n2 = m.nickname(a), m.nickname(b)
    say("nick", n1 and 1 or 0, n1, n2 and 1 or 0)
    local c, d = m.open_if("eve", true), m.open_if("x", false)
    say("open_if", c and 1 or 0, d == nil and 1 or 0)
    say("close_if", m.close_if(c), m.close_if(nil))
    say("close_all", m.close_all({ a, b }))
    say("some", m.count_some(table.pack(1, nil, 3)))
    say("lists closed", m.closed_accounts())
end

-- what the module rejects, leaving everything as it was; and what a Lua error in a callback or a
-- trait's fn does (Volt gets a stand-in, and the error comes out of the call)
local function rejects()
    local a = m.account.open("zed")
    assert(not pcall(m.close_all, { a, a }), "a handle given twice")
    assert(not pcall(m.close_all, { a, "x" }), "a string for a handle")
    assert(not pcall(m.visit, a, a), "an account for a callback")
    local kept
    m.visit(a, function(lent)
        kept = lent
        assert(not pcall(m.close_account, lent), "a lent account given")
        return 0
    end)
    assert(not pcall(kept.get, kept), "a lent account used after the callback")
    -- an account a running call lent can't be closed or given away by its callback meanwhile
    assert(not pcall(m.visit, a, function() a:close() return 0 end), "closing an account a call holds")
    assert(not pcall(m.visit, a, function() return m.close_account(a) end), "giving away an account a call holds")
    assert(not pcall(m.visit_over, { a }, function() a:close() return 0 end), "closing an account a call holds in a sequence")
    assert(not pcall(m.lend_give, a, a), "lending and giving one account in one call")
    assert(not pcall(m.visit_then, function() error("thrown") end, a), "a callback's error")
    assert(a:get() == 0, "still a's")
    local ok, err = pcall(m.describe, { area = function() return 1 end, name = function() error("no name") end, grow = function() end })
    assert(not ok and tostring(err):find("no name"), "a trait fn's error")
    ok, err = pcall(m.describe, { area = function() return "big" end, name = function() return "x" end, grow = function() end })
    assert(not ok and tostring(err):find("number"), "a trait fn's result of the wrong type")
    assert(not pcall(m.describe, { area = function() return 1 end }), "an object without the trait's fns")
    local calls = 0
    ok, err = pcall(m.try_twice, function()
        calls = calls + 1
        error("stop")
    end, 1)
    assert(not ok and tostring(err):find("stop") and calls == 1, "a callback's error")
    ok, err = pcall(m.shout, function() return 5 end, "x")
    assert(not ok and tostring(err):find("string"), "a callback's text of the wrong type")
    local d = m.doubler()
    d:close()
    assert(not pcall(d, 1), "a closed closure")
    ok, err = pcall(m.joined, { "a" })
    assert(not ok and tostring(err):find("got nil"), "a missing argument after a sequence")
    -- a closure Volt gave back is a callback too
    local lim <close> = m.limiter()
    m.checked(lim, 3)
    ok, err = pcall(m.checked, lim, 12)
    assert(not ok and err.name == "OVERDRAWN", "a closure given back as a callback")
    assert(m.close_account(a) == 0)
    assert(not pcall(a.get, a), "an account given to Volt")
end

do
    local c <close> = Circle.new(1)
    extras()
    say("biggest", m.biggest_i32({ 3, 9, 4 }), m.biggest_f64({ 1.5, 0.5 }))
    local a = m.account.open("ann")
    a:deposit(250)
    a:rename("bea")
    local n = a:deposit(50)
    say("account", a:owner(), n)
    n = m.visit(a, function(b)
        return b:deposit(1)
    end)
    say("visit", n, "get", a:get())
    n = m.close_account(a)
    say("closed", n, m.closed_accounts())
    print(m.describe(c))
    say("grown", m.grow_twice(Circle.new(1)))
    do
        local sq <close> = m.make_square(2)
        sq:grow(1)
        local name, area = sq:name(), sq:area()
        say(name, area, m.describe(sq))
    end
    print(m.shout(function(s)
        return s .. "!"
    end, "hey"))
    local function twice(x)
        if x > 5 then
            return nil, m.bank_error.OVERDRAWN
        end
        return x * 2
    end
    local _, err = pcall(m.try_twice, twice, 4)
    say("try", m.try_twice(twice, 1), err.name)
    n = m.opened_by(function(owner)
        local b = m.account.open(owner)
        b:deposit(7)
        return b
    end)
    say("opened", n)
    say("closed", m.closed_accounts())
    local d, hi = m.doubler(), m.greeter()
    say(d(21), hi("volt"))
    lists()
    rejects()
end
