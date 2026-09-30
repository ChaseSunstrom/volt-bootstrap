# Python calls the Volt library through voltc bindings --lang python (ctypes)
import mathlib as m

print("add", m.ml_add(2, 3))
a, b = m.vec2(1, 2), m.vec2(3, 4)
print("dot %g" % m.ml_dot(a, b))
m.ml_scale(a, 2)
print("scale %g %g" % (a.x, a.y))
print("len", m.ml_len("hello"))
print("next", m.ml_next(m.color.GREEN))
r = m.ml_sqrt(9)
print("sqrt %g %d" % (r.value, r.error == 0))
r = m.ml_sqrt(-1)
print("error", "negative" if r.error == m.math_error.NEGATIVE else "?")
