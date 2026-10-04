// std::fs: files and directories: whole files, file streams, listing, walking, creating and removing.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace fs {
    // why a file operation failed
    error fs_error {
        NOT_FOUND,  // no such file or directory
        IO,         // reading or writing failed
        PERMISSION, // not allowed
        EXISTS,     // something is there already
        NOT_EMPTY,  // the directory still has entries
        NOT_A_DIR,  // a directory was needed
        IS_A_DIR,   // a file was needed
        BAD_PATH,   // too long for the system, or a NUL byte in it
    }

    // text with a NUL after it, in buf, for C: no allocation (a path the system takes is under 4096
    // bytes and has no NUL in it)
    internal fn c_text(text: str, buf: u8[..]) -> fs_error!cstr {
        if (text.len >= buf.len) {
            return fs_error::BAD_PATH;
        }
        for (b, i) in text {
            if (b == 0) {
                return fs_error::BAD_PATH;
            }
            buf[i] = b;
        }
        buf[text.len] = 0;
        return @cast<cstr>(buf.ptr);
    }

    // libc through extern "C": voltc declares these under its own names, so they never clash
    // with a program's C headers
    internal extern "C" fn fopen(path: cstr, mode: cstr) -> void*;
    internal extern "C" fn fread(buf: void*, size: usize, n: usize, f: void*) -> usize;
    internal extern "C" fn fwrite(buf: void*, size: usize, n: usize, f: void*) -> usize;
    internal extern "C" fn fclose(f: void*) -> i32;
    internal extern "C" fn ferror(f: void*) -> i32;
    internal extern "C" fn fflush(f: void*) -> i32;
    internal extern "C" fn fseek(f: void*, offset: i64, whence: i32) -> i32;
    internal extern "C" fn ftell(f: void*) -> i64;
    internal extern "C" fn getline(line: u8**, cap: usize*, f: void*) -> isize;
    internal extern "C" fn free(p: void*) -> void;
    internal extern "C" fn access(path: cstr, mode: i32) -> i32;
    internal extern "C" fn mkdir(path: cstr, mode: u32) -> i32;
    internal extern "C" fn rmdir(path: cstr) -> i32;
    internal extern "C" fn unlink(path: cstr) -> i32;
    namespace sys {
        // apart from fs::rename, which a string literal would fit as well
        internal extern "C" fn rename(from: cstr, to: cstr) -> i32;
    }
    internal extern "C" fn opendir(path: cstr) -> void*;
    internal extern "C" fn readdir(dir: void*) -> u8*;
    internal extern "C" fn closedir(dir: void*) -> i32;
    internal extern "C" fn strlen(s: cstr) -> usize;

    // Windows: the CRT's names for the POSIX calls above, and kernel32 for what the CRT doesn't have
    // (64-bit only, where the system's calls are plain C ones).
    // ponytail: paths cross as the "ANSI" code page, so a UTF-8 path with non-ASCII in it only works
    // on a system set to UTF-8; the W calls with UTF-16 paths if that matters
    namespace win {
        internal extern "C" fn _access(path: cstr, mode: i32) -> i32;
        internal extern "C" fn _mkdir(path: cstr) -> i32;
        internal extern "C" fn _rmdir(path: cstr) -> i32;
        internal extern "C" fn _unlink(path: cstr) -> i32;
        internal extern "C" fn _fseeki64(f: void*, offset: i64, whence: i32) -> i32; // C's long is 32 bits there
        internal extern "C" fn _ftelli64(f: void*) -> i64;
        internal extern "C" fn fgetc(f: void*) -> i32;
        internal extern "C" fn FindFirstFileA(pattern: cstr, data: void*) -> isize; // -1 when it fails
        internal extern "C" fn FindNextFileA(h: isize, data: void*) -> i32;
        internal extern "C" fn FindClose(h: isize) -> i32;
        internal extern "C" fn GetFileAttributesA(path: cstr) -> u32;
        internal extern "C" fn MoveFileExA(from: cstr, to: cstr, flags: u32) -> i32;
        internal extern "C" fn GetLastError() -> u32;
    }

    // GetFileAttributesA's answers
    internal fn no_attributes() -> u32 {
        return 0xffffffff;
    }
    internal fn dir_attribute() -> u32 {
        return 0x10;
    }
    internal fn link_attribute() -> u32 {
        return 0x400; // a reparse point: a symbolic link or a junction
    }

    // the fs_error for a Windows call's GetLastError
    internal fn from_win(e: u32) -> fs_error {
        if (e == 2 || e == 3) {
            return fs_error::NOT_FOUND; // no such file, no such path
        }
        if (e == 5 || e == 32) {
            return fs_error::PERMISSION; // access denied, in use by another process
        }
        if (e == 80 || e == 183) {
            return fs_error::EXISTS;
        }
        if (e == 145) {
            return fs_error::NOT_EMPTY;
        }
        if (e == 267) {
            return fs_error::NOT_A_DIR;
        }
        if (e == 123 || e == 161 || e == 206) {
            return fs_error::BAD_PATH; // a bad name, a bad path, too long
        }
        return fs_error::IO;
    }

    // the fs_error for the last failed C library call's errno
    internal fn from_errno() -> fs_error {
        val e = platform::errno();
        if (e == 2) {
            return fs_error::NOT_FOUND;
        }
        if (e == 1 || e == 13) {
            return fs_error::PERMISSION;
        }
        if (e == 17) {
            return fs_error::EXISTS;
        }
        if (e == platform::by_os(39, 66, 66, 41)) {
            return fs_error::NOT_EMPTY;
        }
        if (e == 20) {
            return fs_error::NOT_A_DIR;
        }
        if (e == 21) {
            return fs_error::IS_A_DIR;
        }
        return fs_error::IO;
    }

    // fseek and ftell with 64-bit offsets everywhere
    internal fn c_seek(f: void*, offset: i64, whence: i32) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::_fseeki64(f, offset, whence);
        } else {
            return fseek(f, offset, whence);
        }
    }

    internal fn c_tell(f: void*) -> i64 {
        comptime if (@cfg("os", "windows")) {
            return win::_ftelli64(f);
        } else {
            return ftell(f);
        }
    }

    // the whole file
    <A: std::mem::allocator = std::mem::default_allocator>
    fn read_file(path: str, allocator: A = {}) -> fs_error!std::string<A> {
        var pb: u8[4096];
        val f = fopen(try c_text(path, pb[..]), "rb") ?? return from_errno();
        var out = std::string::new_in(move allocator);
        var buf: u8[4096];
        loop {
            val n = fread(&buf, 1, 4096, f);
            out.append(@cast<str>(@slice(&buf[0], n)));
            if (n < 4096) {
                break;
            }
        }
        val failed = ferror(f) != 0;
        fclose(f);
        if (failed) {
            return fs_error::IO;
        }
        return out;
    }

    // data written to path through fopen mode m ("wb" replaces, "ab" appends)
    internal fn put_file(path: str, data: str, m: cstr) -> fs_error!void {
        var pb: u8[4096];
        val f = fopen(try c_text(path, pb[..]), m) ?? return from_errno();
        var written: usize = 0;
        if (data.len > 0) {
            written = fwrite(@cast<void*>(data.ptr), 1, data.len, f);
        }
        val closed = fclose(f);
        if (written != data.len || closed != 0) {
            return fs_error::IO;
        }
    }

    // replace the file's contents with data (creating it)
    fn write_file(path: str, data: str) -> fs_error!void {
        return put_file(path, data, "wb");
    }

    // add data to the end of the file (creating it)
    fn append_file(path: str, data: str) -> fs_error!void {
        return put_file(path, data, "ab");
    }

    // whether something is at path
    fn exists(path: str) -> bool {
        var pb: u8[4096];
        val p = c_text(path, pb[..]) catch return false;
        comptime if (@cfg("os", "windows")) {
            return win::_access(p, 0) == 0;
        } else {
            return access(p, 0) == 0;
        }
    }

    // whether path is a directory (or a link to one)
    fn is_dir(path: str) -> bool {
        var pb: u8[4096];
        val p = c_text(path, pb[..]) catch return false;
        comptime if (@cfg("os", "windows")) {
            val a = win::GetFileAttributesA(p);
            return a != no_attributes() && (a & dir_attribute()) != 0;
        } else {
            val d = opendir(p) ?? return false;
            closedir(d);
            return true;
        }
    }

    // whether path is there and isn't a directory
    fn is_file(path: str) -> bool {
        return exists(path) && !is_dir(path);
    }

    // the size of the file at path, in bytes
    fn size(path: str) -> fs_error!u64 {
        var pb: u8[4096];
        val f = fopen(try c_text(path, pb[..]), "rb") ?? return from_errno();
        val ok = c_seek(f, 0, 2) == 0;
        val n = c_tell(f);
        fclose(f);
        if (!ok || n < 0) {
            return fs_error::IO;
        }
        return @cast<u64>(n);
    }

    // the entries of directory path (not "." or ".."), in the order the system gives them: names, and
    // whether each is a directory (a link to one isn't: walking and removing don't follow links)
    <A: std::mem::allocator>
    internal fn scan(path: str, names: std::vec<std::string<A>, A>&, dirs: std::vec<bool, A>&) -> fs_error!void {
        comptime if (@cfg("os", "windows")) {
            return scan_windows(path, names, dirs);
        } else {
            return scan_posix(path, names, dirs);
        }
    }

    // scan, through opendir and readdir
    <A: std::mem::allocator>
    internal fn scan_posix(path: str, names: std::vec<std::string<A>, A>&, dirs: std::vec<bool, A>&) -> fs_error!void {
        var pb: u8[4096];
        val d = opendir(try c_text(path, pb[..])) ?? return from_errno();
        // where struct dirent keeps d_type and d_name: glibc and musl on 64-bit Linux; macOS's (on
        // x86-64, plain readdir is the old one, with 32-bit inode numbers); FreeBSD 12's
        var type_at: usize = 18;
        var name_at: usize = 19;
        comptime if (@cfg("os", "macos") && @cfg("arch", "x86_64")) {
            type_at = 6;
            name_at = 8;
        } else if (@cfg("os", "macos")) {
            type_at = 20;
            name_at = 21;
        } else if (@cfg("os", "freebsd")) {
            name_at = 24;
        }
        loop {
            val ent = readdir(d) ?? break;
            val bytes = @slice(ent, name_at + 1);
            val cname = @cast<cstr>(&bytes[name_at]);
            val name = @cast<str>(@slice(@cast<u8*>(cname), strlen(cname)));
            if (name == "." || name == "..") {
                continue;
            }
            val kind = bytes[type_at];
            var dir = kind == 4; // DT_DIR
            if (kind == 0) {
                // DT_UNKNOWN (a filesystem without types): ask
                // ponytail: this one follows links, so a link loop on such a filesystem walks forever
                dir = is_dir(std::path::join(path, name, copy names.allocator).as_str());
            }
            names.push(std::string::from(name, copy names.allocator)) catch @panic("out of memory");
            dirs.push(dir) catch @panic("out of memory");
        }
        closedir(d);
    }

    // scan, through FindFirstFileA and FindNextFileA
    <A: std::mem::allocator>
    internal fn scan_windows(path: str, names: std::vec<std::string<A>, A>&, dirs: std::vec<bool, A>&) -> fs_error!void {
        var pb: u8[4096];
        var qb: u8[4096];
        val p = try c_text(path, pb[..]);
        val pattern = std::path::join(path, "*", copy names.allocator);
        // WIN32_FIND_DATAA: the attributes at byte 0, the name (NUL-ended) at 44
        var data: u32[80];
        val h = win::FindFirstFileA(try c_text(pattern.as_str(), qb[..]), @cast<void*>(&data[0]));
        if (h == -1) {
            val e = win::GetLastError();
            val a = win::GetFileAttributesA(p);
            if (a != no_attributes() && (a & dir_attribute()) == 0) {
                return fs_error::NOT_A_DIR;
            }
            if (e == 2 && a != no_attributes()) {
                return; // nothing in it (a drive's root has no "." or "..")
            }
            return from_win(e);
        }
        loop {
            val cname = @cast<cstr>(&@slice(@cast<u8*>(&data[0]), 320)[44]);
            val name = @cast<str>(@slice(@cast<u8*>(cname), strlen(cname)));
            if (name != "." && name != "..") {
                // a link to a directory isn't one here: walking and removing don't follow links
                val a = data[0];
                names.push(std::string::from(name, copy names.allocator)) catch @panic("out of memory");
                dirs.push((a & dir_attribute()) != 0 && (a & link_attribute()) == 0) catch @panic("out of memory");
            }
            if (win::FindNextFileA(h, @cast<void*>(&data[0])) == 0) {
                break;
            }
        }
        win::FindClose(h);
    }

    // the names in directory path (not "." or ".."), sorted
    <A: std::mem::allocator = std::mem::default_allocator>
    fn list_dir(path: str, allocator: A = {}) -> fs_error!std::vec<std::string<A>, A> {
        var names: std::vec<std::string<A>, A> = { allocator: copy allocator };
        var dirs: std::vec<bool, A> = { allocator: copy allocator };
        try scan(path, &names, &dirs);
        names.items().sort(move allocator);
        return names;
    }

    // every file under directory path, in its subdirectories too (not the directories themselves), as
    // paths starting with path, sorted; links to directories aren't followed
    <A: std::mem::allocator = std::mem::default_allocator>
    fn walk(path: str, allocator: A = {}) -> fs_error!std::vec<std::string<A>, A> {
        var out: std::vec<std::string<A>, A> = { allocator: copy allocator };
        try walk_into(path, &out);
        out.items().sort(move allocator);
        return out;
    }

    <A: std::mem::allocator>
    internal fn walk_into(dir: str, out: std::vec<std::string<A>, A>&) -> fs_error!void {
        var names: std::vec<std::string<A>, A> = { allocator: copy out.allocator };
        var dirs: std::vec<bool, A> = { allocator: copy out.allocator };
        try scan(dir, &names, &dirs);
        for (n&, i) in names.items() {
            var full = std::path::join(dir, n.as_str(), copy out.allocator);
            if (*dirs.at(i)) {
                try walk_into(full.as_str(), out);
            } else {
                out.push(move full) catch @panic("out of memory");
            }
        }
    }

    // make directory path (its parent has to exist)
    fn create_dir(path: str) -> fs_error!void {
        var pb: u8[4096];
        val p = try c_text(path, pb[..]);
        comptime if (@cfg("os", "windows")) {
            if (win::_mkdir(p) != 0) {
                return from_errno();
            }
        } else {
            if (mkdir(p, 0o777) != 0) {
                return from_errno();
            }
        }
    }

    // make directory path and any of its parents that are missing; fine if it's there already
    fn create_dir_all(path: str) -> fs_error!void {
        if (path.len == 0 || is_dir(path)) {
            return;
        }
        val up = std::path::parent(path);
        if (up.len > 0 && up != path) {
            try create_dir_all(up);
        }
        create_dir(path) catch |e| {
            if (e == fs_error::EXISTS && is_dir(path)) {
                return; // made meanwhile
            }
            return e;
        };
    }

    // C's unlink and rmdir: 0, or -1 with errno set
    internal fn c_unlink(path: cstr) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::_unlink(path);
        } else {
            return unlink(path);
        }
    }

    internal fn c_rmdir(path: cstr) -> i32 {
        comptime if (@cfg("os", "windows")) {
            return win::_rmdir(path);
        } else {
            return rmdir(path);
        }
    }

    // remove the file (or link) at path
    fn remove_file(path: str) -> fs_error!void {
        var pb: u8[4096];
        if (c_unlink(try c_text(path, pb[..])) != 0) {
            return from_errno();
        }
    }

    // remove directory path, which has to be empty
    fn remove_dir(path: str) -> fs_error!void {
        var pb: u8[4096];
        if (c_rmdir(try c_text(path, pb[..])) != 0) {
            return from_errno();
        }
    }

    // remove path: a file, or a directory with everything in it. A link is removed, not followed
    fn remove_all(path: str) -> fs_error!void {
        var pb: u8[4096];
        val p = try c_text(path, pb[..]);
        comptime if (@cfg("os", "windows")) {
            // a link to a directory is removed as a directory is; listing it would list its target
            val a = win::GetFileAttributesA(p);
            if (a != no_attributes() && (a & dir_attribute()) != 0 && (a & link_attribute()) != 0) {
                if (win::_rmdir(p) != 0) {
                    return from_errno();
                }
                return;
            }
        }
        if (c_unlink(p) == 0) {
            return;
        }
        val e = from_errno();
        if (e != fs_error::IS_A_DIR && e != fs_error::PERMISSION) {
            return e;
        }
        var names: std::vec<std::string> = {};
        var dirs: std::vec<bool> = {};
        scan(path, &names, &dirs) catch |x| {
            return e; // not a directory after all: unlink's error stands
        };
        for (n&) in names.items() {
            try remove_all(std::path::join(path, n.as_str()).as_str());
        }
        try remove_dir(path);
    }

    // move (or rename) from to to, replacing a file at to
    fn rename(from: str, to: str) -> fs_error!void {
        var fb: u8[4096];
        var tb: u8[4096];
        val f = try c_text(from, fb[..]);
        val t = try c_text(to, tb[..]);
        comptime if (@cfg("os", "windows")) {
            // the CRT's rename won't replace a file: MOVEFILE_REPLACE_EXISTING, MOVEFILE_COPY_ALLOWED
            // (to another drive)
            if (win::MoveFileExA(f, t, 3) == 0) {
                return from_win(win::GetLastError());
            }
        } else {
            if (sys::rename(f, t) != 0) {
                return from_errno();
            }
        }
    }

    // copy the file at from to to (replacing it)
    fn copy_file(from: str, to: str) -> fs_error!void {
        var src = try open(from, "r");
        var dst = try open(to, "w");
        var buf: u8[65536];
        loop {
            val n = try src.read(buf[..]);
            if (n == 0) {
                break;
            }
            try dst.write(@cast<str>(buf[0..n]));
        }
        try dst.flush();
    }

    // where seek counts from
    enum seek_from {
        START,   // the start of the file
        CURRENT, // the current position
        END,     // the end of the file
    }

    // An open file, read and written through a buffer (C's FILE). Closed when it's deleted.
    struct file {
        handle: void*;
        failed: bool = false; // a write through write_str (std::write) failed; flush reports it
    }

    // open the file at path. mode: "r" reads; "w" writes, creating or emptying it; "a" appends,
    // creating it; "r+" reads and writes; "w+" empties it, then both; "a+" reads and appends
    fn open(path: str, mode: str = "r") -> fs_error!file {
        var pb: u8[4096];
        val f = fopen(try c_text(path, pb[..]), c_mode(mode)) ?? return from_errno();
        return { handle: f };
    }

    // open's mode for fopen, binary: "b" keeps Windows from turning "\n" into "\r\n" (elsewhere it
    // changes nothing)
    internal fn c_mode(mode: str) -> cstr {
        if (mode == "r") {
            return "rb";
        }
        if (mode == "w") {
            return "wb";
        }
        if (mode == "a") {
            return "ab";
        }
        if (mode == "r+") {
            return "r+b";
        }
        if (mode == "w+") {
            return "w+b";
        }
        if (mode == "a+") {
            return "a+b";
        }
        @panic("std::fs::open: mode is r, w, a, r+, w+ or a+");
    }

    // walks a file's lines (see lines)
    <A: std::mem::allocator>
    struct file_lines {
        f: file*;
        allocator: A; // where each line goes
    }
}

// read up to buf.len bytes into buf: how many (0 at the end of the file)
attach fn read(this: std::fs::file&, buf: u8[..]) -> std::fs::fs_error!usize {
    val n = std::fs::fread(@cast<void*>(buf.ptr), 1, buf.len, this.handle);
    if (n < buf.len && std::fs::ferror(this.handle) != 0) {
        return std::fs::fs_error::IO;
    }
    return n;
}

// the rest of the file
<A: std::mem::allocator = std::mem::default_allocator>
attach fn read_all(this: std::fs::file&, allocator: A = {}) -> std::fs::fs_error!std::string<A> {
    var out = std::string::new_in(move allocator);
    var buf: u8[4096];
    loop {
        val n = try this.read(buf[..]);
        if (n == 0) {
            return out;
        }
        out.append(@cast<str>(buf[0..n]));
    }
}

// the next line, without its "\n" (or "\r\n"); null at the end of the file. Any length, NUL bytes too
<A: std::mem::allocator = std::mem::default_allocator>
attach fn read_line(this: std::fs::file&, allocator: A = {}) -> std::fs::fs_error!(std::string<A>?) {
    var out = std::string::new_in(move allocator);
    comptime if (@cfg("os", "windows")) {
        // no getline: a byte at a time
        var any = false;
        loop {
            val c = std::fs::win::fgetc(this.handle);
            if (c < 0) {
                break; // EOF, or an error
            }
            any = true;
            out.push(@cast<u8>(c));
            if (c == 10) {
                break;
            }
        }
        if (!any) {
            if (std::fs::ferror(this.handle) != 0) {
                return std::fs::fs_error::IO;
            }
            return null;
        }
    } else {
        // getline counts the bytes (fgets can't: it would stop the line at a NUL) and grows its
        // buffer, which C's malloc owns, so C's free gives it back
        var buf: u8* = @cast<u8*>(0);
        var cap: usize = 0;
        val n = std::fs::getline(&buf, &cap, this.handle);
        if (n < 0) {
            std::fs::free(buf as void*);
            if (std::fs::ferror(this.handle) != 0) {
                return std::fs::fs_error::IO;
            }
            return null;
        }
        out.append(@cast<str>(@slice(buf, @cast<usize>(n))));
        std::fs::free(buf as void*);
    }
    if (out.as_str().ends_with("\n")) {
        out.pop();
    }
    if (out.as_str().ends_with("\r")) {
        out.pop();
    }
    return out;
}

// for (line) in f.lines(): each line as read_line gives it, until the end (or a read error)
<A: std::mem::allocator = std::mem::default_allocator>
attach fn lines(this: std::fs::file&, allocator: A = {}) -> std::fs::file_lines<A> {
    return { f: this as std::fs::file*, allocator: move allocator };
}

// the next line
<A: std::mem::allocator>
attach fn next(this: std::fs::file_lines<A>&) -> std::string<A>? {
    return this.f->read_line(copy this.allocator) catch null;
}

// write data at the current position
attach fn write(this: std::fs::file&, data: str) -> std::fs::fs_error!void {
    if (data.len > 0 && std::fs::fwrite(@cast<void*>(data.ptr), 1, data.len, this.handle) != data.len) {
        return std::fs::fs_error::IO;
    }
}

// write s: this makes a file a writer, for std::write. A failure shows at the next flush
attach fn write_str(this: std::fs::file&, s: str) -> void {
    this.write(s) catch |e| {
        this.failed = true;
    };
}

// move to offset bytes from the start (or the current position, or the end): the new position
attach fn seek(this: std::fs::file&, offset: i64, from: std::fs::seek_from = std::fs::seek_from::START) -> std::fs::fs_error!u64 {
    var whence = 0;
    if (from == std::fs::seek_from::CURRENT) {
        whence = 1;
    } else if (from == std::fs::seek_from::END) {
        whence = 2;
    }
    if (std::fs::c_seek(this.handle, offset, whence) != 0) {
        return std::fs::from_errno();
    }
    return this.position();
}

// the current position, in bytes from the start
attach fn position(this: std::fs::file&) -> std::fs::fs_error!u64 {
    val n = std::fs::c_tell(this.handle);
    if (n < 0) {
        return std::fs::from_errno();
    }
    return @cast<u64>(n);
}

// write out what's buffered; IO if that (or an earlier std::write into the file) failed
attach fn flush(this: std::fs::file&) -> std::fs::fs_error!void {
    if (std::fs::fflush(this.handle) != 0 || this.failed) {
        return std::fs::fs_error::IO;
    }
}

// closes the file (writing out what's buffered)
attach fn delete(this: std::fs::file&) -> void {
    std::fs::fclose(this.handle);
}
