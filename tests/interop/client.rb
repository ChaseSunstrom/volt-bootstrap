# Ruby calls the Volt library through voltc bindings --lang ruby (a C extension): errors are raised
# as Mathlib::Error subclasses, owned text comes back as a String, an export struct is a class
# (close frees it now; otherwise the GC does)
require "mathlib"

def n(v) = v == v.to_i ? v.to_i.to_s : v.to_s

puts "add #{Mathlib.ml_add(2, 3)}"
a = Mathlib::Vec2.new(1.0, 2.0)
b = Mathlib::Vec2.new(3.0, 4.0)
puts "dot #{n(Mathlib.ml_dot(a, b))}"
Mathlib.ml_scale(a, 2.0)
puts "scale #{n(a.x)} #{n(a.y)}"
puts "len #{Mathlib.ml_len("hello")}"
puts "clash #{Mathlib.ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14)}"
puts "next #{Mathlib.ml_next(Mathlib::Color::GREEN)}"
puts "sqrt #{n(Mathlib.ml_sqrt(9.0))} 1"
begin
  Mathlib.ml_sqrt(-1.0)
rescue Mathlib::MathError => e
  puts "error #{e.code == Mathlib::MathError::NEGATIVE ? "negative" : "?"}"
end
puts "greet #{Mathlib.ml_greet("volt")}"
puts "repeat #{Mathlib.ml_repeat("ab", 2)}"
begin
  Mathlib.ml_repeat("ab", -1)
rescue Mathlib::Error => e
  puts "repeat #{e.message.downcase}"
end
puts "sum #{n(Mathlib.ml_sum([1, 2, 3.5]))}"
ys = [4, 5, 6]
puts "find #{Mathlib.ml_find(ys, 6)} #{Mathlib.ml_find(ys, 9).nil? ? "none" : "?"}"
seen = []
Mathlib.ml_each(ys) { |x| seen << x }
puts "each #{seen.join(" ")} = #{seen.sum}"
c = Mathlib::Counter.new("clicks")
c.add(2)
puts "counter #{c.name} #{c.add(3)}"
begin
  c.take(9)
rescue Mathlib::MathError => e
  puts "take #{e.message.downcase}"
end
c.close

# what the extension rejects: numbers that don't fit, wrong types, a closed counter; and a
# callback's exception comes out of the call (the later calls are skipped)
def rejects(what)
  yield
  raise "#{what}: accepted"
rescue RangeError, TypeError, RuntimeError => e
  raise if e.message.end_with?(": accepted")
end
rejects("too big for i32") { Mathlib.ml_add(5_000_000_000, 1) }
rejects("fraction for i32") { Mathlib.ml_add(1.5, 1) }
rejects("string for a number") { Mathlib.ml_add("1", 1) }
rejects("a field missing") { Mathlib.ml_dot({ x: 1 }, b) }
rejects("closed counter") { c.add(1) }
calls = 0
begin
  Mathlib.ml_each(ys, proc { |x| calls += 1; raise ArgumentError, "stop at #{x}" })
  raise "no error"
rescue ArgumentError => e
  raise "callback error: #{e.message} #{calls}" unless e.message == "stop at 4" && calls == 1
end
raise "hash struct" unless Mathlib.ml_dot({ x: 1, y: 2 }, { x: 3, y: 4 }) == 11.0
