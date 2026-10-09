// Swift calls the Volt library through voltc bindings --lang swift, over the C header (module
// Cmathlib): errors are thrown as their error set's enum, owned text comes back as a String, an
// export struct is a class (close(), or deinit, frees it)
func n(_ v: Double) -> String {
    let i = Int(v)
    return Double(i) == v ? String(i) : String(v)
}

print("add", ml_add(2, 3))
var a = vec2(x: 1, y: 2)
let b = vec2(x: 3, y: 4)
print("dot", n(ml_dot(a, b)))
ml_scale(&a, 2)
print("scale", n(a.x), n(a.y))
print("len", ml_len("hello"))
print("clash", ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14))
var tg = ml_tags_make()
let head = "tags \(tg.from) \(tg.type) \(tg.`self`) \(tg.int_)"
tg.int_ = 5
print(head, ml_tags_sum(tg))
var bp: Int32 = 7
var bq = 2.5
ml_bump(&bp, &bq)
print("bump", bp, n(bq))
print("next", ml_next(.GREEN).rawValue)
print("sqrt", n(try ml_sqrt(9)), 1)
do {
    _ = try ml_sqrt(-1)
} catch math_error.NEGATIVE {
    print("error", "negative")
}
print("greet", ml_greet("volt"))
print("repeat", try ml_repeat("ab", 2))
do {
    _ = try ml_repeat("ab", -1)
} catch {
    print("repeat", "\(error)".lowercased())
}
var xs = [1, 2, 3.5]
print("sum", n(ml_sum(&xs)))
var ys: [Int32] = [4, 5, 6]
print("find", ml_find(&ys, 6)!, ml_find(&ys, 9) == nil ? "none" : "?")
var seen: [Int32] = []
ml_each(&ys) { seen.append($0) }
print("each", seen.map { String($0) }.joined(separator: " "), "=", seen.reduce(0, +))
let c = counter("clicks")
_ = c.add(2)
print("counter", c.name(), c.add(3))
do {
    _ = try c.take(9)
} catch let e as math_error {
    print("take", "\(e)".lowercased())
}
c.close()
