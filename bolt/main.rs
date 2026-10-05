// bolt: the Volt build tool, Cargo without a registry. A package is a directory with a bolt.toml;
// a workspace groups packages that build together. bolt resolves dependencies (local paths or git,
// pinned in bolt.lock), turns on features, precompiles every library once per profile with
// `voltc lib`, runs build files (Volt programs that add steps, like Zig's build.zig) and builds,
// runs, tests, benchmarks and installs executables.
mod build;
mod commands;
mod foreign;
mod hot;
mod import;
mod manifest;
mod progress;
mod resolve;
mod toml;

use build::{Build, Exe};
use manifest::Kind;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, exit};
use std::sync::OnceLock;
use std::time::Instant;

const USAGE: &str = "\
bolt: the Volt build tool

usage: bolt <command> [options]

commands:
  new PATH [--lib]        make a package in a new directory PATH (--lib: a library instead of a program)
  init [PATH] [--lib]     make a package in an existing directory (default: here)
  build [STEP] [-Dk=v]    build the package, or run a step from its build files (-D: their options)
  check                   type-check without building anything
  run [-- ARGS]           build and run an executable (--bin NAME, --example NAME)
  hot [FILES] [-- ARGS]   run it (or .volt FILES) sampled, and show where it spends its time: the
                          hottest functions, .volt lines and call paths (voltc --profiler; Linux)
  test [FILTER]           build and run tests/ (each program there must exit 0); --no-run builds only
  bench [FILTER]          build and time benches/ (with the bench profile)
  clean                   remove target/ (with --release or --profile: just that profile's)
  add [NAME[@REQ]]        add a dependency: --path DIR, or --git URL [--rev R | --branch B | --tag T];
                          --dev, --optional, --features F, --no-default-features
  remove NAME...          remove dependencies (--dev: dev-dependencies)
  update [NAME...]        move git dependencies to their newest commits (bolt.lock)
  fetch                   download every git dependency (to build --offline later)
  tree                    show the dependency tree
  metadata                describe the workspace as JSON
  install                 build a package (--path DIR, --git URL) with the release profile and copy
                          its executables to ROOT/bin (--root, $BOLT_INSTALL_ROOT, ~/.local)
  uninstall NAME...       remove what install put there

options:
  -p, --package NAME      work on this package (default: the one here, or the workspace's defaults)
  --workspace             work on every package in the workspace
  -r, --release           use the release profile (optimized)
  --profile NAME          use a profile: dev, release, test, bench or one from [profile.NAME]
  -F, --features LIST     turn on features (FEATURE, PACKAGE/FEATURE, DEPENDENCY/FEATURE)
  --all-features          turn on every feature of the selected packages
  --no-default-features   don't turn on their default features
  --bin NAME, --bins      that executable, or all of them (likewise --example(s), --test(s), --bench(es))
  --lib, --all-targets    the library only, or every kind of target
  -j, --jobs N            compile N things at once (default: one per CPU)
  --target-dir DIR        build in DIR instead of target/
  --manifest-path PATH    the bolt.toml to use (default: here or in a parent directory)
  --locked                fail if bolt.lock would change
  --offline               never touch the network
  --frozen                both --locked and --offline
  --backend c|llvm        the backend voltc uses (overrides the profile's)
  --message-format F      how voltc prints errors: human, short or json
  --color WHEN            auto, always or never
  --error-limit N         how many errors voltc shows (default 20; 0: all)
  -q, --quiet             print no progress lines
  -v, --verbose           print every command bolt runs
  -V, --version           print bolt's version
";

// ---------- output ----------

pub struct Ui {
    pub quiet: bool,
    verbose: bool,
    pub color: bool,
}

static UI: OnceLock<Ui> = OnceLock::new();

pub fn ui() -> &'static Ui {
    UI.get_or_init(|| Ui { quiet: false, verbose: false, color: false })
}

/// `text` in bold and colour (an ANSI colour number) when colour is on
pub fn paint(text: &str, color: u8) -> String {
    if ui().color { format!("\x1b[1;{color}m{text}\x1b[0m") } else { text.to_string() }
}

/// a cargo-style progress line on stderr: `what` right-aligned, then msg
pub fn status(what: &str, msg: impl std::fmt::Display) {
    if !ui().quiet {
        progress::above(&format!("{} {msg}\n", paint(&format!("{what:>12}"), 32)));
    }
}

pub fn warn(msg: impl std::fmt::Display) {
    if !ui().quiet {
        progress::above(&format!("{} {msg}\n", paint("warning:", 33)));
    }
}

pub fn fail(msg: impl std::fmt::Display) -> ! {
    progress::above(&format!("{} {msg}\n", paint("error:", 31)));
    exit(1);
}

/// with -v, the command about to run
pub fn verbose(c: &Command) {
    if ui().verbose {
        status("Running", format!("`{}`", build::show(c)));
    }
}

/// `.or_fail()`: the value, or stop with the error
pub trait OrFail<T> {
    fn or_fail(self) -> T;
}

impl<T, E: std::fmt::Display> OrFail<T> for Result<T, E> {
    fn or_fail(self) -> T {
        self.unwrap_or_else(|e| fail(e))
    }
}

// ---------- the command line ----------

/// the command, its words (a step, a filter, package or dependency names) and every option; each
/// command reads the ones it takes
#[derive(Default, Clone)]
pub struct Opts {
    pub cmd: String,
    pub words: Vec<String>,
    /// after `--`: the program's arguments (run)
    pub prog_args: Vec<String>,
    /// -Dk=v: build-file options
    pub defines: Vec<String>,
    pub release: bool,
    pub profile: Option<String>,
    pub features: Vec<String>,
    pub all_features: bool,
    pub no_default_features: bool,
    pub packages: Vec<String>,
    pub workspace: bool,
    pub bins: Vec<String>,
    pub examples: Vec<String>,
    pub tests: Vec<String>,
    pub benches: Vec<String>,
    /// --bins, --examples, --tests, --benches (or --all-targets): every target of that kind
    pub all_of: Vec<Kind>,
    pub lib: bool,
    pub target_dir: Option<PathBuf>,
    pub jobs: Option<usize>,
    pub locked: bool,
    pub offline: bool,
    pub manifest_path: Option<PathBuf>,
    pub message_format: Option<String>,
    pub color: Option<String>,
    pub error_limit: Option<String>,
    pub backend: Option<String>,
    pub path: Option<String>,
    pub git: Option<String>,
    pub rev: Option<String>,
    pub branch: Option<String>,
    pub tag: Option<String>,
    pub dev: bool,
    pub optional: bool,
    pub force: bool,
    pub no_run: bool,
    pub root: Option<PathBuf>,
    pub name: Option<String>,
    pub vcs: Option<String>,
}

/// options in any order, before or after the command; --opt=value works too
fn parse(args: Vec<String>) -> Opts {
    let mut o = Opts::default();
    let (mut quiet, mut verbose, mut color) = (false, false, "auto".to_string());
    let mut it = args.into_iter();
    while let Some(arg) = it.next() {
        let (a, mut inline) = match arg.split_once('=') {
            Some((k, v)) if arg.starts_with("--") => (k.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let mut val = || inline.take().or_else(|| it.next()).unwrap_or_else(|| fail(format!("{a} needs a value")));
        match a.as_str() {
            "-r" | "--release" => o.release = true,
            "--profile" => o.profile = Some(val()),
            "-F" | "--features" => o.features.extend(val().split([',', ' ']).filter(|f| !f.is_empty()).map(String::from)),
            "--all-features" => o.all_features = true,
            "--no-default-features" => o.no_default_features = true,
            "-p" | "--package" => o.packages.push(val()),
            "--workspace" | "--all" => o.workspace = true,
            "--bin" => o.bins.push(val()),
            "--example" => o.examples.push(val()),
            "--test" => o.tests.push(val()),
            "--bench" => o.benches.push(val()),
            "--bins" => o.all_of.push(Kind::Bin),
            "--examples" => o.all_of.push(Kind::Example),
            "--tests" => o.all_of.push(Kind::Test),
            "--benches" => o.all_of.push(Kind::Bench),
            "--all-targets" => o.all_of.extend([Kind::Bin, Kind::Example, Kind::Test, Kind::Bench]),
            "--lib" => o.lib = true,
            "--target-dir" => o.target_dir = Some(val().into()),
            "-j" | "--jobs" => o.jobs = Some(val().parse().ok().filter(|n| *n > 0).unwrap_or_else(|| fail("-j takes a number of jobs"))),
            "--locked" => o.locked = true,
            "--offline" => o.offline = true,
            "--frozen" => (o.locked, o.offline) = (true, true),
            "--manifest-path" => o.manifest_path = Some(val().into()),
            "--message-format" => o.message_format = Some(val()),
            "--error-limit" => o.error_limit = Some(val()).filter(|n| n.parse::<usize>().is_ok()).or_else(|| fail("--error-limit takes a number (0: no limit)")),
            "--color" => {
                color = val();
                if !["auto", "always", "never"].contains(&color.as_str()) {
                    fail("--color takes auto, always or never");
                }
                o.color = Some(color.clone());
            }
            "--backend" => o.backend = Some(val()).filter(|b| b == "c" || b == "llvm").or_else(|| fail("--backend takes c or llvm")),
            "--path" => o.path = Some(val()),
            "--git" => o.git = Some(val()),
            "--rev" => o.rev = Some(val()),
            "--branch" => o.branch = Some(val()),
            "--tag" => o.tag = Some(val()),
            "--root" => o.root = Some(val().into()),
            "--name" => o.name = Some(val()),
            "--vcs" => o.vcs = Some(val()),
            "--dev" => o.dev = true,
            "--optional" => o.optional = true,
            "--force" | "-f" => o.force = true,
            "--no-run" => o.no_run = true,
            "-q" | "--quiet" => quiet = true,
            "-v" | "--verbose" => verbose = true,
            "-h" | "--help" => o.cmd = "help".into(),
            "-V" | "--version" => o.cmd = "version".into(),
            "--" => o.prog_args.extend(it.by_ref()),
            d if d.starts_with("-D") && d.len() > 2 => o.defines.push(d.to_string()),
            f if f.starts_with('-') => fail(format!("unknown option '{f}' (see bolt help)")),
            _ if o.cmd.is_empty() => o.cmd = arg,
            _ => o.words.push(arg),
        }
    }
    use std::io::IsTerminal;
    let color = match color.as_str() {
        "always" => true,
        "never" => false,
        _ => std::io::stderr().is_terminal() && std::env::var_os("NO_COLOR").is_none() && std::env::var("TERM").map_or(true, |t| t != "dumb"),
    };
    let _ = UI.set(Ui { quiet, verbose, color });
    o
}

// ---------- targets ----------

/// does this command build tests, examples or benches (so dev-dependencies are needed)?
fn needs_dev(o: &Opts, default: &[Kind]) -> bool {
    let named = !o.examples.is_empty() || !o.tests.is_empty() || !o.benches.is_empty();
    let kinds = if o.all_of.is_empty() && o.bins.is_empty() && !named && !o.lib { default } else { &o.all_of[..] };
    named || kinds.iter().any(|k| *k != Kind::Bin)
}

/// was any target picked on the command line?
fn picked(o: &Opts) -> bool {
    !(o.bins.is_empty() && o.examples.is_empty() && o.tests.is_empty() && o.benches.is_empty() && o.all_of.is_empty() && !o.lib)
}

/// the executables a command works on: the named ones (--bin NAME...), whole kinds (--bins,
/// --all-targets), else every target of the default kinds; targets whose required features are off
/// are left out (or, when named, an error)
fn select(b: &Build, o: &Opts, default: &[Kind]) -> Vec<Exe> {
    let mut out: Vec<Exe> = Vec::new();
    for (kind, names) in [(Kind::Bin, &o.bins), (Kind::Example, &o.examples), (Kind::Test, &o.tests), (Kind::Bench, &o.benches)] {
        for n in names {
            let (r, t) = b.roots.iter().flat_map(|&r| b.g.pkgs[r].m.of(kind).map(move |t| (r, t))).find(|(_, t)| t.name == *n).unwrap_or_else(|| fail(format!("no {} target named '{n}'", kind.name())));
            if !b.has_features(r, t) {
                fail(format!("{} '{n}' needs the features {} (--features)", kind.name(), t.required_features.join(", ")));
            }
            out.push(b.exe_of(r, t));
        }
    }
    let kinds: &[Kind] = if picked(o) { &o.all_of } else { default };
    for &r in &b.roots {
        for t in b.g.pkgs[r].m.targets.iter().filter(|t| kinds.contains(&t.kind) && b.has_features(r, t)) {
            if !out.iter().any(|e| e.pkg == r && e.kind == t.kind && e.name == t.name) {
                out.push(b.exe_of(r, t));
            }
        }
    }
    for (i, e) in out.iter().enumerate() {
        if out[..i].iter().any(|x| x.kind == e.kind && x.name == e.name) {
            fail(format!("two packages have a {} called '{}': pick one with -p", e.kind.name(), e.name));
        }
    }
    out
}

/// the selected packages' build-file plans
fn plans(b: &Build, o: &Opts) -> HashMap<usize, build::Plan> {
    b.roots.iter().map(|&r| (r, b.plan(r, &o.defines).or_fail())).collect()
}

// ---------- building commands ----------

fn build_cmd(o: &Opts) {
    let start = Instant::now();
    let mut b = Build::new(o, "dev", needs_dev(o, &[Kind::Bin]));
    if let Some(step) = o.words.first() {
        let [r] = b.roots[..] else { fail("steps belong to one package: pick it with -p") };
        let plan = b.plan(r, &o.defines).or_fail();
        b.run_step(r, step, &plan).or_fail();
        return;
    }
    let plans = plans(&b, o);
    let mut exes = select(&b, o, &[Kind::Bin]);
    if !picked(o) {
        // build files' executables come with the package's own
        for (&r, plan) in &plans {
            exes.extend(b.install_exes(r, plan).into_iter().filter(|e| !exes.iter().any(|x| x.name == e.name)).collect::<Vec<_>>());
        }
    }
    // every selected library too (a library-only package builds just that)
    let libs: Vec<usize> = b.roots.iter().filter(|_| !picked(o) || o.lib).flat_map(|&r| b.closure(r, false)).collect();
    b.libraries(&libs).or_fail();
    b.executables(&exes, &plans).or_fail();
    if !picked(o) || o.lib {
        for r in b.roots.clone() {
            b.foreign(r).or_fail();
        }
    }
    b.finished(start);
}

fn check_cmd(o: &Opts) {
    let start = Instant::now();
    let b = Build::new(o, "dev", needs_dev(o, &[Kind::Bin]));
    let mut jobs: Vec<(usize, Option<Exe>)> = Vec::new();
    for &r in &b.roots {
        if b.g.pkgs[r].m.lib.is_some() && (!picked(o) || o.lib) {
            jobs.push((r, None));
        }
    }
    jobs.extend(select(&b, o, &[Kind::Bin]).into_iter().map(|e| (e.pkg, Some(e))));
    build::parallel(b.jobs, jobs, |(p, e)| b.check(p, e.as_ref())).or_fail();
    b.finished(start);
}

fn run_cmd(o: &Opts) {
    let start = Instant::now();
    let mut b = Build::new(o, "dev", !o.examples.is_empty());
    let exe = built_exe(&mut b, o);
    b.finished(start);
    let mut c = Command::new(&exe.out);
    c.args(&o.prog_args);
    status("Running", format!("`{}`", build::show(&c).replacen(&exe.out.display().to_string(), &build::rel(&exe.out), 1)));
    let st = c.status().unwrap_or_else(|e| fail(format!("can't run {}: {e}", exe.out.display())));
    exit(st.code().unwrap_or(1));
}

/// bolt hot: build with voltc --profiler (the package's executable, or loose .volt files), run it,
/// and report where it spent its time (hot.rs)
fn hot_cmd(o: &Opts) {
    let start = Instant::now();
    let files: Vec<&String> = o.words.iter().filter(|w| w.ends_with(".volt")).collect();
    let mut temp = None;
    let exe = if files.is_empty() {
        let mut b = Build::new(o, "release", !o.examples.is_empty());
        b.profiled();
        let exe = built_exe(&mut b, o);
        b.finished(start);
        exe.out
    } else {
        let dir = std::env::temp_dir().join(format!("bolt-hot-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_else(|e| fail(format!("can't make {}: {e}", dir.display())));
        let exe = dir.join(std::path::Path::new(files[0]).file_stem().unwrap_or_default());
        let mut c = Command::new(build::find_voltc());
        c.args(["build", "--release", "--profiler"]).args(&files).arg("-o").arg(&exe);
        if let Some(b) = &o.backend {
            c.args(["--backend", b]);
        }
        status("Building", files.iter().map(|f| f.as_str()).collect::<Vec<_>>().join(" "));
        let st = c.status().unwrap_or_else(|e| fail(format!("can't run voltc: {e}")));
        if !st.success() {
            exit(1);
        }
        temp = Some(dir);
        exe
    };
    let mut prof = exe.clone().into_os_string();
    prof.push(".prof");
    let prof = PathBuf::from(prof);
    let mut c = Command::new(&exe);
    c.args(&o.prog_args).env("VOLT_PROFILE_OUT", &prof);
    status("Running", format!("`{}` (sampling)", build::show(&c)));
    let st = c.status().unwrap_or_else(|e| fail(format!("can't run {}: {e}", exe.display())));
    if !st.success() {
        status("Note", format!("the program exited with {}", st.code().map_or("a signal".to_string(), |c| c.to_string())));
    }
    let text = hot::read_profile(&prof).and_then(|p| hot::report(&exe, &p, 10));
    if let Some(d) = temp {
        let _ = std::fs::remove_dir_all(d);
    }
    print!("\n{}", text.unwrap_or_else(|e| fail(e)));
}

/// the executable `run` (and `hot`) means, built: --bin/--example, else the package's own
fn built_exe(b: &mut Build, o: &Opts) -> Exe {
    let plans = plans(b, o);
    let exe = if !o.examples.is_empty() || !o.bins.is_empty() {
        let mut picked = o.clone();
        picked.bins.retain(|n| !plans.values().any(|p| p.exes.iter().any(|(x, _)| x == n)));
        let mut v = select(&b, &picked, &[]);
        // a build file's executable, by name
        for n in o.bins.iter().filter(|n| !picked.bins.contains(n)) {
            let (&r, plan) = plans.iter().find(|(_, p)| p.exes.iter().any(|(x, _)| x == n)).unwrap();
            v.extend(b.install_exes(r, plan).into_iter().filter(|e| e.name == *n));
        }
        v.remove(0)
    } else {
        // the package's own executable ([[bin]] or src/), not tools from its build files
        let mut own = select(&b, o, &[Kind::Bin]);
        if own.len() > 1 {
            let wanted: Vec<&String> = b.roots.iter().filter_map(|r| b.g.pkgs[*r].m.default_run.as_ref()).collect();
            own.retain(|e| wanted.contains(&&e.name));
        }
        match own.len() {
            1 => own.remove(0),
            0 if select(&b, o, &[Kind::Bin]).is_empty() => fail("no executable to run ([[bin]] or src/)"),
            _ => {
                let names: Vec<String> = select(&b, o, &[Kind::Bin]).iter().map(|e| e.name.clone()).collect();
                fail(format!("several executables ({}); pick one with --bin NAME, or set default-run", names.join(", ")))
            }
        }
    };
    b.executables(std::slice::from_ref(&exe), &plans).or_fail();
    exe
}

fn test_cmd(o: &Opts, bench: bool) {
    let start = Instant::now();
    let kind = if bench { Kind::Bench } else { Kind::Test };
    let mut b = Build::new(o, if bench { "bench" } else { "test" }, true);
    let mut exes = select(&b, o, &[kind]);
    if let Some(f) = o.words.first() {
        exes.retain(|e| e.name.contains(f.as_str()));
    }
    // the selected packages' test blocks, unless particular targets were asked for
    if !bench && !picked(o) && o.tests.is_empty() {
        exes.extend(b.roots.iter().flat_map(|&r| b.units_of(r)));
    }
    b.executables(&exes, &HashMap::new()).or_fail();
    b.finished(start);
    if !o.no_run && !b.run_tests(&exes, bench, o.words.first().map(String::as_str)) {
        exit(1);
    }
}

fn clean_cmd(o: &Opts) {
    let ws = manifest::workspace(o.manifest_path.as_deref()).or_fail();
    let target = o.target_dir.clone().unwrap_or_else(|| ws.root.join("target"));
    let dir = match (&o.profile, o.release) {
        (Some(p), _) => target.join(manifest::profile(&ws.profiles, p).or_fail().dir),
        (None, true) => target.join("release"),
        (None, false) => target,
    };
    if dir.exists() {
        std::fs::remove_dir_all(&dir).unwrap_or_else(|e| fail(format!("can't remove {}: {e}", dir.display())));
        status("Removed", dir.display());
    }
}

fn main() {
    // plumbing voltc runs for `use LANG { ... }`: its own arguments
    let args: Vec<String> = std::env::args().skip(1).collect();
    // the voltc bolt runs finds this bolt for `use LANG { ... }`
    if std::env::var_os("BOLT").is_none() {
        if let Ok(me) = std::env::current_exe() {
            // SAFETY: nothing else runs yet (no other threads read the environment)
            unsafe { std::env::set_var("BOLT", me) };
        }
    }
    if args.first().is_some_and(|a| a == "import") {
        exit(import::main(&args[1..]));
    }
    let o = parse(args);
    match o.cmd.as_str() {
        "help" => print!("{USAGE}"),
        "" => {
            eprint!("{USAGE}");
            exit(2);
        }
        "version" => println!("bolt {}", env!("CARGO_PKG_VERSION")),
        "new" => commands::new_package(&o, false),
        "init" => commands::new_package(&o, true),
        "build" | "b" => build_cmd(&o),
        "check" | "c" => check_cmd(&o),
        "run" | "r" => run_cmd(&o),
        "hot" => hot_cmd(&o),
        "test" | "t" => test_cmd(&o, false),
        "bench" => test_cmd(&o, true),
        "clean" => clean_cmd(&o),
        "add" => commands::add(&o),
        "remove" | "rm" => commands::remove(&o),
        "update" => commands::update(&o),
        "fetch" => commands::fetch(&o),
        "tree" => commands::tree(&o),
        "metadata" => commands::metadata(&o),
        "install" => commands::install(&o),
        "uninstall" => commands::uninstall(&o),
        other => fail(format!("no command '{other}' (see bolt help)")),
    }
}
