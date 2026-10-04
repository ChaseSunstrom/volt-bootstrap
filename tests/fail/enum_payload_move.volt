// a payload that owns memory can't move out of the enum through its field: copy it
enum named {
    NAME: std::string,
    NONE,
}

fn main() -> void {
    val n = named::NAME(std::string::from("ada"));
    val s = n.NAME;
}
// error: out of a field, element or reference; copy it instead
