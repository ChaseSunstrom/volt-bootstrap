// bolt end to end: a new package with a path dependency, a git dependency (a local repo), a build
// file with steps, tests, and libraries that aren't rebuilt when nothing changed; workspaces,
// features, profiles and targets; and every command (add/remove, update, tree, metadata, install...).
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

/// write a file, making its directories
fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

/// stdout and stderr of a command that must have succeeded
fn ok(o: Output, what: &str) -> String {
    let (out, err) = (String::from_utf8_lossy(&o.stdout).to_string(), String::from_utf8_lossy(&o.stderr).to_string());
    assert!(o.status.success(), "{what} failed\n--- stdout\n{out}\n--- stderr\n{err}");
    out + "\n" + &err
}

#[test]
fn bolt() {
    let tmp = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("bolt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp).unwrap();
    let bolt = |dir: &Path, args: &[&str]| {
        Command::new(env!("CARGO_BIN_EXE_bolt"))
            .args(args)
            .current_dir(dir)
            .env("VOLTC", env!("CARGO_BIN_EXE_voltc-bootstrap"))
            .env("BOLT_HOME", tmp.join("cache"))
            .output()
            .unwrap()
    };
    let git = |dir: &Path, args: &[&str]| {
        let o = Command::new("git").args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]).args(args).current_dir(dir).output().unwrap();
        ok(o, &format!("git {}", args.join(" ")));
    };

    // a path dependency
    write(&tmp.join("mathx/bolt.toml"), "[package]\nname = \"mathx\"\nversion = \"0.1.0\"\n");
    write(&tmp.join("mathx/lib/ops.volt"), "fn triple(x: i32) -> i32 { return x * 3; }\n");
    // a git dependency, which itself depends on mathx by path
    let greet = tmp.join("greet");
    write(&greet.join("bolt.toml"), &format!("[package]\nname = \"greet\"\nversion = \"1.0.0\"\n\n[dependencies]\nmathx = {{ path = \"{}\" }}\n", tmp.join("mathx").display()));
    write(&greet.join("lib/greet.volt"), "use std::io;\nfn hello(who: str) -> void { std::println(\"hello {} x{}\", who, mathx::triple(2)); }\n");
    git(&greet, &["init", "-q"]);
    git(&greet, &["add", "."]);
    git(&greet, &["commit", "-q", "-m", "v1"]);

    ok(bolt(&tmp, &["new", "app"]), "bolt new");
    let app = tmp.join("app");
    write(
        &app.join("bolt.toml"),
        &format!(
            "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\nmathx = {{ path = \"../mathx\" }}\ngreet = {{ git = \"file://{}\" }}\n\n[build]\nfiles = [\"build.volt\"]\n",
            greet.display()
        ),
    );
    write(
        &app.join("src/main.volt"),
        "use std::io;\nfn main() -> void {\n    greet::hello(\"app\");\n    std::println(\"{} {}\", mathx::triple(5), std::process::arg(1) ?? \"-\");\n}\n",
    );
    write(
        &app.join("build.volt"),
        "fn main() -> void {\n    val word = bolt::option(\"word\", \"plain\");\n    bolt::c_source(\"native/add.c\");\n    bolt::link_c(\"m\");\n    bolt::cc_arg(\"-DADD_BIAS=0\");\n    bolt::exe(\"tool\", \"tools\");\n    bolt::step(\"demo\");\n    bolt::cmd(\"demo\", \"echo\", \"step says\", word);\n    bolt::cmd(\"demo\", \"sh\", \"-c\", \"IFS=; echo cc: $BOLT_CC_ARGS\");\n    bolt::run(\"demo\", \"app\", \"from-step\");\n    bolt::run(\"demo\", \"tool\");\n}\n",
    );
    // ADD_BIAS comes from the build file's cc_arg
    write(&app.join("native/add.c"), "int c_add(int a, int b) { return a + b + ADD_BIAS; }\n");
    write(&app.join("tools/tool.volt"), "use std::io;\nextern \"C\" fn c_add(a: i32, b: i32) -> i32;\nfn main() -> void { std::println(\"tool {}\", c_add(40, 2)); }\n");
    write(&app.join("tests/sums.volt"), "fn main() -> i32 { return mathx::triple(0); }\n");

    let out = ok(bolt(&app, &["run", "--", "arg1"]), "bolt run");
    assert!(out.contains("hello app x6\n15 arg1"), "{out}");
    let lock = std::fs::read_to_string(app.join("bolt.lock")).unwrap();
    assert!(lock.contains("commit = \""), "{lock}");

    // nothing changed: libraries aren't compiled again
    let out = ok(bolt(&app, &["build"]), "bolt build");
    assert!(!out.contains("Compiling mathx") && !out.contains("Compiling std"), "{out}");

    let out = ok(bolt(&app, &["build", "demo", "-Dword=loud"]), "bolt build demo");
    assert!(out.contains("step says loud") && out.contains("15 from-step") && out.contains("tool 42"), "{out}");
    // steps see what the executables were linked with, one per line
    assert!(out.contains("native/add.c\n-lm\n-DADD_BIAS=0\n"), "{out}");

    let out = ok(bolt(&app, &["run", "--release", "--bin", "app"]), "bolt run --release");
    assert!(out.contains("hello app x6") && app.join("target/release/deps/libstd.a").is_file(), "{out}");

    let out = ok(bolt(&app, &["test"]), "bolt test");
    assert!(out.contains("test sums ... ok"), "{out}");

    // the lock keeps the commit even after the dependency moves on
    write(&greet.join("lib/greet.volt"), "use std::io;\nfn hello(who: str) -> void { std::println(\"changed\"); }\n");
    git(&greet, &["commit", "-q", "-am", "v2"]);
    let out = ok(bolt(&app, &["run"]), "bolt run (locked)");
    assert!(out.contains("hello app x6"), "{out}");

    // a package can bring its own std
    let alt = tmp.join("alt");
    let alt_std = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/std_alt");
    write(&alt.join("bolt.toml"), &format!("[package]\nname = \"alt\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", alt_std.display()));
    write(&alt.join("src/main.volt"), "use std::out;\nfn main() -> void { std::say(\"custom std {}\", 1); }\n");
    let out = ok(bolt(&alt, &["run"]), "bolt run (custom std)");
    assert!(out.contains("custom std 1"), "{out}");

    // switching std rebuilds the cached libstd.a
    let sw = tmp.join("sw");
    write(&sw.join("bolt.toml"), "[package]\nname = \"sw\"\nversion = \"0.1.0\"\n");
    write(&sw.join("src/main.volt"), "use std::io;\nfn main() -> void { std::println(\"default std\"); }\n");
    assert!(ok(bolt(&sw, &["run"]), "bolt run (default std)").contains("default std"));
    write(&sw.join("bolt.toml"), &format!("[package]\nname = \"sw\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n", alt_std.display()));
    write(&sw.join("src/main.volt"), "use std::out;\nfn main() -> void { std::say(\"switched\"); }\n");
    assert!(ok(bolt(&sw, &["run"]), "bolt run (switched std)").contains("switched"));

    // steps that depend on each other, and arguments that would break the directive lines
    write(&sw.join("bolt.toml"), "[package]\nname = \"sw\"\nversion = \"0.1.0\"\n\n[build]\nfiles = [\"build.volt\"]\n");
    write(&sw.join("src/main.volt"), "fn main() -> void {}\n");
    write(&sw.join("build.volt"), "fn main() -> void {\n    bolt::step(\"a\");\n    bolt::step(\"b\");\n    bolt::depends(\"a\", \"b\");\n    bolt::depends(\"b\", \"a\");\n    bolt::step(\"t\");\n    bolt::cmd(\"t\", \"echo\", bolt::option(\"arg\", \"x\"));\n}\n");
    let o = bolt(&sw, &["build", "a"]);
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("steps depend on each other: a -> b -> a"), "{}", String::from_utf8_lossy(&o.stderr));
    let o = bolt(&sw, &["build", "t", "-Darg=tab\there"]);
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("can't contain tabs"), "{}", String::from_utf8_lossy(&o.stderr));

    // build files compile against the build's std, whatever $VOLT_STD says; and a $VOLT_STD that
    // isn't a directory is named as the problem
    let pinned = tmp.join("pinned");
    let real_std = Path::new(env!("CARGO_MANIFEST_DIR")).join("std");
    write(&pinned.join("bolt.toml"), &format!("[package]\nname = \"pinned\"\nversion = \"0.1.0\"\n\n[std]\npath = \"{}\"\n\n[build]\nfiles = [\"build.volt\"]\n", real_std.display()));
    write(&pinned.join("src/main.volt"), "fn main() -> void {}\n");
    write(&pinned.join("build.volt"), "fn main() -> void {}\n");
    let stale = tmp.join("no-such-std");
    let o = Command::new(env!("CARGO_BIN_EXE_bolt")).arg("build").current_dir(&pinned).env("VOLTC", env!("CARGO_BIN_EXE_voltc-bootstrap")).env("BOLT_HOME", tmp.join("cache")).env("VOLT_STD", &stale).output().unwrap();
    ok(o, "bolt build ([std] path, a stale $VOLT_STD)");
    let o = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("std-dir").env("VOLT_STD", &stale).output().unwrap();
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("$VOLT_STD") && err.contains("no-such-std"), "{err}");

    // a dependency can't smuggle git options in through its url
    let evil = tmp.join("evil");
    write(&evil.join("bolt.toml"), "[package]\nname = \"evil\"\nversion = \"0.1.0\"\n\n[dependencies]\nx = { git = \"--upload-pack=touch /tmp/pwned\" }\n");
    write(&evil.join("src/main.volt"), "fn main() -> void {}\n");
    let o = bolt(&evil, &["build"]);
    assert!(!o.status.success() && String::from_utf8_lossy(&o.stderr).contains("can't start with '-'"));

    let bad = bolt(&app, &["build", "nope"]);
    assert!(!bad.status.success() && String::from_utf8_lossy(&bad.stderr).contains("no step 'nope'"));

    // --error-limit goes through to voltc: two errors, one shown
    let two = tmp.join("two");
    write(&two.join("bolt.toml"), "[package]\nname = \"two\"\nversion = \"0.1.0\"\n");
    write(&two.join("src/main.volt"), "fn a() -> i32 { return true; }\nfn b() -> i32 { return \"b\"; }\nfn main() -> void {}\n");
    let o = bolt(&two, &["check", "--error-limit", "1"]);
    let err = String::from_utf8_lossy(&o.stderr);
    assert!(!o.status.success() && err.contains("aborting due to 2 errors (1 shown") && !err.contains("found str"), "{err}");
    let _ = std::fs::remove_dir_all(&tmp);
}

/// a scratch directory for one test, and bolt run with its cache inside it
struct Env {
    tmp: PathBuf,
}

impl Env {
    fn new(name: &str) -> Env {
        let tmp = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("bolt-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        Env { tmp }
    }
    fn run(&self, dir: &Path, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_bolt"))
            .args(args)
            .current_dir(dir)
            .env("VOLTC", env!("CARGO_BIN_EXE_voltc-bootstrap"))
            .env("BOLT_HOME", self.tmp.join("cache"))
            .env_remove("BOLT_INSTALL_ROOT")
            .output()
            .unwrap()
    }
    /// stdout + stderr of a bolt command that must succeed
    fn ok(&self, dir: &Path, args: &[&str]) -> String {
        ok(self.run(dir, args), &format!("bolt {}", args.join(" ")))
    }
    /// stderr of a bolt command that must fail
    fn fails(&self, dir: &Path, args: &[&str]) -> String {
        let o = self.run(dir, args);
        let err = String::from_utf8_lossy(&o.stderr).to_string();
        assert!(!o.status.success(), "bolt {} should fail\n{}{err}", args.join(" "), String::from_utf8_lossy(&o.stdout));
        err
    }
    fn git(&self, dir: &Path, args: &[&str]) {
        let o = Command::new("git").args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"]).args(args).current_dir(dir).output().unwrap();
        ok(o, &format!("git {}", args.join(" ")));
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if !std::thread::panicking() {
            let _ = std::fs::remove_dir_all(&self.tmp);
        }
    }
}

#[test]
fn workspace_features_profiles() {
    let e = Env::new("ws");
    let ws = e.tmp.join("ws");
    // a virtual workspace: members by glob, one target/ and bolt.lock, profiles for everyone
    write(&ws.join("bolt.toml"), "[workspace]\nmembers = [\"crates/*\"]\n\n[profile.fast]\ninherits = \"release\"\ncc-flags = [\"-DFAST=1\"]\n");
    let c = ws.join("crates");
    write(&c.join("helper/bolt.toml"), "[package]\nname = \"helper\"\nversion = \"0.3.1\"\n");
    write(&c.join("helper/lib/helper.volt"), "fn name() -> str { return \"helper\"; }\n");
    write(
        &c.join("core/bolt.toml"),
        "[package]\nname = \"core\"\nversion = \"0.1.0\"\n\n[dependencies]\nhelper = { path = \"../helper\", version = \"0.3\", optional = true }\n\n[features]\ndefault = [\"loud\"]\nloud = []\nextra = [\"dep:helper\"]\n",
    );
    write(
        &c.join("core/lib/core.volt"),
        "fn describe() -> str {\n    comptime if (@cfg(\"feature\", \"loud\")) {\n        return \"LOUD\";\n    }\n    return \"quiet\";\n}\nfn extra() -> str {\n    comptime if (@cfg(\"feature\", \"extra\")) {\n        return helper::name();\n    }\n    return \"-\";\n}\n",
    );
    write(&c.join("app/bolt.toml"), "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[dependencies]\ncore = { path = \"../core\", features = [\"extra\"] }\n\n[features]\nfancy-ui = []\n\n[build]\nfiles = [\"build.volt\"]\n");
    write(&c.join("app/src/main.volt"), "use std::io;\nfn main() -> void { std::println(\"app {} {}\", core::describe(), core::extra()); }\n");
    // a build file sees the profile and the package's features
    write(&c.join("app/build.volt"), "use std::io;\nfn main() -> void { std::println(\"build file: {} {}\", bolt::profile(), bolt::feature(\"fancy-ui\")); }\n");
    write(
        &c.join("quiet/bolt.toml"),
        "[package]\nname = \"quiet\"\nversion = \"0.1.0\"\n\n[dependencies]\ncore = { path = \"../core\", default-features = false }\n\n[features]\nshout = [\"core/loud\"]\n",
    );
    write(
        &c.join("quiet/src/main.volt"),
        "use std::io;\nfn main() -> void {\n    comptime if (@cfg(\"feature\", \"shout\")) {\n        std::print(\"shouting \");\n    }\n    std::println(\"quiet {} {}\", core::describe(), core::extra());\n}\n",
    );

    // the root builds every member into one target/
    let out = e.ok(&ws, &["build"]);
    assert!(out.contains("Compiling core v0.1.0") && out.contains("Finished `dev` profile"), "{out}");
    assert!(ws.join("target/debug/app").is_file() && ws.join("target/debug/quiet").is_file() && !c.join("app/target").exists());

    // each package's features: defaults, a dependency's features, --no-default-features off the dependency
    assert!(e.ok(&ws, &["run", "-p", "app"]).contains("app LOUD helper"));
    assert!(e.ok(&ws, &["build", "-p", "app", "--release", "--features", "fancy-ui"]).contains("build file: release true"));
    assert!(e.ok(&c.join("quiet"), &["run"]).contains("quiet quiet -"));
    assert!(e.ok(&ws, &["run", "-p", "quiet", "--features", "shout"]).contains("shouting quiet LOUD -"));
    assert!(e.ok(&ws, &["run", "-p", "quiet", "--features", "core/extra"]).contains("quiet quiet helper"));
    assert!(e.ok(&ws, &["run", "-p", "quiet", "--all-features"]).contains("shouting quiet LOUD -"));
    let err = e.fails(&ws, &["build", "-p", "app", "--features", "nope"]);
    assert!(err.contains("package app has no feature 'nope'"), "{err}");
    let err = e.fails(&ws, &["run"]);
    assert!(err.contains("several executables"), "{err}");

    // profiles: release and a custom one, each in its own directory
    let out = e.ok(&ws, &["build", "-p", "app", "--profile", "fast", "-v"]);
    assert!(ws.join("target/fast/app").is_file() && out.contains("-DFAST=1") && out.contains("--release"), "{out}");
    assert!(e.ok(&ws, &["build", "-p", "app", "--release"]).contains("Finished `release` profile [optimized]"));
    let err = e.fails(&ws, &["build", "--profile", "nope"]);
    assert!(err.contains("no profile 'nope'"), "{err}");

    // version requirements are checked against the dependency's [package] version
    write(&c.join("core/bolt.toml"), &std::fs::read_to_string(c.join("core/bolt.toml")).unwrap().replace("\"0.3\"", "\"^0.4\""));
    let err = e.fails(&ws, &["build"]);
    assert!(err.contains("core needs helper ^0.4, but") && err.contains("is 0.3.1"), "{err}");
    write(&c.join("core/bolt.toml"), &std::fs::read_to_string(c.join("core/bolt.toml")).unwrap().replace("\"^0.4\"", "\">=0.3.1, <0.4\""));

    // default-members that name nothing are an error, not an empty build
    let root_toml = std::fs::read_to_string(ws.join("bolt.toml")).unwrap();
    write(&ws.join("bolt.toml"), &root_toml.replace("members = [\"crates/*\"]", "members = [\"crates/*\"]\ndefault-members = [\"crates/gone\"]"));
    let err = e.fails(&ws, &["build"]);
    assert!(err.contains("default-members") && err.contains("crates/gone"), "{err}");
    write(&ws.join("bolt.toml"), &root_toml);

    // tree and metadata
    let tree = e.ok(&ws, &["tree", "-p", "app"]);
    assert!(tree.contains("app v0.1.0") && tree.contains("└── core v0.1.0") && tree.contains("    └── helper v0.3.1"), "{tree}");
    let meta = e.ok(&ws, &["metadata"]);
    for want in ["\"workspace_members\":[", "\"name\":\"quiet\"", "\"features\":{\"default\":[\"loud\"]", "\"kind\":\"bin\"", "\"target_directory\":"] {
        assert!(meta.contains(want), "metadata lacks {want}\n{meta}");
    }

    // check: types only, no libraries built
    write(&c.join("helper/lib/helper.volt"), "fn name() -> str { return 1; }\n");
    let err = e.fails(&ws, &["check", "-p", "helper"]);
    assert!(err.contains("helper.volt") && err.contains("error"), "{err}");
    write(&c.join("helper/lib/helper.volt"), "fn name() -> str { return \"helper\"; }\n");
    assert!(e.ok(&ws, &["check", "--workspace"]).contains("Finished"));
}

#[test]
fn targets_and_commands() {
    let e = Env::new("cmds");
    let t = &e.tmp;
    assert!(e.ok(t, &["--version"]).starts_with("bolt "));
    e.ok(t, &["new", "tools", "--lib"]);
    assert!(t.join("tools/lib/tools.volt").is_file() && !t.join("tools/src").exists());
    write(&t.join("tools/lib/tools.volt"), "fn twice(x: i32) -> i32 { return x * 2; }\n");
    write(&t.join("testutil/bolt.toml"), "[package]\nname = \"testutil\"\n\n[features]\nstrict = []\n");
    write(&t.join("testutil/lib/t.volt"), "fn expect(ok: bool) -> i32 { if (ok) { return 0; } return 1; }\n");

    std::fs::create_dir_all(t.join("app")).unwrap();
    e.ok(&t.join("app"), &["init"]);
    let app = t.join("app");
    assert!(app.join("bolt.toml").is_file() && app.join("src/main.volt").is_file());

    // add and remove keep the rest of the file as written
    let manifest = std::fs::read_to_string(app.join("bolt.toml")).unwrap() + "# keep this comment\n";
    write(&app.join("bolt.toml"), &manifest);
    let out = e.ok(&app, &["add", "--path", "../tools"]);
    assert!(out.contains("Adding tools"), "{out}");
    e.ok(&app, &["add", "testutil", "--path", "../testutil", "--dev"]);
    e.ok(&app, &["add", "--path", "../testutil"]);
    e.ok(&app, &["remove", "testutil"]);
    let m = std::fs::read_to_string(app.join("bolt.toml")).unwrap();
    assert!(m.contains("[dependencies]\ntools = { path = \"../tools\" }") && m.contains("[dev-dependencies]\ntestutil = { path = \"../testutil\" }") && m.contains("# keep this comment"), "{m}");
    assert!(!m.split("[dev-dependencies]").next().unwrap().contains("testutil"), "{m}");
    assert!(e.fails(&app, &["remove", "nothing"]).contains("no dependency 'nothing'"));
    assert!(e.fails(&app, &["add", "--path", "../nowhere"]).contains("nowhere"));
    assert_eq!(std::fs::read_to_string(app.join("bolt.toml")).unwrap(), m, "a failed add leaves bolt.toml alone");

    // every kind of target
    write(&app.join("src/main.volt"), "use std::io;\nfn main() -> void { std::println(\"main {}\", tools::twice(2)); }\n");
    write(&app.join("examples/demo.volt"), "use std::io;\nfn main() -> void { std::println(\"demo {}\", std::process::arg(1) ?? \"-\"); }\n");
    write(&app.join("tests/unit.volt"), "fn main() -> i32 { return testutil::expect(tools::twice(3) == 6); }\n");
    write(&app.join("tests/multi/main.volt"), "fn main() -> i32 { return testutil::expect(helper() == 7); }\n");
    write(&app.join("tests/multi/helper.volt"), "fn helper() -> i32 { return 7; }\n");
    write(&app.join("benches/speed.volt"), "fn main() -> void { var s: u64 = 0; for (i) in 0..1000 { s += @cast<u64>(i); } }\n");

    assert!(e.ok(&app, &["run"]).contains("main 4"));
    assert!(e.ok(&app, &["run", "--example", "demo", "--", "hi"]).contains("demo hi"));
    let out = e.ok(&app, &["test"]);
    assert!(out.contains("test multi ... ok") && out.contains("test unit ... ok") && out.contains("test result: ok. 2 passed; 0 failed"), "{out}");
    let out = e.ok(&app, &["test", "mul"]);
    assert!(out.contains("test multi ... ok") && !out.contains("test unit"), "{out}");
    e.ok(&app, &["test", "--no-run"]);
    // a dev-dependency's features, for the builds that use it
    e.ok(&app, &["test", "--no-run", "--features", "testutil/strict"]);
    assert!(app.join("target/debug/tests/unit").is_file());
    let out = e.ok(&app, &["bench"]);
    assert!(out.contains("bench speed ... ") && app.join("target/release/benches/speed").is_file(), "{out}");
    write(&app.join("tests/broken.volt"), "fn main() -> i32 { return 3; }\n");
    let o = e.run(&app, &["test"]);
    let out = String::from_utf8_lossy(&o.stdout).to_string();
    assert!(!o.status.success() && out.contains("test broken ... FAILED") && out.contains("1 failed"), "{out}");
    std::fs::remove_file(app.join("tests/broken.volt")).unwrap();
    // dev-dependencies are only for tests, examples and benches
    write(&app.join("src/main.volt"), "fn main() -> i32 { return testutil::expect(true); }\n");
    assert!(e.fails(&app, &["build"]).contains("testutil"));
    write(&app.join("src/main.volt"), "use std::io;\nfn main() -> void { std::println(\"main {}\", tools::twice(2)); }\n");

    // quiet and verbose, parallel
    let o = e.run(&app, &["build", "-q", "-j", "2"]);
    assert!(o.status.success() && o.stderr.is_empty(), "{}", String::from_utf8_lossy(&o.stderr));
    assert!(e.ok(&app, &["build", "-v", "--all-targets"]).contains("Running `"));

    // install and uninstall
    let root = t.join("root");
    let out = e.ok(t, &["install", "--path", "app", "--root", root.to_str().unwrap()]);
    assert!(out.contains("Installed package `app v0.1.0`"), "{out}");
    let o = Command::new(root.join("bin/app")).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&o.stdout), "main 4\n");
    assert!(e.fails(t, &["install", "--path", "app", "--root", root.to_str().unwrap()]).contains("--force"));
    e.ok(t, &["install", "--path", "app", "--root", root.to_str().unwrap(), "--force"]);
    e.ok(t, &["uninstall", "app", "--root", root.to_str().unwrap()]);
    assert!(!root.join("bin/app").exists());

    // git: a branch, update, --locked, --offline, fetch
    let lib = t.join("gitlib");
    write(&lib.join("bolt.toml"), "[package]\nname = \"gitlib\"\nversion = \"1.0.0\"\n");
    write(&lib.join("lib/g.volt"), "fn which() -> str { return \"v1\"; }\n");
    e.git(&lib, &["init", "-q"]);
    e.git(&lib, &["add", "."]);
    e.git(&lib, &["commit", "-q", "-m", "v1"]);
    let url = format!("file://{}", lib.display());
    e.ok(&app, &["add", "gitlib", "--git", &url, "--branch", "main"]);
    write(&app.join("src/main.volt"), "use std::io;\nfn main() -> void { std::println(\"git {}\", gitlib::which()); }\n");
    assert!(e.ok(&app, &["run"]).contains("git v1"));
    write(&lib.join("lib/g.volt"), "fn which() -> str { return \"v2\"; }\n");
    e.git(&lib, &["commit", "-q", "-am", "v2"]);
    assert!(e.ok(&app, &["run", "--locked", "--offline"]).contains("git v1"));
    let out = e.ok(&app, &["update"]);
    assert!(out.contains("Updating gitlib"), "{out}");
    assert!(e.ok(&app, &["run"]).contains("git v2"));
    e.ok(&app, &["fetch"]);
    std::fs::remove_file(app.join("bolt.lock")).unwrap();
    assert!(e.fails(&app, &["build", "--locked"]).contains("bolt.lock"));
    let other = t.join("other");
    write(&other.join("bolt.toml"), "[package]\nname = \"other\"\n\n[dependencies]\nnever = { git = \"file:///nonexistent/never\" }\n");
    write(&other.join("src/main.volt"), "fn main() -> void {}\n");
    assert!(e.fails(&other, &["build", "--offline"]).contains("offline"));
    assert!(e.fails(&other, &["build", "--frozen"]).contains("offline"));
}
