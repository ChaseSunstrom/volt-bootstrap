# Python calls the Volt library greet through its module (bindings/greet.py, over ctypes): owned
# text comes back as str, an export struct is a class (close() or a with block frees it)
import greet

print("add", greet.add(2, 3))
print(greet.hello("volt"))
with greet.tally("clicks") as c:
    c.add(1)
    n = c.add(2)
    print(c.name(), n)
