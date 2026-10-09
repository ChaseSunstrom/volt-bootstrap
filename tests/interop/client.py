# Python calls the Volt library through voltc bindings --lang python (ctypes): errors are raised,
# owned text comes back as str, an export struct is a class (close() or a with block frees it)
import ctypes

import mathlib as m

print("add", m.ml_add(2, 3))
a, b = m.vec2(1, 2), m.vec2(3, 4)
print("dot %g" % m.ml_dot(a, b))
m.ml_scale(a, 2)
print("scale %g %g" % (a.x, a.y))
print("len", m.ml_len("hello"))
print("clash", m.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14))
tg = m.ml_tags_make()
print("tags", tg.from_, tg.type, tg.self, tg.int, end=" ")
tg.int = 5
print(m.ml_tags_sum(tg))
bp, bq = ctypes.c_int32(7), ctypes.c_double(2.5)
m.ml_bump(ctypes.byref(bp), ctypes.byref(bq))
print("bump %d %g" % (bp.value, bq.value))
print("next", m.ml_next(m.color.GREEN))
print("sqrt %g 1" % m.ml_sqrt(9))
try:
    m.ml_sqrt(-1)
except m.math_error as e:
    print("error", "negative" if e.code == m.math_error.NEGATIVE else "?")
print("greet", m.ml_greet("volt"))
print("repeat", m.ml_repeat("ab", 2))
try:
    m.ml_repeat("ab", -1)
except m.Error as e:
    print("repeat", e.name.lower())
print("sum %g" % m.ml_sum([1, 2, 3.5]))
ys = [4, 5, 6]
print("find", m.ml_find(ys, 6), "none" if m.ml_find(ys, 9) is None else "?")
seen: list[int] = []
m.ml_each(ys, seen.append)
print("each", " ".join(map(str, seen)), "=", sum(seen))
with m.counter("clicks") as c:
    c.add(2)
    print("counter", c.name(), c.add(3))
    try:
        c.take(9)
    except m.math_error as e:
        print("take", e.name.lower())
