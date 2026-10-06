// The website: site/gen, built by the bootstrap compiler, makes every page (the docs under
// site/src/content/docs, a std::FILE page per file in site/src/data/std.json, the landing page and
// 404) with Starlight's structure, and refuses to finish when a link goes nowhere.
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// a fresh directory for one test
fn temp(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("volt-site-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// site/gen built once, with the C backend (what the Pages workflow does)
fn generator() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| {
        let exe = temp("gen").join("sitegen");
        let mut srcs: Vec<PathBuf> = std::fs::read_dir(Path::new(ROOT).join("site/gen")).unwrap().map(|e| e.unwrap().path()).collect();
        srcs.sort();
        let b = Command::new(env!("CARGO_BIN_EXE_voltc-bootstrap")).arg("build").args(&srcs).arg("--std").arg(Path::new(ROOT).join("std")).arg("-o").arg(&exe).output().unwrap();
        assert!(b.status.success(), "building site/gen failed:\n{}", String::from_utf8_lossy(&b.stderr));
        exe
    })
}

fn generate(site: &Path, out: &Path) -> Output {
    Command::new(generator()).arg(site).arg(out).output().unwrap()
}

/// the .md files under dir, as paths relative to base without the extension
fn docs(base: &Path, dir: &Path, out: &mut Vec<String>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            docs(base, &p, out);
        } else if p.extension().is_some_and(|x| x == "md") {
            out.push(p.strip_prefix(base).unwrap().with_extension("").to_string_lossy().into_owned());
        }
    }
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let p = e.unwrap().path();
        let dest = to.join(p.file_name().unwrap());
        if p.is_dir() {
            copy_dir(&p, &dest);
        } else {
            std::fs::copy(&p, &dest).unwrap();
        }
    }
}

#[test]
fn every_page_with_starlights_structure() {
    let out = temp("dist");
    let r = generate(&Path::new(ROOT).join("site"), &out);
    assert!(r.status.success(), "the generator failed:\n{}", String::from_utf8_lossy(&r.stderr));

    let mut pages = Vec::new();
    let base = Path::new(ROOT).join("site/src/content/docs");
    docs(&base, &base, &mut pages);
    let std_json = std::fs::read_to_string(Path::new(ROOT).join("site/src/data/std.json")).unwrap();
    let mut files: Vec<&str> = std_json.split("\"file\":\"").skip(1).map(|s| s.split(".volt\"").next().unwrap()).collect();
    files.sort();
    files.dedup();
    assert!(files.len() > 20, "std.json lists {} files", files.len());
    pages.extend(files.iter().map(|f| format!("std/{f}")));

    for page in &pages {
        let path = out.join(page).join("index.html");
        let html = std::fs::read_to_string(&path).unwrap_or_else(|_| panic!("no page for {page}"));
        // header with search and theme, sidebar with this page current, table of contents, footer
        for part in ["<header class=\"header", "<site-search", "<starlight-theme-select", "id=\"starlight__sidebar\"", "aria-current=\"page\"", "<starlight-toc", "<mobile-starlight-toc", "pagination-links", "/volt-bootstrap/search.js"] {
            assert!(html.contains(part), "{page}: no {part}");
        }
        // code goes in Expressive Code frames, each with its copy button
        if html.contains("<pre") {
            assert_eq!(html.matches("<div class=\"expressive-code").count(), html.matches("data-code=").count(), "{page}: a code frame without its copy button");
        }
    }
    for file in ["index.html", "404.html", "search.json", "sitemap-index.xml", "sitemap-0.xml", "favicon.svg", "search.js", "theme.css", "landing.css", "current.js"] {
        assert!(out.join(file).is_file(), "no {file}");
    }
    // the sitemap and the search index list every page
    let sitemap = std::fs::read_to_string(out.join("sitemap-0.xml")).unwrap();
    let search = std::fs::read_to_string(out.join("search.json")).unwrap();
    for page in &pages {
        assert!(sitemap.contains(&format!("/volt-bootstrap/{page}/</loc>")), "{page} isn't in the sitemap");
        assert!(search.contains(&format!("\"/volt-bootstrap/{page}/\"")), "{page} isn't in the search index");
    }
}

#[test]
fn broken_links_fail_the_build() {
    let dir = temp("broken");
    let site = dir.join("site");
    copy_dir(&Path::new(ROOT).join("site/theme"), &site.join("theme"));
    copy_dir(&Path::new(ROOT).join("site/src"), &site.join("src"));
    let page = site.join("src/content/docs/guide/basics.md");
    let mut md = std::fs::read_to_string(&page).unwrap();
    md.push_str("\n[a](/volt-bootstrap/guide/nope/) [b](/volt-bootstrap/guide/basics/#nope) [c](#nope) [d](/elsewhere/) [e](/volt-bootstrap/stale.css) [f](/volt-bootstrap/guide/basics/#variables) [g](/volt-bootstrap/theme.css)\n");
    std::fs::write(&page, md).unwrap();
    // a file an earlier build left in the output directory doesn't count
    std::fs::create_dir_all(dir.join("dist")).unwrap();
    std::fs::write(dir.join("dist/stale.css"), "").unwrap();
    let r = generate(&site, &dir.join("dist"));
    let err = String::from_utf8_lossy(&r.stderr);
    assert!(!r.status.success(), "a broken link passed:\n{err}");
    for link in ["/volt-bootstrap/guide/nope/", "/volt-bootstrap/guide/basics/#nope", "#nope", "/elsewhere/", "/volt-bootstrap/stale.css"] {
        assert!(err.contains(&format!("/guide/basics: broken link {link}\n")), "{link} wasn't reported:\n{err}");
    }
    assert!(err.contains("5 broken link(s)"), "{err}");
}

/// the landing page's chart shows each program's Volt (C, clang) and Volt (LLVM) ratios from the
/// benchmarks table, whatever columns the table has
#[test]
fn landing_chart_shows_the_volt_columns() {
    let out = temp("chart");
    let r = generate(&Path::new(ROOT).join("site"), &out);
    assert!(r.status.success(), "the generator failed:\n{}", String::from_utf8_lossy(&r.stderr));
    let html = std::fs::read_to_string(out.join("index.html")).unwrap();
    let md = std::fs::read_to_string(Path::new(ROOT).join("site/src/content/docs/internals/benchmarks.md")).unwrap();
    let measured = md.split("<!-- bench:start -->").nth(1).and_then(|s| s.split("<!-- bench:end -->").next()).expect("the measured table");
    let table: Vec<&str> = measured.lines().filter(|l| l.starts_with("| ")).collect();
    let head: Vec<&str> = table[0].split('|').map(str::trim).collect();
    let col = |name: &str| head.iter().position(|h| *h == name).unwrap_or_else(|| panic!("no {name} column"));
    let (c, llvm) = (col("Volt (C, clang)"), col("Volt (LLVM)"));
    let ratio = |cell: &str| cell.split('(').nth(1).and_then(|s| s.split("x)").next()).unwrap_or("").to_string();
    let mut rows = 0;
    for row in table.iter().filter(|l| l.as_bytes()[2].is_ascii_lowercase()) {
        let cells: Vec<&str> = row.split('|').map(str::trim).collect();
        let at = html.find(&format!("role=\"rowheader\">{}</span>", cells[1])).unwrap_or_else(|| panic!("no chart row for {}", cells[1]));
        let shown: Vec<&str> = html[at..].split("<span class=\"num\">").skip(1).take(2).map(|s| s.split('×').next().unwrap()).collect();
        assert_eq!(shown, [ratio(cells[c]), ratio(cells[llvm])], "{}'s bars", cells[1]);
        rows += 1;
    }
    assert!(rows > 20, "only {rows} rows");
}

/// the landing page's "Code that writes code" section links every example on the metaprogramming
/// page (the generator fails on a link to an anchor that isn't there)
#[test]
fn landing_links_each_metaprogramming_example() {
    let out = temp("meta");
    let r = generate(&Path::new(ROOT).join("site"), &out);
    assert!(r.status.success(), "the generator failed:\n{}", String::from_utf8_lossy(&r.stderr));
    let html = std::fs::read_to_string(out.join("index.html")).unwrap();
    let md = std::fs::read_to_string(Path::new(ROOT).join("site/src/content/docs/guide/metaprogramming.md")).unwrap();
    let headings: Vec<&str> = md.lines().filter_map(|l| l.strip_prefix("## ")).collect();
    assert!(headings.len() >= 6, "only {} examples", headings.len());
    for h in headings {
        // slug() for a heading of letters, digits and spaces (the page's are)
        let anchor = h.to_lowercase().replace(' ', "-");
        assert!(html.contains(&format!("href=\"/volt-bootstrap/guide/metaprogramming/#{anchor}\"")), "the landing page doesn't link {h}");
    }
}
