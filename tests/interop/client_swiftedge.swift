// Swift calls swiftedge (voltc bindings --lang swift): the shapes shapelib doesn't have
final class Counter: counter {
    var total: Int64 = 0

    func close_() -> Int64 {
        return 1000
    }

    func bump(_ by: Int64) throws -> Int64 {
        if by > 100 {
            throw bad.WORSE
        }
        total += by
        return total
    }

    func label(_ t: thing, _ prefix: String) -> String {
        return prefix + String(t.n())
    }

    func first() -> String {
        return "swift"
    }
}

struct Odd: Error {}

func failure(_ body: () throws -> Void) -> String {
    do {
        try body()
        return "none"
    } catch {
        return "\(error)"
    }
}

func opt<T>(_ v: T?) -> String {
    return v.map { "\($0)" } ?? "nil"
}

func main() throws {
    let t = thing(4)
    var ys: [Int64] = [1, 2, 3]
    print("names", t.close_(), tally(&ys).total())
    print("count_text", count_text(["ab", nil, "c"]), "sum_things", sum_things([t, nil, thing(5)]))
    var xs: [Int32] = [1, 2, 3]
    let k = slice_cb({ b in
        b[0] = 9
        return Int32(b.count)
    }, &xs)
    print("slice_cb", k, xs)
    print("cstr_cb", cstr_cb({ s in s.map { $0 + "!" } }), cstr_cb({ _ in nil }))
    print("str_cb", str_cb({ n in String(repeating: "x", count: Int(n)) }))
    print("enum_cb", enum_cb({ $0 == .RED ? .BLUE : .GREEN }))
    print("point_cb", point_cb({ p in point(x: p.x * 10, y: p.y) }))
    print("str_result_cb", try str_result_cb({ _ in "four" }), try str_result_cb({ _ in throw bad.NOPE }), failure { _ = try str_result_cb({ _ in throw Odd() }) })
    print("any_cb", try any_cb({ $0 + 1 }), failure { _ = try any_cb({ _ in throw bad.WORSE }) }, failure { _ = try any_cb({ _ in throw Odd() }) })
    print("swallow", try swallow({ $0 }), failure { _ = try swallow({ _ in throw Odd() }) }, try swallow({ _ in throw bad.NOPE }))
    print("lent_ptr_cb", lent_ptr_cb({ $0?.n() ?? -1 }, t), lent_ptr_cb({ $0?.n() ?? -1 }, nil))
    let c = Counter()
    print("run_counter", try run_counter(c, t), c.total)
    print("give_counter", try give_counter(Counter()))
    let vc = volts_counter()
    print("volts", try vc.bump(3), vc.label(t, "t"), vc.first(), failure { _ = try vc.bump(-1) })
    print("run volts", try run_counter(vc, t), "give volts", try give_counter(vc))
    let nm = namer()
    print("namer", nm(t, "n"), taker()(thing(8)), hands { $0.n() }, measurer()("four"))
    print("colors", colors().map { "\($0)" }, take_colors([.BLUE, .GREEN]))
    print("maybes", maybes().map { opt($0) }, take_maybes([1, nil]))
    print("opt_point", opt_point(point(x: 1, y: 2)).map { "\($0.x) \($0.y)" } ?? "nil", opt_point(nil) == nil)
    print("opt_color", opt(opt_color(.RED)), opt(opt_color(.BLUE)))
    print("maybe_str", opt(maybe_str(true)), opt(maybe_str(false)))
    var cs: [UInt8] = [0, 1]
    print("enum_slice", enum_slice(&cs))
    print("listy", try listy(true), failure { _ = try listy(false) })
    print("mk_thing", try mk_thing(true).n(), failure { _ = try mk_thing(false) })
    print("mk_counter", try mk_counter(true).bump(1), failure { _ = try mk_counter(false) })
    print("texts_in", texts_in(["a", "b"]), "maybe_thing", maybe_thing(t), maybe_thing(nil))
    withExtendedLifetime(t) {}
}

try main()
