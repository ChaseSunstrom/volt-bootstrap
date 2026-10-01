// bolt's live line on a terminal: what is compiling right now and for how long, redrawn under the
// status lines (Cargo's "Building" line), so a long compile shows it's alive. Off when stderr isn't
// a terminal, with -q, and for TERM=dumb; then output is exactly the status lines.
use std::io::{IsTerminal, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

struct State {
    running: Vec<(u64, String, Instant)>,
    next: u64,
    drawn: bool,
}

static STATE: Mutex<State> = Mutex::new(State { running: Vec::new(), next: 0, drawn: false });
static TICKER: OnceLock<()> = OnceLock::new();

pub fn enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| !crate::ui().quiet && std::io::stderr().is_terminal() && std::env::var("TERM").map_or(true, |t| t != "dumb"))
}

/// a unit that is compiling, until it's dropped
pub struct Running(u64);

/// shows `what` on the live line while the returned guard lives (None when the line is off)
pub fn start(what: &str) -> Option<Running> {
    if !enabled() {
        return None;
    }
    TICKER.get_or_init(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_millis(250));
            redraw();
        });
    });
    let mut s = STATE.lock().unwrap();
    s.next += 1;
    let id = s.next;
    s.running.push((id, what.to_string(), Instant::now()));
    Some(Running(id))
}

impl Drop for Running {
    fn drop(&mut self) {
        let mut s = STATE.lock().unwrap();
        s.running.retain(|r| r.0 != self.0);
        if s.running.is_empty() {
            clear(&mut s);
        }
    }
}

/// prints text (whole lines) above the live line, which the ticker draws again
pub fn above(text: &str) {
    let mut s = STATE.lock().unwrap();
    clear(&mut s);
    let mut err = std::io::stderr().lock();
    let _ = err.write_all(text.as_bytes());
    let _ = err.flush();
}

fn clear(s: &mut State) {
    if s.drawn {
        eprint!("\r\x1b[2K");
        s.drawn = false;
    }
}

fn redraw() {
    let mut s = STATE.lock().unwrap();
    if s.running.is_empty() {
        clear(&mut s);
        return;
    }
    let now = Instant::now();
    let running: Vec<(String, Duration)> = s.running.iter().map(|(_, w, t)| (w.clone(), now - *t)).collect();
    let width = std::env::var("COLUMNS").ok().and_then(|c| c.parse().ok()).unwrap_or(80);
    let text = line(&running, width);
    let label = crate::paint(&format!("{:>12}", "Building"), 36);
    let mut err = std::io::stderr().lock();
    let _ = write!(err, "\r\x1b[2K{label}{}", &text[12..]);
    let _ = err.flush();
    s.drawn = true;
}

/// the live line, plain: `    Building voltc v0.1.0 (bin "voltc"), std (12s)`, cut to fit `width`
/// columns; the time is the longest-running unit's
pub fn line(running: &[(String, Duration)], width: usize) -> String {
    let secs = running.iter().map(|r| r.1).max().unwrap_or_default().as_secs();
    let time = format!(" ({secs}s)");
    let names = running.iter().map(|r| r.0.as_str()).collect::<Vec<_>>().join(", ");
    let room = width.saturating_sub(13 + time.chars().count()).max(10);
    let names = if names.chars().count() > room { names.chars().take(room - 1).collect::<String>() + "…" } else { names };
    format!("{:>12} {names}{time}", "Building")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_line() {
        let r = vec![("voltc v0.1.0 (bin \"voltc\")".to_string(), Duration::from_secs(45)), ("std".to_string(), Duration::from_secs(3))];
        assert_eq!(line(&r, 80), "    Building voltc v0.1.0 (bin \"voltc\"), std (45s)");
        let cut = line(&r, 30);
        assert!(cut.ends_with("… (45s)") && cut.chars().count() <= 30, "{cut}");
    }
}
