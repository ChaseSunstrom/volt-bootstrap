// flags: --leak-check
use std::io;
use std::string;
use std::text;
// std collections: the eq/cmp protocol, slice algorithms, vec and map additions, set, deque, heap, sorted_map

struct task {
    pri: i32;
    name: str;
}

// ordered by priority only, so equal priorities show that sort is stable
attach fn cmp(this: task&, other: task&) -> i32 {
    return this.pri.cmp(&other.pri);
}

fn s(text: str) -> std::string {
    return std::string::from(text);
}

fn show(xs: i32[..]) -> void {
    for (x, i) in xs {
        if (i > 0) {
            std::print(" ");
        }
        std::print("{}", x);
    }
    std::println("");
}

fn main() -> void {
    // slices: sort (20 elements: insertion-sorted runs, then a merge), search, reverse, min/max
    var nums: i32[] = { 5, -2, 9, 0, 5, 3, 12, -7, 1, 8, 4, 6, 2, 11, 10, 7, 13, -1, 14, 15 };
    val all = nums[..];
    std::println("{} {} {}", all.is_sorted(), *all.min(), *all.max());
    all.sort();
    show(all);
    std::println("{} {} {} {} {}", all.is_sorted(), all.binary_search(9), all.binary_search(16), all.lower_bound(5), all.lower_bound(100));
    all.reverse();
    std::println("{} {} {} {} {}", all[0], all[19], all.contains(-7), all.index_of(5), all.contains(99));
    all.swap(0, 19);
    val empty: i32[0];
    std::println("{} {} {}", all[0], all[19], empty[..].min() == null);

    // a user type with its own cmp: sort is stable; sort_by takes any comparison
    var tasks: task[] = { { pri: 2, name: "b1" }, { pri: 1, name: "a1" }, { pri: 2, name: "b2" }, { pri: 0, name: "z" }, { pri: 1, name: "a2" } };
    tasks[..].sort();
    std::println("{} {} {} {} {}", tasks[0].name, tasks[1].name, tasks[2].name, tasks[3].name, tasks[4].name);
    tasks[..].sort_by(|| (a: task&, b: task&) -> i32 { return b.name.cmp(a.name); });
    std::println("{} {} {} {} {}", tasks[0].name, tasks[1].name, tasks[2].name, tasks[3].name, tasks[4].name);

    // owned strings sort and dedup through std::string's cmp and eq
    val split = "pear fig apple fig banana".words();
    var words: std::vec<std::string> = {};
    for (w) in split.items() {
        words.push(s(w)) catch @panic("out of memory");
    }
    words.items().sort();
    words.dedup();
    std::println("{} {} {} {}", words.len, words.at(0).as_str(), words.at(2).as_str(), words.items().binary_search(s("pear")));

    // vec editing
    val base: i32[] = { 1, 2, 3, 4, 5 };
    var v: std::vec<i32> = {};
    v.extend(base[..]) catch @panic("out of memory");
    v.insert(0, 0) catch @panic("out of memory");
    v.insert(6, 6) catch @panic("out of memory");
    v.insert(3, 99) catch @panic("out of memory");
    val r = v.remove(3);
    val sr = v.swap_remove(1);
    show(v.items());
    v.retain(|| (x: i32&) -> bool { return *x % 2 == 0; });
    v.truncate(3);
    show(v.items());
    std::println("{} {} {} {}", r, sr, *v.first(), *v.last());
    // the same with owned elements, so a lost or doubled element shows in the leak check
    var sv: std::vec<std::string> = {};
    sv.extend(words.items()) catch @panic("out of memory");
    sv.insert(1, s("kiwi")) catch @panic("out of memory");
    val sv_r = sv.remove(0);
    val sv_sr = sv.swap_remove(0);
    sv.retain(|| (x: std::string&) -> bool { return x.as_str() != "fig"; });
    sv.push(s("lime")) catch @panic("out of memory");
    sv.truncate(2);
    std::println("{} {} {} {} {}", sv_r.as_str(), sv_sr.as_str(), sv.len, sv.at(0).as_str(), sv.at(1).as_str());

    // map: std::string keys, iteration by reference, contains, clear
    var ages: std::map<std::string, i32> = {};
    ages.put(s("ann"), 31);
    ages.put(s("bob"), 42);
    ages.put(s("ann"), 32);
    var total = 0;
    for (e) in ages.iter() {
        total += *e.value;
        *e.value += 1;
    }
    std::println("{} {} {} {}", ages.len, total, *(ages.get(s("ann")) ?? return), ages.contains(s("cy")));
    ages.clear();
    std::println("{} {}", ages.len, ages.contains(s("ann")));
    ages.put(s("dee"), 1);
    std::println("{}", *(ages.get(s("dee")) ?? return));

    // set
    var seen: std::set<std::string> = {};
    val added = seen.add(s("x"));
    val again = seen.add(s("x"));
    val other = seen.add(s("y"));
    std::println("{} {} {} {} {}", added, again, other, seen.len(), seen.contains(s("y")));
    val removed = seen.remove(s("x"));
    val missing = seen.remove(s("x"));
    for (k) in seen.iter() {
        std::println("{} {} {}", removed, missing, k.as_str());
    }

    // deque: both ends, wrapping around the ring, growing while wrapped
    var dq: std::deque<i32> = {};
    for (i) in 0..10 {
        dq.push_back(i);
    }
    dq.push_front(-1);
    dq.push_front(-2);
    val a = dq.pop_front() ?? 0;
    val b = dq.pop_back() ?? 0;
    for (x) in dq.iter() {
        *x *= 2;
    }
    std::println("{} {} {} {} {} {}", a, b, dq.len, *dq.front(), *dq.back(), *dq.at(3));
    for (i) in 0..7 {
        dq.push_back(100 + i);
    }
    std::println("{} {} {} {} {}", dq.len, *dq.front(), *dq.at(9), *dq.at(10), *dq.back());
    var names: std::deque<std::string> = {};
    names.push_back(s("mid"));
    names.push_front(s("head"));
    names.push_back(s("tail"));
    val names2 = copy names;
    std::println("{} {} {}", names2.len, names2.front()->as_str(), names2.back()->as_str());
    val nf = names.pop_front() ?? s("?");
    val nb = names.pop_back() ?? s("?");
    names.push_front(s("new"));
    std::println("{} {} {} {}", nf.as_str(), nb.as_str(), names.len, names.front()->as_str());

    // heap: smallest first
    var h: std::heap<i32> = {};
    val order: i32[] = { 5, 1, 8, 3, 9, 2 };
    for (x) in order {
        h.push(x);
    }
    std::println("{} {}", h.len(), *h.peek());
    var out: std::vec<i32> = {};
    loop {
        val x = h.pop() ?? break;
        out.push(x) catch @panic("out of memory");
    }
    show(out.items());
    var jobs: std::heap<std::string> = {};
    jobs.push(s("write"));
    jobs.push(s("build"));
    jobs.push(s("test"));
    val jobs2 = copy jobs;
    std::println("{} {}", jobs2.len(), jobs2.peek()->as_str());
    jobs.push(s("deploy"));
    loop {
        val job = jobs.pop() ?? break;
        std::print("{} ", job.as_str());
    }
    std::println("{}", jobs.len());

    // sorted_map: kept in key order
    var sm: std::sorted_map<std::string, i32> = {};
    sm.put(s("pear"), 3);
    sm.put(s("apple"), 1);
    sm.put(s("fig"), 2);
    sm.put(s("apple"), 10);
    val gone = sm.remove(s("pear")) ?? 0;
    for (e, i) in sm.iter() {
        if (i > 0) {
            std::print(" ");
        }
        std::print("{}={}", e.key.as_str(), *e.value);
    }
    std::println("");
    val sm2 = copy sm;
    std::println("{} {} {} {} {}", sm2.len(), gone, sm2.contains(s("fig")), *(sm2.get(s("apple")) ?? return), sm2.get(s("pear")) == null);
}
// expect: false -7 15
// expect: -7 -2 -1 0 1 2 3 4 5 5 6 7 8 9 10 11 12 13 14 15
// expect: true 13 null 8 20
// expect: 15 -7 true 10 false
// expect: -7 15 true
// expect: z a1 a2 b1 b2
// expect: z b2 b1 a2 a1
// expect: 4 apple fig 3
// expect: 0 6 2 3 4 5
// expect: 0 6 2
// expect: 99 1 0 2
// expect: apple kiwi 2 pear banana
// expect: 2 74 33 false
// expect: 0 false
// expect: 1
// expect: true false true 2 true
// expect: true false y
// expect: -2 9 10 -2 16 4
// expect: 17 -2 16 100 106
// expect: 3 head tail
// expect: head tail 2 new
// expect: 6 1
// expect: 1 2 3 5 8 9
// expect: 3 build
// expect: build deploy test write 0
// expect: apple=10 fig=2
// expect: 2 3 true 10 true
