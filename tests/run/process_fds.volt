// std::process::run's child gets only stdin/out/err: the pipe it uses to report a failed exec is
// closed before exec (fd 3 is that pipe's read end: the lowest free fd when run makes it)
use std::io;
use std::process;

fn main() -> void {
    val args: str[3] = { "sh", "-c", "if [ -e /proc/$$/fd/3 ]; then echo leaked; else echo clean; fi" };
    val code = std::run(args[..]) catch 1;
    std::println("exit {}", code);
}
// expect: clean
// expect: exit 0
