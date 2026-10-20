// error: 'later' is async, so it needs a body: Volt runs an async fn's frame, and a C function has none
extern "C" async fn later() -> i32;
fn main() -> void { later(); }
