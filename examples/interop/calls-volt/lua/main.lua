-- Lua calls the Volt library greet through its C module (bindings/lua/greet.so): owned text comes
-- back as a string, an export struct is a userdata (a to-be-closed variable frees it)
local greet = require("greet")

print("add", greet.add(2, 3))
print(greet.hello("volt"))
do
    local c <close> = greet.tally.new("clicks")
    c:add(1)
    local n = c:add(2)
    print(c:name(), n)
end
