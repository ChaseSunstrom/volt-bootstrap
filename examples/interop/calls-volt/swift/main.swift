// Swift calls the Volt library greet through its Swift file (bindings/greet.swift, over the C
// header as module Cgreet): owned text comes back as a String, an export struct is a class
print("add", add(2, 3))
print(hello("volt"))
let c = tally("clicks")
_ = c.add(1)
let n = c.add(2)
print(c.name(), n)
c.close()
