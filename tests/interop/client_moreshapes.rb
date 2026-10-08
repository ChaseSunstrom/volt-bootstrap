# Ruby calls moreshapes (voltc bindings --lang ruby): what shapelib's clients don't, Ruby's side of
# a trait object Volt keeps past the call, handles a callback is given, a str a callback gives, a
# slice and an E!T a callback takes, str?, cstr, a list of optionals, a closure taking a handle, and
# a handle closed while the call's arguments are converted
require "moreshapes"

M = Moreshapes

# Ruby's sizer: Volt keeps it (given to a holder) until the holder goes, then closes it
class Sizer
  def size(t) = t.get + 1
  def make(n) = M::Thing.new(n * 2)
  def label = "sizer"
  def close = puts("sizer closed")
end

class Bad
  def size(_) = raise(ArgumentError, "no size")
  def make(n) = M::Thing.new(n)
  def label = 5
end

# the class of what the block raises
def raised
  yield
  "nothing"
rescue StandardError => e
  e.class.name
end

h = M::Holder.new(Sizer.new)
GC.start
GC.compact if GC.respond_to?(:compact)
puts "measure #{h.measure(3)} tag #{h.tag}"
h.close
seen = []
M.each_thing(3) do |t|
  seen << t.get
  t.close
end
puts "each #{seen.join(",")} gone #{M.gone_things}"
begin
  M.each_thing(3) do |t|
    t.close
    raise "stop"
  end
rescue RuntimeError => e
  puts "stopped #{e.message} gone #{M.gone_things}"
end
puts "label #{M.label_of(->(x) { x.positive? ? "pos" : "neg" }, 1)} #{M.label_of(->(_) { "neg" }, -1)}"
puts "slice #{M.with_slice(->(xs) { xs.sum })}"
r = ->(x) { x.is_a?(M::Error) ? -1 : x }
puts "result #{M.with_result(r, true)} #{M.with_result(r, false)}"
puts "maybe #{M.maybe_text(true)} #{M.maybe_text(false).inspect} cstr #{M.cstr_len("hello")}"
puts "list #{M.some_list.inspect}"
g = M.getter
t = M::Thing.new(9)
puts "getter #{g.(t)} #{[t].map(&g).inspect}"
g.close
big = M.keep_big([M::Thing.new(1), M::Thing.new(5), M::Thing.new(7)], 5)
puts "big #{big.map(&:get).inspect}"
fs = M.fixed_sizer(100)
h3 = M::Holder.new(fs)
puts "fixed #{h3.measure(2)} #{raised { fs.label }}"
hb = M::Holder.new(Bad.new)
puts "bad #{raised { hb.measure(1) }} #{raised { hb.tag }}"
# a handle closed by what converting a later argument runs (respond_to?) isn't passed
def sneaky(victim)
  f = Object.new
  f.define_singleton_method(:call) { |n| n }
  f.define_singleton_method(:respond_to?) do |*|
    victim.close
    true
  end
  f
end
t1 = M::Thing.new(1)
t2 = M::Thing.new(2)
puts "closed meanwhile #{raised { M.lend_then(t1, sneaky(t1)) }} #{raised { M.give_then(t2, sneaky(t2)) }} gone #{M.gone_things}"
# the rest (h3, hb, big, t) is left to the GC, which frees it at exit, before the leak report
