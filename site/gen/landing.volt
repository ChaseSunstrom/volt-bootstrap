// The landing page: site/theme/landing.html (cut from the Astro page it replaces, a std::html
// template) with what changes filled in: the code samples from site/src/samples and their `// expect:` output, what voltc writes
// for the hero program, and the benchmark chart from the table in internals/benchmarks.md.
use std::fmt;
use std::html;
use std::json;

// the colours Shiki gives the dark theme's tokens, by colour class (code.volt)
val SHIKI: str[8] = { "#E6E1FF", "#C4B5FF", "#9FB8FF", "#FFFFFF", "#F5B38A", "#7FD8C9", "#7D76A8", "#E6E1FF" };

struct sample {
    code: std::string;
    output: std::vec<std::string>;
}

// a sample program: its code without the expect lines, and those lines' text
fn read_sample(path: str) -> !sample {
    val src = try std::fs::read_file(path);
    var s: sample = { code: {}, output: {} };
    var first = true;
    for (l&) in src.as_str().trim_end().lines().items() {
        val e = l.strip_prefix("// expect:");
        if (e) {
            s.output.push(std::string::from(e.trim()));
            continue;
        }
        if (!first) {
            s.code.push('\n');
        }
        s.code.append(*l);
        first = false;
    }
    val trimmed = std::string::from(s.code.as_str().trim_end());
    s.code = move trimmed;
    return s;
}

fn landing(site: str, out: str, th: theme&) -> !std::string {
    val dir = std::format("{}/src/samples", site);
    val hero = try read_sample(std::format("{}/hero.volt", dir.as_str()).as_str());
    val names: str[5] = { "errors", "ownership", "templates", "comptime", "interop" };
    var tabs: std::vec<sample> = {};
    for (n) in names {
        tabs.push(try read_sample(std::format("{}/{}.volt", dir.as_str(), n).as_str()));
    }
    val hero_c = try std::fs::read_file(std::format("{}/hero.c.txt", dir.as_str()).as_str());
    val hero_ll = try std::fs::read_file(std::format("{}/hero.ll.txt", dir.as_str()).as_str());
    val bench_md = try std::fs::read_file(std::format("{}/src/content/docs/internals/benchmarks.md", site).as_str());

    var d = std::json::object();
    d.set("code0", shiki_value(th, "volt", hero.code.as_str()));
    d.set("code1", shiki_value(th, "c", hero_c.as_str().trim_end()));
    d.set("code2", shiki_value(th, "llvm", hero_ll.as_str().trim_end()));
    var hero_out: std::string = {};
    for (o&, i) in hero.output.items() {
        if (i > 0) {
            hero_out.push('\n');
        }
        hero_out.append(o.as_str());
    }
    d.set("hero_out", std::json::string(hero_out.as_str()));
    // the tabs: code3.. and their output lines out0..
    for (t&, k) in tabs.items() {
        d.set(std::format("code{}", k + 3).as_str(), shiki_value(th, "volt", t.code.as_str()));
        var lines = std::json::array();
        for (o&, i) in t.output.items() {
            var x = std::json::object();
            x.set("i", std::json::number(@cast<f64>(i)));
            x.set("text", std::json::string(o.as_str()));
            lines.add(move x);
        }
        d.set(std::format("out{}", k).as_str(), move lines);
    }
    d.set("bench_c", std::json::string(pct(1.0).as_str()));
    d.set("bench", bench_rows(bench_md.as_str()));
    var html: std::string = {};
    fill(&th.landing, &d, &html);
    try std::fs::write_file(std::format("{}/index.html", out).as_str(), html.as_str());
    return html;
}

// code as Shiki's own renderer writes it (Astro's Code, site/theme/shiki.html), as a template's
// value: one span per run of a colour, whitespace joined to the run after it
fn shiki_value(th: theme&, lang: str, code: str) -> std::json::value {
    var ls = std::json::array();
    var c: carry = {};
    for (l&, n) in code.lines().items() {
        var colors: std::vec<u8> = {};
        for (i) in 0..l.len {
            colors.push(FG);
        }
        if (lang == "volt") {
            volt_line(*l, &c, &colors);
        } else {
            other_line(lang, *l, &c, &colors);
        }
        var runs = std::json::array();
        var i: usize = 0;
        while (i < l.len) {
            var j = i;
            while (j < l.len && *colors.at(j) == *colors.at(i)) {
                j += 1;
            }
            // a run of only spaces goes with the next run (or the one before, at the end)
            var color = *colors.at(i);
            if (blank_run((*l)[i..j]) && j < l.len) {
                color = *colors.at(j);
                var k = j;
                while (k < l.len && *colors.at(k) == color) {
                    k += 1;
                }
                j = k;
            }
            var r = std::json::object();
            r.set("color", std::json::string(SHIKI[color]));
            r.set("text", std::json::string(untab((*l)[i..j]).as_str()));
            runs.add(move r);
            i = j;
        }
        var x = std::json::object();
        x.set("nl", std::json::boolean(n > 0));
        x.set("runs", move runs);
        ls.add(move x);
    }
    var d = std::json::object();
    d.set("lang", std::json::string(lang));
    d.set("lines", move ls);
    var h: std::string = {};
    fill(&th.shiki, &d, &h);
    return std::json::string(h.as_str());
}

fn blank_run(s: str) -> bool {
    for (i) in 0..s.len {
        if (s[i] != ' ' && s[i] != '\t') {
            return false;
        }
    }
    return true;
}

// a ratio's bar width: 0x to 1.4x of C's time across the chart, as JavaScript prints the number
fn pct(r: f64) -> std::string {
    var x = r;
    if (x > 1.4) {
        x = 1.4;
    }
    return std::format("{}%", x / 1.4 * 100.0);
}

// the chart's rows: each program's Volt times as a fraction of C's, from the benchmark table's
// Volt (C, clang) and Volt (LLVM) columns, found by their headings
fn bench_rows(md: str) -> std::json::value {
    var rows = std::json::array();
    val (_, after) = md.split_once("<!-- bench:start -->") ?? return rows;
    val (table, _) = after.split_once("<!-- bench:end -->") ?? return rows;
    var c_col: usize = 0;
    var llvm_col: usize = 0;
    for (l&) in table.lines().items() {
        if (l.starts_with("| Program")) {
            for (h&, i) in l.split("|").items() {
                if (h.trim() == "Volt (C, clang)") {
                    c_col = i;
                }
                if (h.trim() == "Volt (LLVM)") {
                    llvm_col = i;
                }
            }
            continue;
        }
        // | name | ...: a program's row (lower case, as the header's isn't)
        if (!l.starts_with("| ") || !((*l)[2] >= 'a' && (*l)[2] <= 'z')) {
            continue;
        }
        val cells = l.split("|");
        if (c_col == 0 || llvm_col == 0 || cells.len <= c_col || cells.len <= llvm_col) {
            continue;
        }
        val name = cells.at(1).trim();
        var bars = std::json::array();
        bars.add(bar(ratio(*cells.at(c_col))));
        bars.add(bar(ratio(*cells.at(llvm_col))));
        var row = std::json::object();
        row.set("name", std::json::string(name));
        row.set("bars", move bars);
        rows.add(move row);
    }
    return rows;
}

// the number in a cell's "(0.51x)"
fn ratio(cell: str) -> f64 {
    val (_, after) = cell.split_once("(") ?? return 1.0;
    val (num, _) = after.split_once("x)") ?? return 1.0;
    return num.parse_float() catch 1.0;
}

// a bar: its width, whether Volt beat C, and the ratio shown
fn bar(r: f64) -> std::json::value {
    var b = std::json::object();
    b.set("w", std::json::string(pct(r).as_str()));
    b.set("faster", std::json::boolean(r < 0.97));
    b.set("r", std::json::string(std::format("{:.2}", r).as_str()));
    return b;
}
