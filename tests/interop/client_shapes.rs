// Rust calls shapelib (voltc bindings --lang rust): a generic's instances, a struct held by a type
// with methods, owned values passed in, a Volt trait as a Rust trait both ways, closures taking and
// giving text and handles, and closures given back as Box<dyn FnMut>
mod shapelib;
use shapelib::*;

struct Circle {
    r: f64,
}

impl Drop for Circle {
    fn drop(&mut self) {
        println!("circle gone");
    }
}

impl shape for Circle {
    fn area(&mut self) -> f64 {
        3.0 * self.r * self.r
    }
    fn name(&mut self) -> String {
        "circle".to_string()
    }
    fn grow(&mut self, by: f64) {
        self.r += by;
    }
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
fn extras() {
    let ok = checked(|x| if x > 0 { Ok(()) } else { Err(Error { code: bank_error::OVERDRAWN }) }, 1).is_ok();
    println!("checked {} {}", ok, checked(|_| Err(Error { code: bank_error::OVERDRAWN }), 1).unwrap_err());
    let mut lim = limiter();
    println!("limit {} {}", lim(3).is_ok(), lim(12).unwrap_err());
    let mut sign = labeler();
    println!("sign {} {}", sign(5), sign(-1));
}

// lists (Vec both ways), slices of text and handles, Option text and handles
fn lists() {
    let mut ab = vec![account::open("ann"), account::open("bobby")];
    ab[0].deposit(5);
    ab[1].deposit(9);
    let os = owners(&mut ab);
    println!("owners {} {} {}", os.len(), os[0], os[1]);
    print!("richest {}", richest(&mut ab));
    println!(" after {} {}", ab[0].get(), ab[1].get());
    let opened = open_all(&["cy", "dee"][..]);
    println!("opened {} {}", opened.len(), opened[1].owner());
    drop(opened);
    let sq = squares_upto(4);
    println!("squares {} {} sum {}", sq.len(), sq[3], sum_all(sq.clone()));
    let parts = ["a", "b", "c"];
    println!("joined {} total {}", joined(&parts[..], "-"), total_len(&parts[..]));
    println!("{}; {}", greeting(Some("ann")), greeting(None));
    let (n1, n2) = (nickname(&ab[0]), nickname(&ab[1]));
    println!("nick {} {} {}", n1.is_some() as i32, n1.unwrap_or_default(), n2.is_some() as i32);
    let c = open_if("eve", true);
    let d = open_if("x", false);
    println!("open_if {} {}", c.is_some() as i32, d.is_none() as i32);
    let c1 = close_if(c);
    println!("close_if {} {}", c1, close_if(None));
    println!("close_all {}", close_all(ab));
    println!("some {}", count_some(&mut [VoltOpt::from(Some(1)), VoltOpt::from(None), VoltOpt::from(Some(3))]));
    let (mut r1, mut r2) = ([1i64, 2], [3i64]);
    println!("rows {}", total_rows(&mut [VoltSlice::from(&mut r1[..]), VoltSlice::from(&mut r2[..])]));
    let (rot, sw, bu) = (rotated([11, 12, 13]), swapped([1.5, 2.5]), bumped([1, 2, 3]));
    println!("arrays {} {} {} {} {} {} {} {}", rot[0], rot[1], rot[2], sw[0], sw[1], bu[0], bu[1], bu[2]);
    struct Tg;
    impl tagged for Tg {
        fn r#type(&mut self) -> i32 {
            1
        }
        fn from(&mut self, x: i32) -> i32 {
            x + 1
        }
        fn int(&mut self) -> i32 {
            2
        }
        fn close(&mut self) -> i32 {
            3
        }
    }
    let mut tv = make_tagged(5);
    let (a, b, c, d) = (tv.r#type(), tv.from(4), tv.int(), tv.close());
    println!("tagged {} {} {} {} {} {}", tagged_sum(&mut Tg), a, b, c, d, tagged_sum(&mut *tv));
    println!("lists closed {}", closed_accounts());
}

fn main() {
    extras();
    println!("biggest {} {}", biggest_i32(&mut [3, 9, 4]), biggest_f64(&mut [1.5, 0.5]));
    let a = account::open("ann");
    a.deposit(250);
    a.rename("bea");
    let n = a.deposit(50);
    println!("account {} {}", a.owner(), n);
    let n = visit(&a, |b| b.deposit(1));
    println!("visit {} get {}", n, a.get());
    let n = close_account(a);
    println!("closed {} {}", n, closed_accounts());
    let mut c = Circle { r: 1.0 };
    println!("{}", describe(&mut c));
    let g = grow_twice(Box::new(Circle { r: 1.0 }));
    println!("grown {}", g);
    let mut sq = make_square(2.0);
    sq.grow(1.0);
    let (name, area) = (sq.name(), sq.area());
    println!("{} {} {}", name, area, describe(&mut *sq));
    println!("{}", shout(|s| s + "!", "hey"));
    let twice = |x: i32| if x > 5 { Err(Error { code: bank_error::OVERDRAWN }) } else { Ok(x * 2) };
    print!("try {}", try_twice(twice, 1).unwrap());
    println!(" {}", try_twice(twice, 4).unwrap_err());
    let n = opened_by(|owner| {
        let b = account::open(owner);
        b.deposit(7);
        b
    });
    println!("opened {}", n);
    println!("closed {}", closed_accounts());
    let mut d = doubler();
    let mut hi = greeter();
    println!("{} {}", d(21), hi("volt"));
    lists();
}
