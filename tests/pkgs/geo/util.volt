fn scale(x: i32) -> i32 {
    return x * FACTOR;
}

val FACTOR: i32 = 2;

error geo_error { NEGATIVE }

// allocates in the package, freed by the program: one runtime allocator across C units
fn boxed_area(r: rect) -> geo_error!std::mem::box<i32> {
    if (r.w < 0) {
        return geo_error::NEGATIVE;
    }
    return i32::new(area(r)) catch return geo_error::NEGATIVE;
}

// package state: one variable, even when the package comes from a prebuilt library
var calls: i32 = 0;

fn count() -> i32 {
    calls += 1;
    return calls;
}

// state only a template uses: a prebuilt library still defines it, for the programs that
// instantiate the template
var tallies: i64 = 0;

<T: type>
fn tally(x: T) -> i64 {
    tallies += @cast<i64>(x);
    return tallies;
}
