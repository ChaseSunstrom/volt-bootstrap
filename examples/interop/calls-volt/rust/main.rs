// Rust calls the Volt library greet through its Rust module (bindings/greet.rs): owned text comes
// back as String, an export struct is a type that frees itself when dropped
#[path = "../greet/target/debug/bindings/greet.rs"]
mod greet;

fn main() {
    println!("add {}", greet::add(2, 3));
    println!("{}", greet::hello("volt"));
    let c = greet::tally::new("clicks");
    c.add(1);
    let n = c.add(2);
    println!("{} {}", c.name(), n);
}
