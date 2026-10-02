---
title: Files, paths and time
description: std::fs for files and directories, std::path for paths as text, and std::time for clocks, sleeping and dates.
sidebar:
  order: 4
---

## Whole files and streams

`std::fs::read_file` and `write_file` move a whole file in one call. For more control, `open` a
file: it reads and writes through a buffer, and closes itself when it goes out of scope. A file is a
writer, so `std::write` formats straight into it.

```volt
use std::io;
use std::fmt;

extern "C" fn getpid() -> i32;

fn main() -> !void {
    var name = std::string::from("/tmp/volt-files-doc-");
    name.append_int(getpid());
    val path = name.as_str();
    {
        var log = try std::fs::open(path, "w");
        try log.write("start\n");
        std::write(&log, "{} items\n", 3);
        try log.flush();
    }
    try std::fs::append_file(path, "done\n");
    var f = try std::fs::open(path);
    for (line, i) in f.lines() {
        std::println("{}: {}", i, line.as_str());
    }
    try f.seek(-5, std::fs::seek_from::END);
    std::println("{} {}", (try f.read_all()).as_str().trim(), try std::fs::size(path));
    try std::fs::remove_file(path);
}
// expect: 0: start
// expect: 1: 3 items
// expect: 2: done
// expect: done 19
```

`open`'s mode is C's: `"r"` (the default) reads, `"w"` creates or empties the file, `"a"` appends,
and `"r+"`, `"w+"`, `"a+"` both read and write. `read_line` gives the next line without its line
ending, or `null` at the end; `lines()` loops over them. `seek` counts from `std::fs::seek_from::START`
(the default), `CURRENT` or `END`.

## Directories

```volt
use std::io;
use std::text;

extern "C" fn getpid() -> i32;

fn main() -> !void {
    var name = std::string::from("/tmp/volt-dirs-doc-");
    name.append_int(getpid());
    val root = name.as_str();
    try std::fs::create_dir_all(std::path::join(root, "src/util").as_str());
    try std::fs::write_file(std::path::join(root, "src/main.volt").as_str(), "");
    try std::fs::write_file(std::path::join(root, "src/util/strings.volt").as_str(), "");
    val top = try std::fs::list_dir(root);
    val all = try std::fs::walk(root);
    std::println("{} | {}", std::text::join(top.items(), ","), all.len);
    std::fs::remove_dir(root) catch |e| {
        std::println("can't remove a full directory: {}", e);
    };
    try std::fs::remove_all(root);
    std::println("{}", std::fs::exists(root));
}
// expect: src | 2
// expect: can't remove a full directory: NOT_EMPTY
// expect: false
```

`list_dir` gives the names in a directory, sorted; `walk` every file below it as a path. Neither
follows links to directories, and `remove_all` removes a link rather than what it points at. Errors
are `std::fs::fs_error`: `NOT_FOUND`, `EXISTS`, `NOT_EMPTY`, `PERMISSION`, `NOT_A_DIR`, `IS_A_DIR`,
`IO`.

## Paths

`std::path` works on the text of a path and never touches the disk.

```volt
use std::io;

fn main() -> void {
    val p = "src/../lib/./parser.tar.gz";
    val clean = std::path::normalize(p);
    std::println("{} {} {} {}", clean.as_str(), std::path::parent(p), std::path::file_name(p), std::path::extension(p));
    std::println("{} {}", std::path::stem("notes.md"), std::path::join("/home", "volt").as_str());
}
// expect: lib/parser.tar.gz src/../lib/. parser.tar.gz gz
// expect: notes /home/volt
```

The working directory and the environment are in `std::process`: `cwd()`, `set_cwd(path)`,
`env(name)`, `set_env(name, value)` and `unset_env(name)`. `exe_path()` is the program's own file,
as an absolute path, for finding what's installed beside it.

## Time

`std::time::now()` reads the monotonic clock, which only goes forward, for measuring;
`unix_nanos()` reads the wall clock. Durations are made with `nanos`, `micros`, `millis` and `secs`.

```volt
use std::io;

fn main() -> void {
    val start = std::time::now();
    std::time::sleep(std::time::millis(5));
    val took = start.elapsed();
    val stamp = std::time::utc_iso8601(1000000000123000000);
    std::println("{} {}", took.as_millis() >= 5, stamp.as_str());
}
// expect: true 2001-09-09T01:46:40.123Z
```
