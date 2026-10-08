// Swift calls shapelib (voltc bindings --lang swift): a generic's instances, a struct held by a
// class with methods, owned values passed in, a Volt trait as a Swift protocol both ways, closures
// taking and giving text and handles, and closures given back as callable classes
final class Circle: shape {
    var r: Double

    init(_ r: Double) {
        self.r = r
    }

    deinit {
        print("circle gone")
    }

    func area() -> Double {
        return 3 * r * r
    }

    func name() -> String {
        return "circle"
    }

    func grow(_ by: Double) {
        r += by
    }
}

struct Odd: Error {}

func n(_ v: Double) -> String {
    let i = Int(v)
    return Double(i) == v ? String(i) : String(v)
}

func failure(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "none"
    } catch {
        return "\(error)"
    }
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
func extras() throws {
    try checked({ x in
        if x <= 0 {
            throw bank_error.OVERDRAWN
        }
    }, 1)
    print("checked", true, failure { try checked({ _ in throw bank_error.OVERDRAWN }, 1) })
    let lim = limiter()
    print("limit", (try? lim(3)) != nil, failure { try lim(12) })
    let sign = labeler()
    print("sign", sign(5), sign(-1))
}

// lists ([T] both ways), slices of text and handles, optional text and handles
func lists() {
    let ab = [account.open("ann"), account.open("bobby")]
    _ = ab[0].deposit(5)
    _ = ab[1].deposit(9)
    let os = owners(ab)
    print("owners", os.count, os[0], os[1])
    print("richest", richest(ab), terminator: "")
    print(" after", ab[0].get(), ab[1].get())
    let opened = open_all(["cy", "dee"])
    print("opened", opened.count, opened[1].owner())
    opened.forEach { $0.close() }
    let sq = squares_upto(4)
    print("squares", sq.count, sq[3], "sum", sum_all(sq))
    print("joined", joined(["a", "b", "c"], "-"), "total", total_len(["a", "b", "c"]))
    print("\(greeting("ann")); \(greeting(nil))")
    let n1 = nickname(ab[0])
    let n2 = nickname(ab[1])
    print("nick", n1 != nil ? 1 : 0, n1 ?? "", n2 != nil ? 1 : 0)
    let c = open_if("eve", true)
    let d = open_if("x", false)
    print("open_if", c != nil ? 1 : 0, d == nil ? 1 : 0)
    let c1 = close_if(c)
    print("close_if", c1, close_if(nil))
    print("close_all", close_all(ab))
    var some: [Int64?] = [1, nil, 3]
    print("some", count_some(&some))
    print("lists closed", closed_accounts())
}

// what only Swift checks: an error a callback throws that isn't Volt's comes out of the call
func checks() {
    print("thrown", failure { _ = try try_twice({ _ in throw Odd() }, 1) })
}

// what Swift refuses (each ends the program, as a failed precondition does): closing or giving away
// a handle a running call holds, giving one twice, giving away one Volt lent a callback
func refuse(_ what: String) {
    let a = account.open("zed")
    switch what {
    case "busy":
        _ = visit(a) { _ in
            a.close()
            return 0
        }
    case "held":
        _ = visit(a) { _ in close_account(a) }
    case "twice":
        _ = close_all([a, a])
    default:
        _ = visit(a) { b in close_account(b) }
    }
}

func main() throws {
    try extras()
    var xs: [Int32] = [3, 9, 4]
    var ys = [1.5, 0.5]
    print("biggest", biggest_i32(&xs), n(biggest_f64(&ys)))
    let a = account.open("ann")
    _ = a.deposit(250)
    a.rename("bea")
    let m = a.deposit(50)
    print("account", a.owner(), m)
    let v = visit(a) { b in b.deposit(1) }
    print("visit", v, "get", a.get())
    let k = close_account(a)
    print("closed", k, closed_accounts())
    let c = Circle(1)
    print(describe(c))
    let g = grow_twice(Circle(1))
    print("grown", n(g))
    let sq = make_square(2)
    sq.grow(1)
    print(sq.name(), n(sq.area()), describe(sq))
    print(shout({ $0 + "!" }, "hey"))
    let twice = { (x: Int32) throws -> Int32 in
        if x > 5 {
            throw bank_error.OVERDRAWN
        }
        return x * 2
    }
    print("try", try try_twice(twice, 1), terminator: "")
    print("", failure { _ = try try_twice(twice, 4) })
    let o = opened_by { owner in
        let b = account.open(owner)
        _ = b.deposit(7)
        return b
    }
    print("opened", o)
    print("closed", closed_accounts())
    let d = doubler()
    let hi = greeter()
    print(d(21), hi("volt"))
    lists()
    withExtendedLifetime(c) {}
}

if CommandLine.arguments.count > 1 {
    refuse(CommandLine.arguments[1])
} else {
    try main()
    checks()
}
