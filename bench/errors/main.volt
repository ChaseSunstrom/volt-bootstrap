// errors: lines of comma-separated numbers, about 1 in 100 malformed, parsed through three layers of
// calls (parse_list -> parse_number -> parse_digits), many rounds; the caller counts the lines that
// fail and sums the rest. Volt returns an error union, passed up by try and handled by catch
use std::io;
use std::text;

error parse_error { EMPTY, BAD_DIGIT }

struct parser {
    text: str;
    pos: usize = 0;
}

// the digits up to the next ',' or '\n'
attach fn parse_digits(this: parser&) -> parse_error!i64 {
    val start = this.pos;
    var v: i64 = 0;
    while (this.pos < this.text.len) {
        val c = this.text[this.pos];
        if (c == ',' || c == '\n') {
            break;
        }
        if (c < '0' || c > '9') {
            return .BAD_DIGIT;
        }
        v = v * 10 + (c - '0') as i64;
        this.pos += 1;
    }
    if (this.pos == start) {
        return .EMPTY;
    }
    return v;
}

attach fn parse_number(this: parser&) -> parse_error!i64 {
    if (this.pos < this.text.len && this.text[this.pos] == '-') {
        this.pos += 1;
        return -(try this.parse_digits());
    }
    return this.parse_digits();
}

// one line's numbers: their sum
attach fn parse_list(this: parser&) -> parse_error!i64 {
    var sum: i64 = 0;
    loop {
        sum += try this.parse_number();
        if (this.pos >= this.text.len || this.text[this.pos] == '\n') {
            break;
        }
        this.pos += 1;
    }
    this.pos += 1;
    return sum;
}

attach fn skip_line(this: parser&) -> void {
    while (this.pos < this.text.len && this.text[this.pos] != '\n') {
        this.pos += 1;
    }
    this.pos += 1;
}

var rng: u64 = 88172645463325252;

fn next() -> u64 {
    rng = rng ^ (rng << 13);
    rng = rng ^ (rng >> 7);
    rng = rng ^ (rng << 17);
    return rng;
}

fn main() -> void {
    val rounds = (std::process::arg(1) ?? "1000").parse_int() catch 1000;
    val lines = 20000;
    var text = std::string::from("");
    for (i) in 0..lines {
        val count = 1 + next() % 10;
        for (k) in 0..count {
            if (k > 0) {
                text.push(',');
            }
            val r = next() % 200;
            if (r == 0) {
                continue; // an empty field
            }
            if (r % 4 == 2) {
                text.push('-');
            }
            text.append_uint(next() % 1000000);
            if (r == 1) {
                text.push('x'); // a stray letter
            }
        }
        text.push('\n');
    }
    var total: i64 = 0;
    var failures = 0;
    for (round) in 0..rounds {
        var p: parser = { text: text.as_str() };
        while (p.pos < p.text.len) {
            total += p.parse_list() catch {
                failures += 1;
                p.skip_line();
                continue;
            };
        }
    }
    std::println("{} bytes, {} total, {} failures", text.len(), total, failures);
}
