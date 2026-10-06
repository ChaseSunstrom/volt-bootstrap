// The landing page: site/theme/landing.html (cut from the Astro page it replaces) with what changes
// filled in: the code samples from site/src/samples and their `// expect:` output, what voltc writes
// for the hero program, and the benchmark chart from the table in internals/benchmarks.md.
use std::fmt;

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

fn landing(site: str, out: str) -> !std::string {
    val tmpl = try std::fs::read_file(std::format("{}/theme/landing.html", site).as_str());
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

    var html: std::string = {};
    var rest = tmpl.as_str();
    loop {
        val (before, after) = rest.split_once("{{") ?? break;
        val (slot, more) = after.split_once("}}") ?? break;
        html.append(before);
        if (slot == "code0") {
            shiki("volt", hero.code.as_str(), &html);
        } else if (slot == "code1") {
            shiki("c", hero_c.as_str().trim_end(), &html);
        } else if (slot == "code2") {
            shiki("llvm", hero_ll.as_str().trim_end(), &html);
        } else if (slot.starts_with("code")) {
            val k = @cast<usize>(slot[4..slot.len].parse_int() catch 3) - 3;
            shiki("volt", tabs.at(k).code.as_str(), &html);
        } else if (slot == "hero_out") {
            for (o&, i) in hero.output.items() {
                if (i > 0) {
                    html.push('\n');
                }
                escape(o.as_str(), &html);
            }
        } else if (slot.starts_with("out")) {
            val k = @cast<usize>(slot[3..slot.len].parse_int() catch 0);
            for (o&, i) in tabs.at(k).output.items() {
                std::write(&html, "<span style=\"--i:{}\">", i);
                escape(o.as_str(), &html);
                html.append("\n</span>");
            }
        } else if (slot == "bench_c") {
            pct(1.0, &html);
        } else if (slot == "bench_rows") {
            bench_rows(bench_md.as_str(), &html);
        }
        rest = more;
    }
    html.append(rest);
    try std::fs::write_file(std::format("{}/index.html", out).as_str(), html.as_str());
    return html;
}

// code as Shiki's own renderer writes it (Astro's Code): one span per run of a colour, whitespace
// joined to the run after it
fn shiki(lang: str, code: str, out: std::string&) -> void {
    std::write(out, "<pre class=\"astro-code volt-night\" style=\"background-color:#110d29;color:#e6e1ff; overflow-x: auto;\" tabindex=\"0\" data-language=\"{}\"><code>", lang);
    var c: carry = {};
    for (l&, n) in code.lines().items() {
        if (n > 0) {
            out.push('\n');
        }
        var colors: std::vec<u8> = {};
        for (i) in 0..l.len {
            colors.push(FG);
        }
        if (lang == "volt") {
            volt_line(*l, &c, &colors);
        } else {
            other_line(lang, *l, &c, &colors);
        }
        out.append("<span class=\"line\">");
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
            std::write(out, "<span style=\"color:{}\">", SHIKI[color]);
            code_text((*l)[i..j], true, out);
            out.append("</span>");
            i = j;
        }
        out.append("</span>");
    }
    out.append("</code></pre>");
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
fn pct(r: f64, out: std::string&) -> void {
    var x = r;
    if (x > 1.4) {
        x = 1.4;
    }
    std::write(out, "{}%", x / 1.4 * 100.0);
}

// the chart's rows: each program's Volt times as a fraction of C's, from the benchmark table's
// Volt (C, clang) and Volt (LLVM) columns, found by their headings
fn bench_rows(md: str, out: std::string&) -> void {
    val (_, after) = md.split_once("<!-- bench:start -->") ?? return;
    val (table, _) = after.split_once("<!-- bench:end -->") ?? return;
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
        std::write(out, "<div class=\"chart-row\" role=\"row\"><span class=\"prog\" role=\"rowheader\">{}</span>", name);
        bar(ratio(*cells.at(c_col)), out);
        bar(ratio(*cells.at(llvm_col)), out);
        out.append("</div>");
    }
}

// the number in a cell's "(0.51x)"
fn ratio(cell: str) -> f64 {
    val (_, after) = cell.split_once("(") ?? return 1.0;
    val (num, _) = after.split_once("x)") ?? return 1.0;
    return num.parse_float() catch 1.0;
}

fn bar(r: f64, out: std::string&) -> void {
    out.append("<span class=\"bar-cell\" role=\"cell\"><span class=\"track\"><span class=\"bar\" style=\"--w:");
    pct(r, out);
    out.push('"');
    if (r < 0.97) {
        out.append(" data-faster");
    }
    std::write(out, "></span></span><span class=\"num\">{:.2}×</span></span>", r);
}
