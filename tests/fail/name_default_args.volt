// an instance's name leaves out generic arguments equal to their defaults: std::string, not
// std::string<std::mem::default_allocator>
fn main() -> void {
    val s = std::string::from("hi");
    s.zap();
}
// error: std::string has no method 'zap'
