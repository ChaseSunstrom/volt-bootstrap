// Rust calls the Volt library through voltc bindings --lang rust: errors come back as Err, owned
// text as String, an export struct is a type that frees itself when dropped
mod mathlib;
use mathlib::*;

struct Turner;

impl ml_turner for Turner {
    fn turn(&mut self, a: [i32; 3]) -> [i32; 3] {
        [a[2], a[1], a[0]]
    }
}

// an extern "C" fn Volt calls: it calls the one Volt gave out
static VOLT_FLIP: std::sync::OnceLock<extern "C" fn([i32; 3]) -> [i32; 3]> = std::sync::OnceLock::new();

#[allow(improper_ctypes_definitions)]
extern "C" fn flip(a: [i32; 3]) -> [i32; 3] {
    VOLT_FLIP.get().unwrap()(a)
}

fn main() {
    println!("add {}", ml_add(2, 3));
    let mut a = vec2 { x: 1.0, y: 2.0 };
    let b = vec2 { x: 3.0, y: 4.0 };
    println!("dot {}", ml_dot(a, b));
    ml_scale(&mut a, 2.0);
    println!("scale {} {}", a.x, a.y);
    println!("len {}", ml_len("hello"));
    println!("clash {}", ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14));
    let mut tg = ml_tags_make();
    print!("tags {} {} {} {}", tg.from, tg.r#type, tg.self_, tg.int);
    tg.int = 5;
    println!(" {}", ml_tags_sum(tg));
    let (mut bp, mut bq) = (7i32, 2.5f64);
    ml_bump(&mut bp, &mut bq);
    println!("bump {} {}", bp, bq);
    println!("next {}", ml_next(color::GREEN) as i32);
    println!("sqrt {} 1", ml_sqrt(9.0).unwrap());
    let e = ml_sqrt(-1.0).unwrap_err();
    println!("error {}", if e.code == math_error::NEGATIVE { "negative" } else { "?" });
    println!("greet {}", ml_greet("volt"));
    println!("repeat {}", ml_repeat("ab", 2).unwrap());
    println!("repeat {}", ml_repeat("ab", -1).unwrap_err().name().to_lowercase());
    println!("sum {}", ml_sum(&mut [1.0, 2.0, 3.5]));
    let mut ys = [4, 5, 6];
    let none = ml_find(&mut ys, 9).map_or("none".to_string(), |i| i.to_string());
    println!("find {} {}", ml_find(&mut ys, 6).unwrap(), none);
    let mut total = 0;
    print!("each");
    ml_each(&mut ys, &mut |x| {
        total += x;
        print!(" {}", x);
    });
    println!(" = {}", total);
    let c = counter::new("clicks");
    c.add(2);
    println!("counter {} {}", c.name(), c.add(3));
    println!("take {}", c.take(9).unwrap_err().to_string().to_lowercase());
    // structs with text, an array and a struct in them (in, out, in a slice, from a closure), one
    // with a pointer, E!T as a parameter
    let la = ml_label { name: VoltStr::from("ab"), sizes: [1, 2, 3], at: vec2 { x: 7.0, y: 0.0 } };
    println!("label {}", ml_label_len(la));
    let mut lb = ml_label_of("ab", 3);
    println!("label_of {} {} {} {} {}", unsafe { lb.name.as_str() }, lb.sizes[0], lb.sizes[1], lb.sizes[2], lb.at.x);
    println!("labels {}", ml_labels_len(&mut [la, lb]));
    println!("holder {}", ml_holder_k(ml_holder { p: std::ptr::null_mut(), k: 3 }));
    println!("or {} {}", ml_or(Ok(4.5), 9.5), ml_or(Err(Error { code: math_error::NEGATIVE }), 9.5));
    println!("ask {}", ml_ask(|k| ml_label { name: VoltStr::from("abc"), sizes: [k, k, k], at: vec2 { x: 3.0, y: 0.0 } }));
    ml_relabel(&mut lb, 4);
    println!("relabel {} {} {} {}", unsafe { lb.name.as_str() }, lb.sizes[0], lb.sizes[1], lb.sizes[2]);
    println!("count {}", ml_labels_count(vec![la, lb]));
    println!("note {}", ml_note_len(ml_note { str: VoltStr::from("abc"), c: 1, k: 3 }));
    println!("or_label {} {}", ml_or_label(Ok(la)), ml_or_label(Err(Error { code: math_error::NEGATIVE })));
    let mut given = [0i64; 2];
    let mut points = [vec2 { x: 0.0, y: 0.0 }; 2];
    let sum = ml_sum_given(3, |k| {
        given = [k as i64, 10 * k as i64];
        VoltSlice::from(&mut given)
    });
    let area = ml_area_given(|k| {
        points = [vec2 { x: 1.5, y: k as f64 }, vec2 { x: 2.0, y: 3.25 }];
        VoltSlice::from(&mut points)
    });
    println!("given {} {}", sum, area);
    let (mut d00, mut d01, mut d10) = ([1i64, 2], [3i64], [4i64]);
    let mut d0 = [VoltSlice::from(&mut d00[..]), VoltSlice::from(&mut d01[..])];
    let mut d1 = [VoltSlice::from(&mut d10[..])];
    let deep = ml_deep(&mut [VoltSlice::from(&mut d0[..]), VoltSlice::from(&mut d1[..])]);
    let mut w0 = [VoltStr::from("ab"), VoltStr::from("c")];
    let mut w2 = [VoltStr::from("def")];
    let words = ml_words(&mut [VoltSlice::from(&mut w0[..]), VoltSlice::from(&mut []), VoltSlice::from(&mut w2[..])]);
    println!("deep {} {} {} words {}", deep, d00[1], d10[0], words);
    let mut texts = [VoltStr::from("ab"), VoltStr::from("cde")];
    let text_n = ml_text_given(|_| VoltSlice::from(&mut texts[..]));
    let mut labels = [ml_label { name: VoltStr::from("abc"), sizes: [0; 3], at: vec2 { x: 3.0, y: 0.0 } }, ml_label { name: VoltStr::from("de"), sizes: [1, 1, 1], at: vec2 { x: 0.0, y: 0.0 } }];
    let labels_n = ml_labels_given(|k| {
        labels[0].sizes = [k, k, k];
        VoltSlice::from(&mut labels[..])
    });
    println!("text_given {} {}", text_n, labels_n);
    println!("turn {}", ml_turn(|a| [a[2], a[1], a[0]]));
    VOLT_FLIP.set(ml_flipper()).unwrap();
    println!("turner {} flipped {}", ml_turned(&mut Turner), ml_flipped(flip));
    let po = ml_pair_of("ab", "cd");
    let mut shelf = ml_shelf { labels: [ml_label { name: VoltStr::from("abc"), sizes: [2, 2, 2], at: vec2 { x: 3.0, y: 0.0 } }, ml_label { name: VoltStr::from("de"), sizes: [1, 1, 1], at: vec2 { x: 0.0, y: 0.0 } }], k: 1 };
    let shelf_n = ml_shelf_len(shelf);
    let bk = ml_labels_back(&mut shelf.labels);
    let pair_n = ml_pair_len(ml_pair { names: [VoltStr::from("ab"), VoltStr::from("cde")], n: 1 });
    println!("pair {} {} {} shelf {} back {} {}", pair_n, unsafe { po.names[0].as_str() }, unsafe { po.names[1].as_str() }, shelf_n, bk.len, unsafe { (*bk.ptr).name.as_str() });
}
