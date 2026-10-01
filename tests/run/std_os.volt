// flags: --leak-check
use std::io;
use std::string;
use std::text;
use std::fmt;
// std::path, std::fs (directories, file streams), std::process (env, cwd) and std::time

extern "C" fn getpid() -> i32;

fn show(what: str, r: std::fs::fs_error!void) -> void {
    r catch |e| {
        std::println("{}: {}", what, e);
        return;
    };
    std::println("{}: ok", what);
}

// a space before every item but the first
fn if_sep(i: usize) -> str {
    if (i == 0) {
        return "";
    }
    return " ";
}

fn list_status(p: str) -> void {
    val names = std::fs::list_dir(p) catch |e| {
        std::println("list missing: {}", e);
        return;
    };
    std::println("listed {}", names.len);
}

fn main() -> void {
    // paths: pure string work
    val (j1, j2, j3, j4) = (std::path::join("a", "b"), std::path::join("a/", "b"), std::path::join("a", "/b"), std::path::join("", "b"));
    std::println("{} {} {} {}", j1.as_str(), j2.as_str(), j3.as_str(), j4.as_str());
    std::println("[{}] [{}] [{}] [{}] [{}]", std::path::parent("a/b/c"), std::path::parent("/a"), std::path::parent("a"), std::path::parent("/"), std::path::parent("a/b/"));
    std::println("[{}] [{}] [{}]", std::path::file_name("a/b.txt"), std::path::file_name("a/b/"), std::path::file_name("/"));
    std::println("{} {} {} [{}] {} {}", std::path::extension("b.tar.gz"), std::path::extension(".bashrc"), std::path::extension("a/b"), std::path::extension("x."), std::path::stem("a/b.tar.gz"), std::path::stem(".bashrc"));
    val (n1, n2, n3, n4, n5, n6) = (std::path::normalize("a/./b/../c//d/"), std::path::normalize("/../x"), std::path::normalize("../a/.."), std::path::normalize(""), std::path::normalize("./"), std::path::normalize("/"));
    std::println("{} {} {} {} {} {} {} {}", n1.as_str(), n2.as_str(), n3.as_str(), n4.as_str(), n5.as_str(), n6.as_str(), std::path::is_absolute("/x"), std::path::is_absolute("x"));

    // a directory tree in /tmp
    var root = std::string::from("/tmp/volt-std-os-");
    root.append_int(getpid());
    val r = root.as_str();
    val sub = std::path::join(r, "sub");
    val deeper = std::path::join(sub.as_str(), "deeper");
    val a = std::path::join(r, "a.txt");
    show("create", std::fs::create_dir(r));
    show("create again", std::fs::create_dir(r));
    show("create_all", std::fs::create_dir_all(deeper.as_str()));
    std::fs::write_file(std::path::join(sub.as_str(), "b.txt").as_str(), "bee") catch @panic("write");
    std::fs::write_file(std::path::join(deeper.as_str(), "c.txt").as_str(), "sea") catch @panic("write");

    // a file stream: write, std::write into it, append, then read it back by lines
    {
        var f = std::fs::open(a.as_str(), "w") catch @panic("open w");
        f.write("alpha\n") catch @panic("write");
        std::write(&f, "beta {}\r\n", 2);
        f.flush() catch @panic("flush");
    }
    std::fs::append_file(a.as_str(), "gamma") catch @panic("append");
    std::println("{} {} {} {} {}", std::fs::is_dir(sub.as_str()), std::fs::is_file(a.as_str()), std::fs::is_dir(a.as_str()), std::fs::exists(std::path::join(r, "zzz").as_str()), std::fs::size(a.as_str()) catch 0);
    {
        var f = std::fs::open(a.as_str()) catch @panic("open r");
        for (line, i) in f.lines() {
            std::print("{}{}:{}", if_sep(i), i, line.as_str());
        }
        std::println("");
        val p = f.seek(6) catch 99;
        val second = (f.read_line() catch null) ?? std::string::from("?");
        f.seek(-5, std::fs::seek_from::END) catch @panic("seek");
        val rest = f.read_all() catch std::string::from("?");
        val at = f.position() catch 99;
        val eof = (f.read_line() catch null) ?? std::string::from("eof");
        std::println("{} [{}] [{}] {} {}", p, second.as_str(), rest.as_str(), at, eof.as_str());
    }

    // lines with a NUL byte, or longer than any buffer, come back whole
    {
        val odd = std::path::join(r, "odd.txt");
        var body = std::string::from("x\0y\n");
        for (k) in 0..5000 {
            body.push('z');
        }
        body.append("\nlast");
        std::fs::write_file(odd.as_str(), body.as_str()) catch @panic("write");
        var f = std::fs::open(odd.as_str()) catch @panic("open");
        for (line, i) in f.lines() {
            std::print("{}{}", if_sep(i), line.len());
        }
        std::println("");
        std::fs::remove_file(odd.as_str()) catch @panic("remove");
    }

    // listing and walking
    val names = std::fs::list_dir(r) catch @panic("list");
    std::println("{}", std::text::join(names.items(), ","));
    val files = std::fs::walk(r) catch @panic("walk");
    for (p, i) in files.items() {
        std::print("{}{}", if_sep(i), p.as_str()[r.len + 1..p.len()]);
    }
    std::println("");

    // rename, copy, and what can't be done
    val moved = std::path::join(sub.as_str(), "a2.txt");
    show("rename", std::fs::rename(a.as_str(), moved.as_str()));
    val copied = std::path::join(r, "copy.txt");
    show("copy", std::fs::copy_file(moved.as_str(), copied.as_str()));
    val text = std::fs::read_file(copied.as_str()) catch std::string::from("?");
    std::println("{} {} {}", std::fs::exists(a.as_str()), text.len(), text.as_str().ends_with("gamma"));
    show("remove_dir non-empty", std::fs::remove_dir(sub.as_str()));
    show("remove_file missing", std::fs::remove_file(std::path::join(r, "missing").as_str()));
    list_status(std::path::join(r, "missing").as_str());

    // the environment and the working directory
    std::process::set_env("VOLT_STD_OS_TEST", "on");
    val set = std::process::env("VOLT_STD_OS_TEST") ?? "-";
    std::process::unset_env("VOLT_STD_OS_TEST");
    std::println("{} {}", set, std::process::env("VOLT_STD_OS_TEST") ?? "unset");
    val before = std::process::cwd();
    show("cd", std::process::set_cwd(r));
    val inside = std::process::cwd();
    show("cd back", std::process::set_cwd(before.as_str()));
    show("cd missing", std::process::set_cwd("/nonexistent-volt-dir"));
    std::println("{} {}", inside.as_str() == r, std::process::cwd().as_str() == before.as_str());

    show("remove_all", std::fs::remove_all(r));
    std::println("{}", std::fs::exists(r));

    // time
    val start = std::time::now();
    std::time::sleep(std::time::millis(20));
    val took = start.elapsed();
    std::println("{} {} {}", took.as_millis() >= 20, took.as_millis() < 5000, std::time::unix_nanos() > 1700000000000000000);
    val (t1, t2, t3, t4, t5) = (std::time::utc_iso8601(0), std::time::utc_iso8601(951782400000000000), std::time::utc_iso8601(1000000000123000000), std::time::utc_iso8601(4107542400000000000), std::time::utc_iso8601(-1000000000));
    std::println("{} {} {} {} {}", t1.as_str(), t2.as_str(), t3.as_str(), t4.as_str(), t5.as_str());
    std::println("{} {} {:.3}", std::time::secs(2).as_millis(), std::time::micros(1500).as_nanos(), std::time::millis(1250).as_secs_f64());
}
// expect: a/b a/b /b b
// expect: [a/b] [/] [] [/] [a]
// expect: [b.txt] [b] []
// expect: gz null null [] b.tar .bashrc
// expect: a/c/d /x .. . . / true false
// expect: create: ok
// expect: create again: EXISTS
// expect: create_all: ok
// expect: true true false false 19
// expect: 0:alpha 1:beta 2 2:gamma
// expect: 6 [beta 2] [gamma] 19 eof
// expect: 3 5000 4
// expect: a.txt,sub
// expect: a.txt sub/b.txt sub/deeper/c.txt
// expect: rename: ok
// expect: copy: ok
// expect: false 19 true
// expect: remove_dir non-empty: NOT_EMPTY
// expect: remove_file missing: NOT_FOUND
// expect: list missing: NOT_FOUND
// expect: on unset
// expect: cd: ok
// expect: cd back: ok
// expect: cd missing: NOT_FOUND
// expect: true true
// expect: remove_all: ok
// expect: false
// expect: true true true
// expect: 1970-01-01T00:00:00Z 2000-02-29T00:00:00Z 2001-09-09T01:46:40.123Z 2100-03-01T00:00:00Z 1969-12-31T23:59:59Z
// expect: 2000 1500000 1.250
