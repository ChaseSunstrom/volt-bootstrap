// The language server (`voltc lsp`, the self-hosted voltc) in a scripted session over stdio:
// initialize, diagnostics as the text changes, hover, go to definition, references, document
// symbols, completion (after `.`, after `::`, and plain) and signature help, then shutdown.
mod common;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// the program the session edits (0-based lines are what LSP counts)
const PROGRAM: &str = "use std::io;

struct point {
    x: i32;
    y: i32;
}

attach fn sum(this: point&) -> i32 {
    return this.x + this.y;
}

fn add(a: i32, b: i32) -> i32 {
    return a + b;
}

fn main() -> void {
    val p: point = { x: 1, y: 2 };
    val total = add(p.x, p.sum());
    std::println(\"{}\", total + missing);
}
";

struct Server {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    next_id: u64,
    dir: PathBuf,
}

impl Server {
    fn start() -> Server {
        let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("lsp-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let voltc = dir.join("voltc");
        let mut srcs: Vec<PathBuf> = std::fs::read_dir(Path::new(ROOT).join("voltc/src")).unwrap().map(|e| e.unwrap().path()).filter(|p| p.extension().is_some_and(|x| x == "volt")).collect();
        srcs.sort();
        let b = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).args(common::llvm_cc_args()).arg("-o").arg(&voltc).output().unwrap();
        assert!(b.status.success(), "building voltc/src failed:\n{}", String::from_utf8_lossy(&b.stderr));
        // bolt on PATH: the server asks it for a package's dependencies
        let bolt_dir = Path::new(env!("CARGO_BIN_EXE_bolt")).parent().unwrap().to_path_buf();
        let path = std::env::join_paths(std::iter::once(bolt_dir).chain(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()))).unwrap();
        // started the way VS Code's client starts it: with --stdio
        let mut child = Command::new(&voltc)
            .args(["lsp", "--stdio"])
            .env("VOLT_STD", Path::new(ROOT).join("std"))
            .env("PATH", path)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        Server { child, input, output, next_id: 1, dir }
    }

    fn send(&mut self, msg: &str) {
        write!(self.input, "Content-Length: {}\r\n\r\n{msg}", msg.len()).unwrap();
        self.input.flush().unwrap();
    }

    /// the next message the server sends
    fn recv(&mut self) -> String {
        let mut len = 0;
        loop {
            let mut line = String::new();
            assert!(self.output.read_line(&mut line).unwrap() > 0, "the server closed its output");
            let line = line.trim_end();
            if line.is_empty() {
                break;
            }
            if let Some(n) = line.strip_prefix("Content-Length: ") {
                len = n.parse().unwrap();
            }
        }
        let mut body = vec![0; len];
        self.output.read_exact(&mut body).unwrap();
        String::from_utf8(body).unwrap()
    }

    /// a request's response (notifications in between are skipped)
    fn request(&mut self, method: &str, params: &str) -> String {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"{method}\",\"params\":{params}}}"));
        loop {
            let m = self.recv();
            // a response has a result or an error; a request or notification has a method (which a
            // result can also spell: the semantic token legend has "method")
            if m.contains(&format!("\"id\":{id}")) && (m.contains("\"result\"") || m.contains("\"error\"")) {
                return m;
            }
        }
    }

    fn notify(&mut self, method: &str, params: &str) {
        self.send(&format!("{{\"jsonrpc\":\"2.0\",\"method\":\"{method}\",\"params\":{params}}}"));
    }

    /// the next publishDiagnostics notification
    fn diagnostics(&mut self) -> String {
        loop {
            let m = self.recv();
            if m.contains("textDocument/publishDiagnostics") {
                return m;
            }
        }
    }

    /// the next publishDiagnostics for the document at uri (skipping others still on their way)
    fn diagnostics_for(&mut self, uri: &str) -> String {
        loop {
            let m = self.diagnostics();
            if m.contains(&format!("\"uri\":\"{uri}\"")) {
                return m;
            }
        }
    }
}

/// a JSON string literal
fn js(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

#[test]
fn scripted_session() {
    let mut s = Server::start();
    let uri = format!("file://{}/main.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");

    let init = s.request("initialize", &format!("{{\"processId\":null,\"rootUri\":\"file://{}\",\"capabilities\":{{}}}}", s.dir.display()));
    for cap in ["\"hoverProvider\":true", "\"definitionProvider\":true", "\"referencesProvider\":true", "\"documentSymbolProvider\":true", "\"completionProvider\"", "\"signatureHelpProvider\"", "\"textDocumentSync\""] {
        assert!(init.contains(cap), "initialize lacks {cap}: {init}");
    }
    s.notify("initialized", "{}");

    // a URI ending in a cut-off %-escape is read as it is
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"file://{}/odd%1\",\"languageId\":\"volt\",\"version\":1,\"text\":\"fn main() -> void {{}}\\n\"}}}}", s.dir.display()));
    let d = s.diagnostics();
    assert!(d.contains("odd%1") && d.contains("\"diagnostics\":[]"), "{d}");

    // test blocks are checked like the rest (kept as plain fns, each its own)
    let turi = format!("file://{}/tests.volt", s.dir.display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{turi}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js("fn main() -> void {}\ntest \"one\" {\n    val x = nope;\n}\ntest \"two\" {\n}\n")));
    let d = s.diagnostics_for(&turi);
    assert!(d.contains("unknown name 'nope'") && !d.contains("defined"), "{d}");

    // an error where `missing` is (line 18, from character 31)
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(PROGRAM)));
    let d = s.diagnostics();
    assert!(d.contains("unknown name 'missing'") && d.contains("\"start\":{\"line\":18,\"character\":31}") && d.contains("\"severity\":1"), "{d}");

    // fixed: no diagnostics
    let fixed = PROGRAM.replace("total + missing", "total");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":2}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&fixed)));
    let d = s.diagnostics();
    assert!(d.contains("\"diagnostics\":[]"), "{d}");

    // hover: a local's type, a fn's signature
    let h = s.request("textDocument/hover", &at(18, 23));
    assert!(h.contains("total: i32"), "hover total: {h}");
    let h = s.request("textDocument/hover", &at(17, 20));
    assert!(h.contains("p: point"), "hover p: {h}");
    let h = s.request("textDocument/hover", &at(17, 16));
    assert!(h.contains("fn add(a: i32, b: i32) -> i32"), "hover add: {h}");

    // definition: a fn, a method, a field
    let def = s.request("textDocument/definition", &at(17, 16));
    assert!(def.contains(&uri) && def.contains("\"start\":{\"line\":11,\"character\":3}"), "definition add: {def}");
    let def = s.request("textDocument/definition", &at(17, 29));
    assert!(def.contains("\"start\":{\"line\":7,"), "definition sum: {def}");
    let def = s.request("textDocument/definition", &at(17, 22));
    assert!(def.contains("\"start\":{\"line\":3,\"character\":4}"), "definition x: {def}");

    // a type name, and a field named in a struct literal
    let h = s.request("textDocument/hover", &at(16, 12));
    assert!(h.contains("struct point"), "hover point: {h}");
    let def = s.request("textDocument/definition", &at(16, 12));
    assert!(def.contains("\"start\":{\"line\":2,\"character\":7}"), "definition point: {def}");
    let h = s.request("textDocument/hover", &at(16, 21));
    assert!(h.contains("x: i32"), "hover literal x: {h}");
    let def = s.request("textDocument/definition", &at(16, 21));
    assert!(def.contains("\"start\":{\"line\":3,\"character\":4}"), "definition literal x: {def}");

    // references to add: its declaration and the call
    let refs = s.request("textDocument/references", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":11,\"character\":4}},\"context\":{{\"includeDeclaration\":true}}}}"));
    assert!(refs.contains("\"line\":11") && refs.contains("\"line\":17"), "references: {refs}");

    // the file's symbols
    let sym = s.request("textDocument/documentSymbol", &doc_param(&doc));
    for name in ["\"point\"", "\"sum\"", "\"add\"", "\"main\""] {
        assert!(sym.contains(name), "symbols lack {name}: {sym}");
    }

    // completion while typing (the text doesn't parse): members after `p.`, a namespace's names
    // after `std::`, and names in scope
    let typing = fixed.replace("    std::println(\"{}\", total);\n", "    p.\n    std::pr\n    to\n");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":3}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&typing)));
    let c = s.request("textDocument/completion", &at(18, 6));
    for item in ["\"label\":\"x\"", "\"label\":\"y\"", "\"label\":\"sum\""] {
        assert!(c.contains(item), "completion after p. lacks {item}: {c}");
    }
    let c = s.request("textDocument/completion", &at(19, 11));
    assert!(c.contains("\"label\":\"println\""), "completion after std:: lacks println: {c}");
    let c = s.request("textDocument/completion", &at(20, 6));
    for item in ["\"label\":\"total\"", "\"label\":\"add\"", "\"label\":\"return\""] {
        assert!(c.contains(item), "plain completion lacks {item}: {c}");
    }

    // signature help inside add(...), at its second argument
    let sig_text = fixed.replace("    std::println(\"{}\", total);\n", "    add(1, \n");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"version\":4}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&sig_text)));
    let h = s.request("textDocument/signatureHelp", &at(18, 11));
    assert!(h.contains("fn add(a: i32, b: i32) -> i32") && h.contains("\"activeParameter\":1"), "signature help: {h}");

    // a bolt package's dependencies come from `bolt metadata`: app uses geo (a path dependency),
    // and a file of geo's library is checked as part of package geo
    let geo = s.dir.join("geo");
    let app = s.dir.join("app");
    std::fs::create_dir_all(geo.join("lib")).unwrap();
    std::fs::create_dir_all(app.join("src")).unwrap();
    std::fs::write(geo.join("bolt.toml"), "[package]\nname = \"geo\"\nversion = \"0.1.0\"\n").unwrap();
    let shapes = "// areas\npublic fn area(w: i32, h: i32) -> i32 {\n    return w * h;\n}\n";
    std::fs::write(geo.join("lib/shapes.volt"), shapes).unwrap();
    // an unreadable file in a library is left out; it doesn't take the server down
    let locked = geo.join("lib/locked.volt");
    std::fs::write(&locked, "fn locked() -> void {}\n").unwrap();
    std::fs::set_permissions(&locked, std::os::unix::fs::PermissionsExt::from_mode(0o000)).unwrap();
    std::fs::write(app.join("bolt.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\ngeo = { path = \"../geo\" }\n").unwrap();
    let main = "use std::io;\n\nfn main() -> void {\n    std::println(\"{}\", geo::area(2, 3));\n}\n";
    std::fs::write(app.join("src/main.volt"), main).unwrap();
    let app_uri = format!("file://{}", app.join("src/main.volt").display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{app_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(main)));
    let d = s.diagnostics_for(&app_uri);
    assert!(d.contains("\"diagnostics\":[]"), "app using geo: {d}");
    let h = s.request("textDocument/hover", &format!("{{\"textDocument\":{{\"uri\":\"{app_uri}\"}},\"position\":{{\"line\":3,\"character\":29}}}}"));
    assert!(h.contains("fn area(w: i32, h: i32) -> i32"), "hover geo::area: {h}");
    let geo_uri = format!("file://{}", geo.join("lib/shapes.volt").display());
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{geo_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(shapes)));
    let d = s.diagnostics_for(&geo_uri);
    assert!(d.contains("\"diagnostics\":[]"), "geo's own file: {d}");

    inline_features(&mut s);

    let r = s.request("shutdown", "null");
    assert!(r.contains("\"result\":null"), "{r}");
    s.notify("exit", "null");
    let st = s.child.wait().unwrap();
    assert!(st.success(), "the server exited with {st}");
    let _ = std::fs::remove_dir_all(&s.dir);
}

/// what the server shows inline (lsp_inline.volt), on a program of its own
const INLINE: &str = "use std::io;

trait shape {
    fn area(this) -> f64;
}

struct circle {
    r: f64;
}

enum color {
    RED,
    GREEN: i32,
}

attach shape -> circle {
    fn area(this) -> f64 {
        return 3.0 * this.r * this.r;
    }
}

attach fn grow(this: circle&, by: f64) -> void {
    this.r += by;
}

<T: shape>
fn report(s: T&, scale: f64) -> f64 {
    return s.area() * scale;
}

fn main() -> void {
    var c: circle = { r: 1.0 };
    val k = color::GREEN(2);
    val doubled = report(&c, 2.0);
    c.grow(1.0);
    std::println(\"{} {}\", doubled, @sizeof(circle));
}

fn first(x: u16?, c: circle) -> f64 {
    val wide: circle = { ..c, r: 2.0 };
    std::println(\"r {wide.r}\");
    if (val n = x) {
        return wide.r + @cast<f64>(n);
    }
    return c.r;
}
";

fn inline_features(s: &mut Server) {
    let uri = format!("file://{}/inline.volt", s.dir.display());
    let doc = format!("{{\"uri\":\"{uri}\"}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(INLINE)));
    let d = s.diagnostics_for(&uri);
    assert!(d.contains("\"diagnostics\":[]"), "inline.volt: {d}");

    // semantic tokens: what each name is (the legend's order: lsp_inline.volt)
    let types = ["namespace", "type", "struct", "enum", "interface", "typeParameter", "parameter", "variable", "property", "enumMember", "function", "method", "macro"];
    let mods = ["declaration", "readonly", "defaultLibrary"];
    let r = s.request("textDocument/semanticTokens/full", &doc_param(&doc));
    let lines: Vec<&str> = INLINE.lines().collect();
    let (mut line, mut col, mut got) = (0usize, 0usize, Vec::new());
    for t in numbers(&r, "\"data\":[").chunks(5) {
        line += t[0];
        col = if t[0] == 0 { col + t[1] } else { t[1] };
        let ms: Vec<&str> = (0..mods.len()).filter(|b| t[4] >> b & 1 == 1).map(|b| mods[b]).collect();
        got.push(format!("{} {} {}", &lines[line][col..col + t[2]], types[t[3]], ms.join(" ")).trim_end().to_string());
    }
    for want in ["std namespace", "io namespace", "shape interface declaration", "shape interface", "circle struct declaration", "r property declaration", "GREEN enumMember declaration", "GREEN enumMember", "T typeParameter declaration", "T typeParameter", "report function declaration", "grow method declaration", "grow method", "s parameter declaration readonly", "c variable declaration", "k variable declaration readonly", "println function defaultLibrary", "@sizeof macro", "area method"] {
        assert!(got.iter().any(|g| g == want), "semantic tokens lack `{want}`: {got:?}");
    }

    // inlay hints: the types of locals that don't write one, the parameters arguments are for
    // (not for one-letter parameters, nor where the argument names it already)
    let range = "\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":40,\"character\":0}}";
    let h = s.request("textDocument/inlayHint", &format!("{{\"textDocument\":{doc},{range}}}"));
    for want in ["\"label\":\": color\"", "\"label\":\": f64\"", "\"label\":\"scale:\"", "\"label\":\"by:\""] {
        assert!(h.contains(want), "inlay hints lack {want}: {h}");
    }
    // an if's binding gets one; the hidden locals an if binding or a struct update is parsed into don't
    assert!(h.contains("\"label\":\": u16\""), "inlay hints lack the if binding's type: {h}");
    for unwanted in ["\"label\":\": circle\"", "\"label\":\"s:\"", "\"label\":\": u16?\""] {
        assert!(!h.contains(unwanted), "inlay hints have {unwanted}: {h}");
    }

    let at = |line: u32, ch: u32| format!("{{\"textDocument\":{doc},\"position\":{{\"line\":{line},\"character\":{ch}}}}}");
    // a local named in a format string is used where its name is written, inside the string
    let h = s.request("textDocument/documentHighlight", &at(39, 8));
    assert!(h.contains("\"start\":{\"line\":40,\"character\":21}"), "highlight of wide lacks its {{wide.r}}: {h}");
    // highlights: the field r where it's declared and everywhere it's used
    let h = s.request("textDocument/documentHighlight", &at(7, 5));
    for line in [7, 17, 22, 31] {
        assert!(h.contains(&format!("\"start\":{{\"line\":{line},")), "highlight of r lacks line {line}: {h}");
    }

    // rename: grow where it's declared and called; not a std fn, not to a keyword
    let r = s.request("textDocument/prepareRename", &at(21, 11));
    assert!(r.contains("\"placeholder\":\"grow\""), "prepareRename grow: {r}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":21,\"character\":11}},\"newName\":\"enlarge\"}}"));
    assert!(r.contains("\"newText\":\"enlarge\"") && r.contains("\"line\":21,") && r.contains("\"line\":34,"), "rename grow: {r}");
    let r = s.request("textDocument/prepareRename", &at(35, 10));
    assert!(r.contains("\"result\":null"), "prepareRename println: {r}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{doc},\"position\":{{\"line\":21,\"character\":11}},\"newName\":\"fn\"}}"));
    assert!(r.contains("\"error\"") && r.contains("isn't a name"), "rename to a keyword: {r}");

    // hover on a type: its fields, then what's attached to it, grouped by trait; a trait's attachers
    let h = s.request("textDocument/hover", &at(31, 12));
    assert!(h.contains("struct circle {\\n    r: f64;\\n}\\n// shape\\nfn area(this) -> f64\\n// attached\\nattach fn grow(this: circle&, by: f64) -> void"), "hover circle: {h}");
    let h = s.request("textDocument/hover", &at(2, 8));
    assert!(h.contains("// attached by\\ncircle"), "hover shape: {h}");

    // what comptime code became: hover on a generic call adds the instance it runs, and volt/expand
    // lists a line's
    let h = s.request("textDocument/hover", &at(33, 20));
    assert!(h.contains("expands to\\n```volt\\ncalls report<circle>(s: circle&, scale: f64) -> f64"), "hover report: {h}");
    let e = s.request("volt/expand", &format!("{{\"textDocument\":{doc},\"line\":33}}"));
    assert!(e.contains("\"text\":\"calls report<circle>(s: circle&, scale: f64) -> f64\"") && e.contains("\"start\":{\"line\":33,\"character\":18}"), "volt/expand: {e}");
    let e = s.request("volt/expand", &format!("{{\"textDocument\":{doc},\"line\":32}}"));
    assert!(e.contains("\"result\":[]"), "volt/expand of a line without comptime code: {e}");
    // the same from the command line: voltc expand FILE, and FILE:LINE for one line's
    let expand = |arg: &str| {
        let out = Command::new(s.dir.join("voltc")).args(["expand", arg]).current_dir(ROOT).env("VOLT_STD", Path::new(ROOT).join("std")).output().unwrap();
        assert!(out.status.success(), "voltc expand {arg}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).into_owned()
    };
    let all = expand("tests/run/expand.volt");
    for want in [":6:22: attach eq -> point {}", ":20:7: attach fn get_x(this: point&) -> i32 {", ":32:13: 32 (usize)", ":36:13: = \"hi\" (str)", ":39:9: comptime match: 16, this arm", ":42:25: comptime for: 3 copies, i = 0, 1, 2", ":47:18: comptime if: true, this branch"] {
        assert!(all.contains(want), "voltc expand lacks {want}: {all}");
    }
    let one = expand("tests/run/expand.volt:34");
    assert!(one.contains(":34:21: calls twice<i64>(v: i64) -> i64") && !one.contains(":33:"), "voltc expand FILE:34: {one}");

    // code lenses: references above fns, attached fns and traits above types, attachers above a
    // trait, Run above main
    let l = s.request("textDocument/codeLens", &doc_param(&doc));
    for want in ["attached fns", "shape", "1 type attaches it", "1 reference", "volt.showLocations", "\"command\":\"volt.run\""] {
        assert!(l.contains(want), "code lenses lack {want}: {l}");
    }

    // quick fixes: diagnostics carry their fixes as data, and codeAction turns them into edits
    let fix_uri = format!("file://{}/fixes.volt", s.dir.display());
    let fix_src = "fn bump(r: i32&) -> void {\n    *r += 1;\n}\n\nfn main() -> void {\n    val x = 0;\n    bump(&x);\n    var y = 0;\n    y + 1;\n}\n";
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{fix_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(fix_src)));
    let d = s.diagnostics_for(&fix_uri);
    assert!(d.contains("\"fixes\":[") && d.contains("declare 'x' with var"), "fixes in diagnostics: {d}");
    let key = "\"diagnostics\":";
    let diags = &d[d.find(key).unwrap() + key.len()..d.len() - 2];
    let a = s.request("textDocument/codeAction", &format!("{{\"textDocument\":{{\"uri\":\"{fix_uri}\"}},\"range\":{{\"start\":{{\"line\":0,\"character\":0}},\"end\":{{\"line\":0,\"character\":0}}}},\"context\":{{\"diagnostics\":{diags}}}}}"));
    assert!(a.contains("\"kind\":\"quickfix\"") && a.contains("\"newText\":\"var\"") && a.contains("\"start\":{\"line\":5,\"character\":4}"), "codeAction val -> var: {a}");

    // a closure parameter's type, the end of a long block; and nothing from an older check: when the
    // text no longer parses, tokens and hints say ContentModified and rename refuses
    let long_uri = format!("file://{}/long.volt", s.dir.display());
    let mut long_src = String::from("fn apply(f: fn(i32) -> i32, x: i32) -> i32 {\n    return f(x);\n}\n\nfn main() -> void {\n    val r0 = apply(|| (n) -> i32 { return n * 2; }, 3);\n");
    for i in 0..25 {
        long_src.push_str(&format!("    val v{i} = r0 + {i};\n"));
    }
    long_src.push_str("}\n");
    let long_doc = format!("{{\"uri\":\"{long_uri}\"}}");
    s.notify("textDocument/didOpen", &format!("{{\"textDocument\":{{\"uri\":\"{long_uri}\",\"languageId\":\"volt\",\"version\":1,\"text\":{}}}}}", js(&long_src)));
    let d = s.diagnostics_for(&long_uri);
    assert!(d.contains("\"diagnostics\":[]"), "long.volt: {d}");
    let h = s.request("textDocument/inlayHint", &format!("{{\"textDocument\":{long_doc},{range}}}"));
    assert!(h.contains("\"position\":{\"line\":5,\"character\":24},\"label\":\": i32\"") && h.contains("\"label\":\"fn main\""), "closure parameter and closing brace hints: {h}");
    s.notify("textDocument/didChange", &format!("{{\"textDocument\":{{\"uri\":\"{long_uri}\",\"version\":2}},\"contentChanges\":[{{\"text\":{}}}]}}", js(&format!("\n\n{long_src}fn broken( {{\n"))));
    let t = s.request("textDocument/semanticTokens/full", &doc_param(&long_doc));
    assert!(t.contains("-32801"), "tokens for changed text: {t}");
    let r = s.request("textDocument/rename", &format!("{{\"textDocument\":{long_doc},\"position\":{{\"line\":2,\"character\":4}},\"newName\":\"run\"}}"));
    assert!(r.contains("\"error\"") && r.contains("fix them, then rename"), "rename on changed text: {r}");

    // folding: blocks (the closing brace stays in view)
    let f = s.request("textDocument/foldingRange", &doc_param(&doc));
    assert!(f.contains("\"startLine\":30,\"endLine\":35") && f.contains("\"startLine\":2,\"endLine\":3"), "folding: {f}");
}

/// the numbers in the JSON array that starts after `key`
fn numbers(json: &str, key: &str) -> Vec<usize> {
    let start = json.find(key).unwrap_or_else(|| panic!("no {key} in {json}")) + key.len();
    let end = start + json[start..].find(']').unwrap();
    json[start..end].split(',').filter(|x| !x.is_empty()).map(|x| x.trim().parse().unwrap()).collect()
}

fn doc_param(doc: &str) -> String {
    format!("{{\"textDocument\":{doc}}}")
}
