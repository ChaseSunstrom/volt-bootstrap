struct s { a: i32; }
fn main() -> void { val x: s = { a: 1 }; x.zap(); }
// error: s has no method 'zap'
