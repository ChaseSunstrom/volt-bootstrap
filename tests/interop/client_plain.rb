# Ruby calls plainlib (voltc bindings --lang ruby): the plain shapes beyond mathlib's
require "plainlib"

# the plain shapes: a struct with text, an array and a struct in it (in, out, in an array, from a
# block), one with a pointer, an E!T parameter (a value, or the error)
ab = { name: "ab", sizes: [1, 2, 3], at: { x: 7, y: 0 } }
puts "label #{Plainlib.pl_label_len(ab)}"
lo = Plainlib.pl_label_of("ab", 3)
puts "label_of #{lo.name} #{lo.sizes.join(' ')} #{lo.at.x}"
puts "labels #{Plainlib.pl_labels_len([ab, lo])}"
puts "holder #{Plainlib.pl_holder_k({ p: nil, k: 3 })}"
puts "or #{Plainlib.pl_or(4.5, 9.5)} #{Plainlib.pl_or(Plainlib::PlainError.new(Plainlib::PlainError::NEGATIVE), 9.5)}"
puts "ask #{Plainlib.pl_ask(proc { |k| { name: "abc", sizes: [k, k, k], at: { x: 3, y: 0 } } })}"
