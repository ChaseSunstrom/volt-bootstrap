// a C enum converts to and from integers only as Volt's own integers do: never narrowing silently
use { "../run/c_more_types.h" } as m;

fn narrow() -> u8 {
    val small: u8 = m::AXIS_Z;
    return small;
}

fn from_wide(wide: i64) -> m::axis {
    val e: m::axis = wide;
    return e;
}

fn too_big() -> m::axis {
    val far: m::axis = 3000000000;
    return far;
}

fn main() -> void {}
// error: expected u8, found m::axis
// error: expected m::axis, found i64
// error: 3000000000 doesn't fit in m::axis
