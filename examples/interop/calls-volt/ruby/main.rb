# Ruby calls the Volt library greet through its C extension (bindings/ruby/greet.so): owned text
# comes back as a String, an export struct is a class (close frees it now; otherwise the GC does)
require "greet"

puts "add #{Greet.add(2, 3)}"
puts Greet.hello("volt")
c = Greet::Tally.new("clicks")
c.add(1)
n = c.add(2)
puts "#{c.name} #{n}"
c.close
