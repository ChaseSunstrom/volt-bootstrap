// errors: lines of comma-separated numbers, about 1 in 100 malformed, parsed through three layers of calls; Rust returns a Result and passes errors up with ?
use std::io::Write;

#[derive(Debug)]
enum ParseError {
    Empty,
    BadDigit,
}

struct Parser<'a> {
    text: &'a [u8],
    pos: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.get(self.pos).copied()
    }

    /// the digits up to the next ',' or '\n'
    fn parse_digits(&mut self) -> Result<i64, ParseError> {
        let start = self.pos;
        let mut v = 0i64;
        while let Some(c) = self.peek() {
            if c == b',' || c == b'\n' {
                break;
            }
            if !c.is_ascii_digit() {
                return Err(ParseError::BadDigit);
            }
            v = v * 10 + (c - b'0') as i64;
            self.pos += 1;
        }
        if self.pos == start {
            return Err(ParseError::Empty);
        }
        Ok(v)
    }

    fn parse_number(&mut self) -> Result<i64, ParseError> {
        if self.peek() == Some(b'-') {
            self.pos += 1;
            return Ok(-self.parse_digits()?);
        }
        self.parse_digits()
    }

    /// one line's numbers: their sum
    fn parse_list(&mut self) -> Result<i64, ParseError> {
        let mut sum = 0;
        loop {
            sum += self.parse_number()?;
            match self.peek() {
                None | Some(b'\n') => break,
                _ => self.pos += 1,
            }
        }
        self.pos += 1;
        Ok(sum)
    }

    fn skip_line(&mut self) {
        while self.peek().is_some_and(|c| c != b'\n') {
            self.pos += 1;
        }
        self.pos += 1;
    }
}

fn main() {
    let rounds: i64 = std::env::args().nth(1).and_then(|a| a.parse().ok()).unwrap_or(1000);
    let lines = 20000;
    let mut rng: u64 = 88172645463325252;
    let mut next = move || {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        rng
    };
    // at most 10 fields a line, each at most "-999999x,"
    let mut text: Vec<u8> = Vec::with_capacity(lines * 91);
    for _ in 0..lines {
        let count = 1 + next() % 10;
        for k in 0..count {
            if k > 0 {
                text.push(b',');
            }
            let r = next() % 200;
            if r == 0 {
                continue; // an empty field
            }
            if r % 4 == 2 {
                text.push(b'-');
            }
            write!(text, "{}", next() % 1000000).unwrap();
            if r == 1 {
                text.push(b'x'); // a stray letter
            }
        }
        text.push(b'\n');
    }
    let mut total = 0i64;
    let mut failures = 0i64;
    for _ in 0..rounds {
        let mut p = Parser { text: &text, pos: 0 };
        while p.pos < text.len() {
            match p.parse_list() {
                Ok(sum) => total += sum,
                Err(_) => {
                    failures += 1;
                    p.skip_line();
                }
            }
        }
    }
    println!("{} bytes, {total} total, {failures} failures", text.len());
}
