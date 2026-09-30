error app_error { MISSING_CONFIG }
fn load() -> app_error!i32 { return app_error::MISSING_CONFIG; }
fn main() -> !void {
    val x = try load();
}
// exit: 1
