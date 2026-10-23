// @field_default of a field with no default, or no such field
struct opts {
    id: u32;
}

fn first() -> u32 {
    return @field_default(opts, "id");
}

fn second() -> u32 {
    return @field_default(opts, "size");
}

fn main() -> void {
    first();
    second();
}
// error: opts's field 'id' has no default
// error: opts has no field 'size'
