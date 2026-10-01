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
    internal extern "C" fn __errno_location() -> i32&;

    // the fs_error for the last failed call's errno
    // ponytail: Linux's errno numbers; other systems need their own
    internal fn from_errno() -> fs_error {
        val e = *__errno_location();
        if (e == 2) {
            return fs_error::NOT_FOUND;
        }
        if (e == 1 || e == 13) {
            return fs_error::PERMISSION;
        }
        if (e == 17) {
            return fs_error::EXISTS;
        }
        if (e == 39) {
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

    // the whole file
    fn read_file(path: str) -> fs_error!std::string {
        var p = std::string::from(path);
        val f = fopen(p.c_str(), "rb") ?? return from_errno();
        var out: std::string = {};
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
        return move out;
    }

    // data written to path through fopen mode m ("wb" replaces, "ab" appends)
    internal fn put_file(path: str, data: str, m: cstr) -> fs_error!void {
        var p = std::string::from(path);
        val f = fopen(p.c_str(), m) ?? return from_errno();
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
        var p = std::string::from(path);
        return access(p.c_str(), 0) == 0;
    }

    // whether path is a directory (or a link to one)
    fn is_dir(path: str) -> bool {
        var p = std::string::from(path);
        val d = opendir(p.c_str()) ?? return false;
        closedir(d);
        return true;
    }

    // whether path is there and isn't a directory
    fn is_file(path: str) -> bool {
        return exists(path) && !is_dir(path);
    }

    // the size of the file at path, in bytes
    fn size(path: str) -> fs_error!u64 {
        var p = std::string::from(path);
        val f = fopen(p.c_str(), "rb") ?? return from_errno();
        val ok = fseek(f, 0, 2) == 0;
        val n = ftell(f);
        fclose(f);
        if (!ok || n < 0) {
            return fs_error::IO;
        }
        return @cast<u64>(n);
    }

    // the entries of directory path (not "." or ".."), in the order the system gives them: names, and
    // whether each is a directory (a link to one isn't: walking and removing don't follow links)
    internal fn scan(path: str, names: std::vec<std::string>&, dirs: std::vec<bool>&) -> fs_error!void {
        var p = std::string::from(path);
        val d = opendir(p.c_str()) ?? return from_errno();
        loop {
            val ent = readdir(d) ?? break;
            // ponytail: struct dirent's d_type at byte 18 and d_name at 19, as glibc and musl lay it out
            // on 64-bit Linux; other systems need their own offsets
            val bytes = @slice(ent, 20);
            val cname = @cast<cstr>(&bytes[19]);
            val name = @cast<str>(@slice(@cast<u8*>(cname), strlen(cname)));
            if (name == "." || name == "..") {
                continue;
            }
            var dir = bytes[18] == 4; // DT_DIR
            if (bytes[18] == 0) {
                // DT_UNKNOWN (a filesystem without types): ask
                // ponytail: this one follows links, so a link loop on such a filesystem walks forever
                dir = is_dir(std::path::join(path, name).as_str());
            }
            names.push(std::string::from(name)) catch @panic("out of memory");
            dirs.push(dir) catch @panic("out of memory");
        }
        closedir(d);
    }

    // the names in directory path (not "." or ".."), sorted
    fn list_dir(path: str) -> fs_error!std::vec<std::string> {
        var names: std::vec<std::string> = {};
        var dirs: std::vec<bool> = {};
        try scan(path, &names, &dirs);
        names.items().sort();
        return move names;
    }

    // every file under directory path, in its subdirectories too (not the directories themselves), as
    // paths starting with path, sorted; links to directories aren't followed
    fn walk(path: str) -> fs_error!std::vec<std::string> {
        var out: std::vec<std::string> = {};
        try walk_into(path, &out);
        out.items().sort();
        return move out;
    }

    internal fn walk_into(dir: str, out: std::vec<std::string>&) -> fs_error!void {
        var names: std::vec<std::string> = {};
        var dirs: std::vec<bool> = {};
        try scan(dir, &names, &dirs);
        for (n&, i) in names.items() {
            var full = std::path::join(dir, n.as_str());
            if (*dirs.at(i)) {
                try walk_into(full.as_str(), out);
            } else {
                out.push(move full) catch @panic("out of memory");
            }
        }
    }

    // make directory path (its parent has to exist)
    fn create_dir(path: str) -> fs_error!void {
        var p = std::string::from(path);
        if (mkdir(p.c_str(), 0o777) != 0) {
            return from_errno();
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

    // remove the file (or link) at path
    fn remove_file(path: str) -> fs_error!void {
        var p = std::string::from(path);
        if (unlink(p.c_str()) != 0) {
            return from_errno();
        }
    }

    // remove directory path, which has to be empty
    fn remove_dir(path: str) -> fs_error!void {
        var p = std::string::from(path);
        if (rmdir(p.c_str()) != 0) {
            return from_errno();
        }
    }

    // remove path: a file, or a directory with everything in it. A link is removed, not followed
    fn remove_all(path: str) -> fs_error!void {
        var p = std::string::from(path);
        if (unlink(p.c_str()) == 0) {
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
        var f = std::string::from(from);
        var t = std::string::from(to);
        if (sys::rename(f.c_str(), t.c_str()) != 0) {
            return from_errno();
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
        if (mode != "r" && mode != "w" && mode != "a" && mode != "r+" && mode != "w+" && mode != "a+") {
            @panic("std::fs::open: mode is r, w, a, r+, w+ or a+");
        }
        var p = std::string::from(path);
        var m = std::string::from(mode);
        val f = fopen(p.c_str(), m.c_str()) ?? return from_errno();
        return { handle: f };
    }

    // walks a file's lines (see lines)
    struct file_lines {
        f: file*;
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
attach fn read_all(this: std::fs::file&) -> std::fs::fs_error!std::string {
    var out: std::string = {};
    var buf: u8[4096];
    loop {
        val n = try this.read(buf[..]);
        if (n == 0) {
            return move out;
        }
        out.append(@cast<str>(buf[0..n]));
    }
}

// the next line, without its "\n" (or "\r\n"); null at the end of the file. Any length, NUL bytes too
attach fn read_line(this: std::fs::file&) -> std::fs::fs_error!(std::string?) {
    // getline counts the bytes (fgets can't: it would stop the line at a NUL) and grows its buffer,
    // which C's malloc owns, so C's free gives it back
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
    var out = std::string::from(@cast<str>(@slice(buf, @cast<usize>(n))));
    std::fs::free(buf as void*);
    if (out.as_str().ends_with("\n")) {
        out.pop();
    }
    if (out.as_str().ends_with("\r")) {
        out.pop();
    }
    return move out;
}

// for (line) in f.lines(): each line as read_line gives it, until the end (or a read error)
attach fn lines(this: std::fs::file&) -> std::fs::file_lines {
    return { f: this as std::fs::file* };
}

// the next line
attach fn next(this: std::fs::file_lines&) -> std::string? {
    return this.f->read_line() catch null;
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
    if (std::fs::fseek(this.handle, offset, whence) != 0) {
        return std::fs::from_errno();
    }
    return this.position();
}

// the current position, in bytes from the start
attach fn position(this: std::fs::file&) -> std::fs::fs_error!u64 {
    val n = std::fs::ftell(this.handle);
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
