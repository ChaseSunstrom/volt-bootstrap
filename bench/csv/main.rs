// csv: format n records (an int, a float with two decimals, a quoted string holding a comma) as CSV text, then parse them back field by field and sum them; Rust formats with write! into a String and parses with str::parse, a bad line giving None
use std::fmt::Write;

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

const NAMES: [&str; 8] = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"];

struct Record<'a> {
    id: i64,
    price: f64,
    name: &'a str,
}

/// one line (without its newline) as a record, or None when it isn't one
fn parse_record(line: &str) -> Option<Record<'_>> {
    let (id, rest) = line.split_once(',')?;
    let (price, rest) = rest.split_once(',')?;
    let name = rest.strip_prefix('"')?.strip_suffix('"')?;
    Some(Record { id: id.parse().ok()?, price: price.parse().ok()?, name })
}

fn main() {
    let n: u64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(3_000_000);
    let mut rng = Rng(88172645463325252);
    let mut text = String::with_capacity(1 << 16);
    for _ in 0..n {
        let id = (rng.next() % 2000000001) as i64 - 1000000000;
        let price = (rng.next() % 10000000) as f64 / 100.0;
        let (a, b) = (NAMES[(rng.next() % 8) as usize], NAMES[(rng.next() % 8) as usize]);
        writeln!(text, "{id},{price:.2},\"{a}, {b}\"").unwrap();
    }
    let (mut ids, mut cents, mut records, mut name_bytes) = (0i64, 0i64, 0u64, 0usize);
    for line in text.lines() {
        let Some(r) = parse_record(line) else {
            eprintln!("bad record {records}");
            std::process::exit(1);
        };
        ids += r.id;
        cents += (r.price * 100.0 + 0.5) as i64;
        name_bytes += r.name.len();
        records += 1;
    }
    println!("{} bytes, {records} records\n{ids} {cents} {name_bytes}", text.len());
}
