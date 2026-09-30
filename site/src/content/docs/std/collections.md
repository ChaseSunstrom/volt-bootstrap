---
title: Collections and algorithms
description: vec, map, set, sorted_map, deque and heap; sorting and searching slices; and how they compare values.
sidebar:
  order: 2
---

| You need | Use |
| --- | --- |
| a list that grows | `std::vec<T>` |
| values by key | `std::map<K, V>` (hashed, any order) or `std::sorted_map<K, V>` (walks keys in order) |
| a collection of distinct values | `std::set<T>` |
| a queue, or a stack you use from both ends | `std::deque<T>` |
| the smallest item first (a priority queue) | `std::heap<T>` |

Each owns what it holds: putting a value in moves it, and deleting the collection deletes its
contents. `copy` makes a deep copy.

## Comparing values: eq, cmp and hash

Collections and algorithms don't use `==` and `<` directly. They call methods:

- `eq(this: T&, other: T&) -> bool` to match values (map and set keys, `contains`, `dedup`);
- `cmp(this: T&, other: T&) -> i32` to order them, negative when `this` sorts first (sorting,
  `binary_search`, `min`, `max`, `heap`, `sorted_map`);
- `hash(this: T&) -> u64` to place keys in `map` and `set`.

std gives every type with `==` and `<` its `eq` and `cmp` (numbers, `bool`, `str`, pointers), and
`std::string` has all three. A type of your own attaches the ones it needs, and they're used instead:

```volt
use std::io;

struct version {
    major: i32;
    minor: i32;
}

attach fn cmp(this: version&, other: version&) -> i32 {
    if (this.major != other.major) {
        return this.major.cmp(&other.major);
    }
    return this.minor.cmp(&other.minor);
}

fn main() -> void {
    var vs: version[] = { { major: 1, minor: 10 }, { major: 0, minor: 9 }, { major: 1, minor: 2 } };
    vs[..].sort();
    val newest = vs[..].max() ?? return;
    std::println("{}.{} {}.{}", vs[0].major, vs[0].minor, newest->major, newest->minor);
}
// expect: 0.9 1.10
```

These are ordinary std methods found by name, so [your own std](/volt-bootstrap/std/overview/#your-own-std)
can define them differently.

## Slices: sorting and searching

The algorithms work on any `T[..]`, so on arrays (`a[..]`) and vecs (`v.items()`) alike. `sort` is
stable: equal elements keep their order. `sort_by` takes a comparison instead of `cmp`.

```volt
use std::io;

fn main() -> void {
    var xs: i32[] = { 40, 10, 30, 20 };
    val s = xs[..];
    s.sort();
    std::println("{} {} {} {}", s[0], s.binary_search(30), s.binary_search(35), s.lower_bound(35));
    s.sort_by(|| (a: i32&, b: i32&) -> i32 { return b.cmp(a); }); // largest first
    s.reverse();
    std::println("{} {} {} {}", s[0], *s.min(), s.contains(20), s.index_of(40));
}
// expect: 10 2 null 3
// expect: 10 10 true 3
```

`binary_search` gives an index holding the value, or `null`; `lower_bound` gives where it would go.
`min` and `max` return a pointer to the element, `null` for an empty slice.

## vec

Besides `push`, `pop` and `at`, a vec edits in the middle: `insert` and `remove` move the elements
after the index; `swap_remove` fills the hole with the last element instead, so it's O(1).

```volt
use std::io;

fn main() -> !void {
    var v: std::vec<i32> = {};
    val start: i32[] = { 3, 1, 1, 4, 1, 5 };
    try v.extend(start[..]);
    try v.insert(0, 9);
    val gone = v.remove(1);
    v.dedup();                                            // 9 1 4 1 5
    v.retain(|| (x: i32&) -> bool { return *x != 1; });   // 9 4 5
    std::println("{} {} {} {}", gone, v.len, *(v.first() ?? return), *(v.last() ?? return));
}
// expect: 3 3 9 5
```

## map and set

```volt
use std::io;

fn main() -> void {
    var counts: std::map<std::string, i32> = {};
    val words = "to be or not to be".words();
    for (w) in words.items() {
        val slot = counts.get(std::string::from(w));
        if (slot) {
            *slot += 1;
        } else {
            counts.put(std::string::from(w), 1);
        }
    }
    var total = 0;
    for (e) in counts.iter() {
        total += *e.value;
    }
    var tags: std::set<str> = {};
    val first = tags.add("new");
    val again = tags.add("new");
    std::println("{} {} {} {} {}", counts.len, total, *(counts.get(std::string::from("be")) ?? return), first, again);
}
// expect: 4 6 2 true false
```

`iter()` gives each entry as `e.key` and `e.value`, references into the map (so `*e.value += 1`
changes it). A map walks in no particular order; a `sorted_map` walks in key order. Don't add or
remove entries while walking, and don't change a key through `e.key`.

## sorted_map, deque and heap

```volt
use std::io;

fn main() -> void {
    var ranks: std::sorted_map<str, i32> = {};
    ranks.put("carol", 3);
    ranks.put("alice", 1);
    ranks.put("bob", 2);
    for (e, i) in ranks.iter() {
        if (i > 0) {
            std::print(" ");
        }
        std::print("{}", *e.key);
    }
    std::println("");

    var q: std::deque<i32> = {};
    q.push_back(2);
    q.push_back(3);
    q.push_front(1);
    val front = q.pop_front() ?? 0;

    var todo: std::heap<i32> = {};
    todo.push(5);
    todo.push(1);
    todo.push(3);
    val next = todo.pop() ?? 0;
    std::println("{} {} {} {}", front, q.len, next, *(todo.peek() ?? return));
}
// expect: alice bob carol
// expect: 1 2 1 3
```

A `heap` pops its smallest element by `cmp`; for largest first, store a type whose `cmp` is
reversed. `sorted_map` keeps its keys in a sorted array, so lookups are a binary search but `put` and
`remove` move the keys after them.
