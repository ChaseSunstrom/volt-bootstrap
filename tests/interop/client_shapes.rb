# Ruby calls shapelib (voltc bindings --lang ruby, a C extension): a generic's instances, a struct
# held by a class with methods, owned values passed in, a Volt trait as any object with its methods
# both ways, blocks and Procs for callbacks taking and giving text, handles and E!T, closures given
# back as Shapelib::Fn, Arrays for lists and for slices of text and handles, and nil for optional
# text and handles
require "open3"
require "rbconfig"
require "shapelib"

S = Shapelib

# Ruby's own shape: Volt calls its methods, and closes one it was given when it drops it
class Circle
  def initialize(r)
    @r = r
  end

  def area = 3 * @r * @r
  def name = "circle"
  def grow(by) = @r += by
  def close = puts("circle gone")
end

def overdrawn = S::BankError.new(S::BankError::OVERDRAWN)

# the name of the Error the block raises
def error_of
  yield
  "no error"
rescue S::Error => e
  e.message
end

def g(x) = format("%g", x)

# what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
def extras
  ok = S.checked(->(_) {}, 1).nil?
  puts "checked #{ok} #{error_of { S.checked(->(_) { raise overdrawn }, 1) }}"
  lim = S.limiter
  puts "limit #{lim.(3).nil?} #{error_of { lim.(12) }}"
  sign = S.labeler
  puts "sign #{sign.(5)} #{sign.(-1)}"
end

# lists (Arrays both ways), slices of text and handles, nil for optional text and handles
def lists
  a = S::Account.open("ann")
  a.deposit(5)
  b = S::Account.open("bobby")
  b.deposit(9)
  both = [a, b]
  names = S.owners(both)
  puts "owners #{names.size} #{names[0]} #{names[1]}"
  print "richest #{S.richest(both)}"
  puts " after #{a.get} #{b.get}"
  opened = S.open_all(%w[cy dee])
  puts "opened #{opened.size} #{opened[1].owner}"
  opened.each(&:close)
  sq = S.squares_upto(4)
  puts "squares #{sq.size} #{sq[3]} sum #{S.sum_all(sq)}"
  parts = %w[a b c]
  puts "joined #{S.joined(parts, "-")} total #{S.total_len(parts)}"
  puts "#{S.greeting("ann")}; #{S.greeting(nil)}"
  n1 = S.nickname(a)
  n2 = S.nickname(b)
  puts "nick #{n1.nil? ? 0 : 1} #{n1} #{n2.nil? ? 0 : 1}"
  c = S.open_if("eve", true)
  d = S.open_if("x", false)
  puts "open_if #{c.nil? ? 0 : 1} #{d.nil? ? 1 : 0}"
  puts "close_if #{S.close_if(c)} #{S.close_if(nil)}"
  puts "close_all #{S.close_all(both)}"
  puts "some #{S.count_some([1, nil, 3])}"
  puts "rows #{S.total_rows([[1, 2], [3]])}"
  puts "lists closed #{S.closed_accounts}"
end

def main
  extras
  puts "biggest #{S.biggest_i32([3, 9, 4])} #{S.biggest_f64([1.5, 0.5])}"
  a = S::Account.open("ann")
  a.deposit(250)
  a.rename("bea")
  n = a.deposit(50)
  puts "account #{a.owner} #{n}"
  n = S.visit(a) { |b| b.deposit(1) }
  puts "visit #{n} get #{a.get}"
  n = S.close_account(a)
  puts "closed #{n} #{S.closed_accounts}"
  c = Circle.new(1)
  puts S.describe(c)
  puts "grown #{g(S.grow_twice(Circle.new(1)))}"
  sq = S.make_square(2)
  sq.grow(1)
  puts "#{sq.name} #{g(sq.area)} #{S.describe(sq)}"
  sq.close
  puts S.shout(->(t) { t + "!" }, "hey")
  twice = lambda do |x|
    raise overdrawn if x > 5

    x * 2
  end
  print "try #{S.try_twice(twice, 1)}"
  puts " #{error_of { S.try_twice(twice, 4) }}"
  n = S.opened_by do |owner|
    b = S::Account.open(owner)
    b.deposit(7)
    b
  end
  puts "opened #{n}"
  puts "closed #{S.closed_accounts}"
  d = S.doubler
  hi = S.greeter
  puts "#{d.(21)} #{hi.("volt")}"
  d.close
  lists
  c.close
end

# the class of what the block raises
def raised
  yield
  "nothing"
rescue Exception => e # rubocop:disable Lint/RescueException
  e.class.name
end

class Broken
  def area = 1.0
  def name = raise(ArgumentError, "no name")
  def grow(by) = nil
end

def boom(*) = raise(ArgumentError, "boom")

class Shrinking
  def area = 1.0
  def name = "shrinking"
  def grow(_) = raise(ArgumentError, "no growth")
  def close = puts("shrinking closed")
end

# Ruby's own (after the rest: it deletes accounts): what a callback or a trait's method raises comes
# out of the call that led to it, once Volt (given a stand-in) returns; what Volt can't take (closed,
# lent, in use by a running call, given twice) is refused before anything is given; a handle Volt
# lent is closed once the callback returns; a block can break out of the call; and a callback that
# has to give Volt a handle and raises ends the program, saying why
def ruby_extras
  a = S::Account.open("ann")
  a.deposit(5)
  puts "raised #{raised { S.shout(method(:boom), "hey") }} #{raised { S.try_twice(method(:boom), 1) }} #{raised { S.visit(a) { boom } }} #{raised { S.describe(Broken.new) }}"
  puts "wrong type #{raised { S.shout(->(_) { 5 }, "hey") }} #{raised { S.describe(Object.new) }}"
  gone = S::Account.open("gone")
  S.close_account(gone)
  puts "refused #{raised { S.close_account(gone) }} #{raised { S.visit(a) { |b| S.close_account(b) } }} #{raised { S.close_all([a, a]) }}"
  puts "in use #{raised { S.visit(a) { S.close_account(a) } }} #{raised { S.visit(a) { a.close } }}"
  puts "kept #{raised { S.close_all([a, gone]) }} #{a.owner} #{a.get}"
  lent = nil
  S.visit(a) { |b| (lent = b).get }
  puts "lent after #{raised { lent.get }}"
  # an object Volt was given is closed when Volt drops it, even after one of its methods raised
  puts "closed anyway #{raised { S.grow_twice(Shrinking.new) }}"
  puts "break #{S.visit(a) { break 7 }}"
  dir = File.dirname($LOADED_FEATURES.grep(/shapelib\.so\z/).first)
  _, err, st = Open3.capture3(RbConfig.ruby, "-I", dir, "-e", "require 'shapelib'; Shapelib.opened_by { 1 / 0 }")
  puts "fatal #{st.exitstatus} #{err.include?("ZeroDivisionError")}"
end

main
ruby_extras
# the library's allocations still live are counted once Ruby has freed its objects (leak_report.c,
# linked into the extension, prints them at exit)
