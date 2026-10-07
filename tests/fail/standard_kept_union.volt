// pthread.h's mutex is a union: kept out of Volt's C (C89 isn't the program's standard), only C89's
// C could lay it out
@attributes([@standard("c89")])
use { "pthread.h" } as p;

fn main() -> void {}
// error: shares or hides its fields' bytes
