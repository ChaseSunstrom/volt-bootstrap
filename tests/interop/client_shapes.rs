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
}
