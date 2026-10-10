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
tg = Mathlib.ml_tags_make
head = "tags #{tg.from} #{tg.type} #{tg.self} #{tg.int}"
tg.int = 5
puts "#{head} #{Mathlib.ml_tags_sum(tg)}"
bp, bq = [7], [2.5]
Mathlib.ml_bump(bp, bq)
puts "bump #{bp[0]} #{n(bq[0])}"
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
# structs with text, an array and a struct in them (in, out, in an array, from a block), one with a
# pointer, E!T as a parameter (a value, or the error)
la = { name: "ab", sizes: [1, 2, 3], at: { x: 7, y: 0 } }
puts "label #{Mathlib.ml_label_len(la)}"
lb = Mathlib.ml_label_of("ab", 3)
puts "label_of #{lb.name} #{lb.sizes.join(' ')} #{lb.at.x}"
puts "labels #{Mathlib.ml_labels_len([la, lb])}"
puts "holder #{Mathlib.ml_holder_k({ p: nil, k: 3 })}"
puts "or #{Mathlib.ml_or(4.5, 9.5)} #{Mathlib.ml_or(Mathlib::MathError.new(Mathlib::MathError::NEGATIVE), 9.5)}"
puts "ask #{Mathlib.ml_ask(proc { |k| { name: "abc", sizes: [k, k, k], at: { x: 3, y: 0 } } })}"
Mathlib.ml_relabel(lb, 4)
puts "relabel #{lb.name} #{lb.sizes.join(' ')}"
puts "count #{Mathlib.ml_labels_count([la, lb])}"
puts "note #{Mathlib.ml_note_len({ str: "abc", c: 1, k: 3 })}"
puts "or_label #{Mathlib.ml_or_label(la)} #{Mathlib.ml_or_label(Mathlib::MathError.new(Mathlib::MathError::NEGATIVE))}"
puts "given #{Mathlib.ml_sum_given(3, proc { |k| [k, 10 * k] })} #{Mathlib.ml_area_given(proc { |k| [{ x: 1.5, y: k }, { x: 2, y: 3.25 }] })}"
deep = [[[1, 2], [3]], [[4]]]
d = Mathlib.ml_deep(deep)
puts "deep #{d} #{deep[0][0][1]} #{deep[1][0][0]} words #{Mathlib.ml_words([["ab", "c"], [], ["def"]])}"
puts "text_given #{Mathlib.ml_text_given(proc { |k| ["ab", "cde"] })} #{Mathlib.ml_labels_given(proc { |k| [{ name: "abc", sizes: [k, k, k], at: { x: 3, y: 0 } }, { name: "de", sizes: [1, 1, 1], at: { x: 0, y: 0 } }] })}"
puts "turn #{Mathlib.ml_turn(proc { |a| [a[2], a[1], a[0]] })}"
turner = Object.new
def turner.turn(a) = [a[2], a[1], a[0]]
puts "turner #{Mathlib.ml_turned(turner)} flipped #{Mathlib.ml_flipped(Mathlib.ml_flipper)}"
po = Mathlib.ml_pair_of("ab", "cd")
shelf = { labels: [{ name: "abc", sizes: [2, 2, 2], at: { x: 3, y: 0 } }, { name: "de", sizes: [1, 1, 1], at: { x: 0, y: 0 } }], k: 1 }
bk = Mathlib.ml_labels_back(shelf[:labels])
puts "pair #{Mathlib.ml_pair_len({ names: ["ab", "cde"], n: 1 })} #{po.names[0]} #{po.names[1]} shelf #{Mathlib.ml_shelf_len(shelf)} back #{bk.length} #{bk[0].name}"

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
