# Python calls shapelib (voltc bindings --lang python): a generic's instances, a struct held by a
# class with methods, owned values passed in, a Volt trait as a class to subclass both ways,
# callbacks taking and giving text, handles and E!T, closures given back as callables, lists,
# slices of text and handles, and optional text and handles (None)
import ctypes
import sys

import shapelib as s


class Circle(s.shape):
    def __init__(self, r):
        self.r = r

    def __del__(self):
        print("circle gone")

    def area(self):
        return 3 * self.r * self.r

    def name(self):
        return "circle"

    def grow(self, by):
        self.r += by


def overdrawn():
    return s.bank_error(s.bank_error.OVERDRAWN)


def error_of(f):
    """the name of the Error f raises"""
    try:
        f()
    except s.Error as e:
        return e.name
    return "no error"


def never(x):
    raise overdrawn()


# what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
def extras():
    ok = s.checked(lambda x: None, 1) is None
    print("checked", str(ok).lower(), error_of(lambda: s.checked(never, 1)))
    lim = s.limiter()
    print("limit", str(lim(3) is None).lower(), error_of(lambda: lim(12)))
    sign = s.labeler()
    print("sign", sign(5), sign(-1))


# lists (Python lists both ways), slices of text and handles, None for optional text and handles
def lists():
    a = s.account.open("ann")
    a.deposit(5)
    b = s.account.open("bobby")
    b.deposit(9)
    both = [a, b]
    names = s.owners(both)
    print("owners", len(names), names[0], names[1])
    print("richest", s.richest(both), end="")
    print(" after", a.get(), b.get())
    opened = s.open_all(["cy", "dee"])
    print("opened", len(opened), opened[1].owner())
    del opened
    sq = s.squares_upto(4)
    print("squares", len(sq), sq[3], "sum", s.sum_all(sq))
    parts = ["a", "b", "c"]
    print("joined", s.joined(parts, "-"), "total", s.total_len(parts))
    print("%s; %s" % (s.greeting("ann"), s.greeting(None)))
    n1, n2 = s.nickname(a), s.nickname(b)
    print("nick", int(n1 is not None), n1, int(n2 is not None))
    c = s.open_if("eve", True)
    d = s.open_if("x", False)
    print("open_if", int(c is not None), int(d is None))
    print("close_if", s.close_if(c), s.close_if(None))
    print("close_all", s.close_all(both))
    print("some", s.count_some([1, None, 3]))
    print("lists closed", s.closed_accounts())


def twice(x):
    if x > 5:
        raise overdrawn()
    return x * 2


def made_by(owner):
    b = s.account.open(owner)
    b.deposit(7)
    return b


def main():
    extras()
    print("biggest", s.biggest_i32([3, 9, 4]), s.biggest_f64([1.5, 0.5]))
    a = s.account.open("ann")
    a.deposit(250)
    a.rename("bea")
    n = a.deposit(50)
    print("account", a.owner(), n)
    n = s.visit(a, lambda b: b.deposit(1))
    print("visit", n, "get", a.get())
    n = s.close_account(a)
    print("closed", n, s.closed_accounts())
    c = Circle(1)
    print(s.describe(c))
    print("grown %g" % s.grow_twice(Circle(1)))
    sq = s.make_square(2)
    sq.grow(1)
    print(sq.name(), "%g" % sq.area(), s.describe(sq))
    print(s.shout(lambda t: t + "!", "hey"))
    print("try", s.try_twice(twice, 1), end="")
    print("", error_of(lambda: s.try_twice(twice, 4)))
    print("opened", s.opened_by(made_by))
    print("closed", s.closed_accounts())
    d = s.doubler()
    hi = s.greeter()
    print(d(21), hi("volt"))
    lists()


main()
# the library's allocations still live (a --leak-check build counts them): 0 when it freed everything
print("volt live:", ctypes.c_size_t.in_dll(s._lib, "volt_live_allocs").value, file=sys.stderr)
