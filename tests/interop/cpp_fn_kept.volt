// cpp_fn_kept.hpp: a closure given to a std::function parameter taken by value moves in, and C++
// may keep and call it after the Volt scope that made it is gone (its captures deleted with the last
// copy); a plain fn or a fn value is lent
use std::io;
use { "cpp_fn_kept.hpp" } as cpp;
fn arm(b: cpp::fk::Button&) -> void {
    val word = std::string::from("clicks");
    b.on_click(|move word| (n: i32) -> i32 { return @cast<i32>(word.len()) + n; });
}
fn twice(x: i32) -> i32 { return x * 2; }
// says when the closure keeping it is deleted
struct probe {
    n: i32;
}
attach fn delete(this: probe&) -> void { std::println("dropped {}", this.n); }
fn main() -> void {
    var b = cpp::fk::Button::new();
    arm(&b);
    std::println("click {}", b.click(4));
    std::println("click {}", b.click(10));
    b.clear();
    std::println("cleared {}", b.click(1));
    {
        val tag = std::string::from("ab");
        val p: probe = { n: 7 };
        cpp::fk::keep(|move tag, move p| () -> i32 { return @cast<i32>(tag.len()) + p.n * 0; });
    }
    std::println("scope done");
    std::println("kept {}", cpp::fk::run_kept());
    std::println("plain {}", cpp::fk::apply_now(twice, 5));
    val f: fn(i32) -> i32 = twice;
    std::println("value {}", cpp::fk::apply_now(f, 6));
}
