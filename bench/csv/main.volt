// csv: format n records (an int, a float with two decimals, a quoted string holding a comma) as CSV
// text, then parse them back field by field and sum them; Volt formats with std::write into a
// std::string and parses with lines, split_once, parse_int and parse_float, failing through an
// error union
use std::io;
use std::text;
use std::fmt;

var x: u64 = 88172645463325252;

fn next() -> u64 {
    x = x ^ (x << 13);
    x = x ^ (x >> 7);
    x = x ^ (x << 17);
    return x;
}

val NAMES: str[8] = { "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel" };

error csv_error { BAD_RECORD }

struct record {
    id: i64;
    price: f64;
    name: str;
}

// one line's fields: id,price,"name"
fn parse_record(line: str) -> !record {
    val (id, rest) = line.split_once(",") ?? return csv_error::BAD_RECORD;
    val (price, quoted) = rest.split_once(",") ?? return csv_error::BAD_RECORD;
    val name = (quoted.strip_prefix("\"") ?? return csv_error::BAD_RECORD).strip_suffix("\"") ?? return csv_error::BAD_RECORD;
    return { id: try id.parse_int(), price: try price.parse_float(), name: name };
}

fn main() -> !void {
    val n = (std::process::arg(1) ?? "3000000").parse_int() catch 3000000;
    var text: std::string = {};
    for (i) in 0..n {
        val id = @cast<i64>(next() % 2000000001) - 1000000000;
        val price = @cast<f64>(next() % 10000000) / 100.0;
        val a = NAMES[next() % 8];
        val b = NAMES[next() % 8];
        std::write(&text, "{},{:.2},\"{}, {}\"\n", id, price, a, b);
    }
    var ids: i64 = 0;
    var cents: i64 = 0;
    var name_bytes: usize = 0;
    val lines = text.as_str().lines();
    for (line) in lines.items() {
        val r = try parse_record(line);
        ids += r.id;
        cents += @cast<i64>(r.price * 100.0 + 0.5);
        name_bytes += r.name.len;
    }
    std::println("{} bytes, {} records", text.len(), lines.len);
    std::println("{} {} {}", ids, cents, name_bytes);
}
