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
        let mut child = Command::new(&voltc)
            .arg("lsp")
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
            if m.contains(&format!("\"id\":{id}")) && !m.contains("\"method\"") {
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
    let shapes = "// areas\nfn area(w: i32, h: i32) -> i32 {\n    return w * h;\n}\n";
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

    let r = s.request("shutdown", "null");
    assert!(r.contains("\"result\":null"), "{r}");
    s.notify("exit", "null");
    let st = s.child.wait().unwrap();
    assert!(st.success(), "the server exited with {st}");
    let _ = std::fs::remove_dir_all(&s.dir);
}

fn doc_param(doc: &str) -> String {
    format!("{{\"textDocument\":{doc}}}")
}
