// voltc run of a program a signal ends says which signal, and exits 128 + its number as the shell does
extern "C" fn abort() -> never;

fn main() -> i32 {
    abort();
}
// exit: 134
// expect-stderr: voltc: the program was ended by SIGABRT (signal 6)
