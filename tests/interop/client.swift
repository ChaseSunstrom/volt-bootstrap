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
// structs with text, an array and a struct in them (in, out, in an array, from a closure), one with a
// pointer, E!T as a parameter (a Result)
let la = ml_label(name: "ab", sizes: (1, 2, 3), at: vec2(x: 7, y: 0))
print("label", ml_label_len(la))
var lb = ml_label_of("ab", 3)
print("label_of", lb.name, lb.sizes.0, lb.sizes.1, lb.sizes.2, lb.at.x)
var ls = [la, lb]
print("labels", ml_labels_len(&ls))
print("holder", ml_holder_k(ml_holder(p: nil, k: 3)))
print("or", ml_or(.success(4.5), 9.5), ml_or(.failure(math_error.NEGATIVE), 9.5))
print("ask", ml_ask { k in ml_label(name: "abc", sizes: (k, k, k), at: vec2(x: 3, y: 0)) })
ml_relabel(&lb, 4)
print("relabel", lb.name, lb.sizes.0, lb.sizes.1, lb.sizes.2)
print("count", ml_labels_count([la, lb]))
print("note", ml_note_len(ml_note(str: "abc", c: 1, k: 3)))
print("or_label", ml_or_label(.success(la)), ml_or_label(.failure(math_error.NEGATIVE)))
print("given", ml_sum_given(3) { k in [Int64(k), 10 * Int64(k)] }, ml_area_given { k in [vec2(x: 1.5, y: Double(k)), vec2(x: 2, y: 3.25)] })
var deep: [[[Int64]]] = [[[1, 2], [3]], [[4]]]
let d = ml_deep(&deep)
print("deep", d, deep[0][0][1], deep[1][0][0], "words", ml_words([["ab", "c"], [], ["def"]]))
print("text_given", ml_text_given { _ in ["ab", "cde"] }, ml_labels_given { k in [ml_label(name: "abc", sizes: (k, k, k), at: vec2(x: 3, y: 0)), ml_label(name: "de", sizes: (1, 1, 1), at: vec2(x: 0, y: 0))] })
print("turn", ml_turn { a in [a[2], a[1], a[0]] })
final class Turner: ml_turner {
    func turn(_ a: [Int32]) -> [Int32] { [a[2], a[1], a[0]] }
}
print("turner", ml_turned(Turner()), "flipped", ml_flipped(ml_flipper()))
let po = ml_pair_of("ab", "cd")
let shelf = ml_shelf(labels: (ml_label(name: "abc", sizes: (2, 2, 2), at: vec2(x: 3, y: 0)), ml_label(name: "de", sizes: (1, 1, 1), at: vec2(x: 0, y: 0))), k: 1)
var backs = [shelf.labels.0, shelf.labels.1]
let bk = ml_labels_back(&backs)
print("pair", ml_pair_len(ml_pair(names: ("ab", "cde"), n: 1)), po.names.0, po.names.1, "shelf", ml_shelf_len(shelf), "back", bk.count, bk[0].name)
