// std::path: file paths as text ("/"-separated). Pure string work: nothing here touches the disk.
// (Part of package std: the package loader wraps every file in `namespace std`.)

namespace path {
    // whether p starts at the root
    fn is_absolute(p: str) -> bool {
        return p.len > 0 && p[0] == '/';
    }

    // b inside a ("a/b"); an absolute b replaces a
    fn join(a: str, b: str) -> std::string {
        if (a.len == 0 || is_absolute(b)) {
            return std::string::from(b);
        }
        var out = std::string::from(a);
        if (a[a.len - 1] != '/') {
            out.push('/');
        }
        out.append(b);
        return move out;
    }

    // p without the slashes it ends with ("/" stays)
    internal fn trimmed(p: str) -> str {
        var end = p.len;
        while (end > 1 && p[end - 1] == '/') {
            end -= 1;
        }
        return p[0..end];
    }

    // the directory p is in: "a/b" for "a/b/c", "/" for "/a", "" for "a"
    fn parent(p: str) -> str {
        val t = trimmed(p);
        val slash = t.rfind("/") ?? return "";
        if (slash == 0) {
            return "/";
        }
        return trimmed(t[0..slash]);
    }

    // the last part: "b.txt" for "a/b.txt", "b" for "a/b/", "" for "/"
    fn file_name(p: str) -> str {
        val t = trimmed(p);
        if (t == "/") {
            return "";
        }
        val slash = t.rfind("/") ?? return t;
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
    fn normalize(p: str) -> std::string {
        val abs = is_absolute(p);
        var parts: std::vec<str> = {};
        val split = p.split("/");
        for (part) in split.items() {
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
        var out = std::string::from("");
        if (abs) {
            out.push('/');
        }
        out.append(std::text::join(parts.items(), "/").as_str());
        if (out.len() == 0) {
            out.push('.');
        }
        return move out;
    }
}
