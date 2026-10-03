// std::path: file paths as text ("/"-separated; on Windows "\" separates too, and "C:\" or "C:/"
// is a root). Pure string work: nothing here touches the disk.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace path {
    // whether c separates a path's parts
    internal fn is_sep(c: u8) -> bool {
        comptime if (@cfg("os", "windows")) {
            return c == '/' || c == '\\';
        } else {
            return c == '/';
        }
    }

    // what join and normalize put between parts
    internal fn sep() -> u8 {
        comptime if (@cfg("os", "windows")) {
            return '\\';
        } else {
            return '/';
        }
    }

    // how long p's root is: 1 for "/", 0 for a relative path; on Windows also 3 for "C:\" or "C:/",
    // and 2 for the "\\" a network path ("\\server\share") starts with
    internal fn root_len(p: str) -> usize {
        comptime if (@cfg("os", "windows")) {
            if (p.len >= 3 && p[1] == ':' && is_sep(p[2])) {
                return 3;
            }
            if (p.len >= 2 && is_sep(p[0]) && is_sep(p[1])) {
                return 2;
            }
        }
        if (p.len > 0 && is_sep(p[0])) {
            return 1;
        }
        return 0;
    }

    // where p's last separator is
    internal fn last_sep(p: str) -> usize? {
        var i = p.len;
        while (i > 0) {
            i -= 1;
            if (is_sep(p[i])) {
                return i;
            }
        }
        return null;
    }

    // whether p starts at the root
    fn is_absolute(p: str) -> bool {
        return root_len(p) > 0;
    }

    // b inside a ("a/b"); an absolute b replaces a
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn join(a: str, b: str, allocator: A = {}) -> std::string<A> {
        if (a.len == 0 || is_absolute(b)) {
            return std::string::from(b, move allocator);
        }
        var out = std::string::from(a, move allocator);
        if (!is_sep(a[a.len - 1])) {
            out.push(sep());
        }
        out.append(b);
        return move out;
    }

    // p without the separators it ends with (its root stays)
    internal fn trimmed(p: str) -> str {
        var keep = root_len(p);
        if (keep == 0) {
            keep = 1;
        }
        var end = p.len;
        while (end > keep && is_sep(p[end - 1])) {
            end -= 1;
        }
        return p[0..end];
    }

    // the directory p is in: "a/b" for "a/b/c", "/" for "/a", "" for "a"
    fn parent(p: str) -> str {
        val t = trimmed(p);
        val slash = last_sep(t) ?? return "";
        val root = root_len(t);
        if (slash < root) {
            return t[0..root];
        }
        return trimmed(t[0..slash]);
    }

    // the last part: "b.txt" for "a/b.txt", "b" for "a/b/", "" for "/"
    fn file_name(p: str) -> str {
        val t = trimmed(p);
        if (t.len == root_len(t)) {
            return ""; // the root, or nothing
        }
        val slash = last_sep(t) ?? return t;
        return t[slash + 1..t.len];
    }

    // the file name after its last dot: "gz" for "b.tar.gz"; null without one, or for a dotfile like ".bashrc"
    fn extension(p: str) -> str? {
        val name = file_name(p);
        val dot = name.rfind(".") ?? return null;
        if (dot == 0) {
            return null;
        }
        return name[dot + 1..name.len];
    }

    // the file name without its extension: "b.tar" for "a/b.tar.gz"
    fn stem(p: str) -> str {
        val name = file_name(p);
        val dot = name.rfind(".") ?? return name;
        if (dot == 0) {
            return name;
        }
        return name[0..dot];
    }

    // p with "." parts, repeated slashes and "x/.." pairs removed, by the text alone (it doesn't
    // follow symlinks): "a/c" for "a/./b/../c/". A relative path keeps its leading ".."s; "" is "."
    <A: std::mem::t_allocator = std::mem::default_allocator>
    fn normalize(p: str, allocator: A = {}) -> std::string<A> {
        val root = root_len(p);
        val abs = root > 0;
        var parts: std::vec<str, A> = { allocator: copy allocator };
        var start = root;
        var i = root;
        while (i <= p.len) {
            if (i < p.len && !is_sep(p[i])) {
                i += 1;
                continue;
            }
            val part = p[start..i];
            start = i + 1;
            i += 1;
            if (part.len == 0 || part == ".") {
                continue;
            }
            if (part == "..") {
                val last = parts.last();
                if (last != null && *last != "..") {
                    parts.pop();
                    continue;
                }
                if (abs) {
                    continue; // nothing is above the root
                }
            }
            parts.push(part) catch @panic("out of memory");
        }
        var out = std::string::new_in(move allocator);
        out.append(p[0..root]);
        for (part, k) in parts.items() {
            if (k > 0) {
                out.push(sep());
            }
            out.append(part);
        }
        if (out.len() == 0) {
            out.push('.');
        }
        return move out;
    }
}
