// std::fs: reading and writing whole files.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace fs {
    // why a file operation failed
    error fs_error {
        NOT_FOUND,  // couldn't open the file
        IO,         // reading or writing failed
    }

    // libc through extern "C": voltc declares these under its own names, so they never clash
    // with a program's C headers
    internal extern "C" fn fopen(path: cstr, mode: cstr) -> void*;
    internal extern "C" fn fread(buf: void*, size: usize, n: usize, f: void*) -> usize;
    internal extern "C" fn fwrite(buf: void*, size: usize, n: usize, f: void*) -> usize;
    internal extern "C" fn fclose(f: void*) -> i32;
    internal extern "C" fn ferror(f: void*) -> i32;

    // the whole file
    fn read_file(path: str) -> fs_error!std::string {
        var p = std::string::from(path);
        val f = fopen(p.c_str(), "rb") ?? return fs_error::NOT_FOUND;
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

    // replace the file's contents with data
    fn write_file(path: str, data: str) -> fs_error!void {
        var p = std::string::from(path);
        val f = fopen(p.c_str(), "wb") ?? return fs_error::NOT_FOUND;
        var written: usize = 0;
        if (data.len > 0) {
            written = fwrite(@cast<void*>(data.ptr), 1, data.len, f);
        }
        val closed = fclose(f);
        if (written != data.len || closed != 0) {
            return fs_error::IO;
        }
    }
}
