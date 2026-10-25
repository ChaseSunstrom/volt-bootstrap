//! An ordinary Rust library: nothing in it is written for Volt. main.volt next to it calls it
//! with `use rust { "geom" } as geom;`.

pub mod shapes;

pub const LIMIT: i32 = 10;
pub const NAME: &str = "geom";

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub fn new(x: f64, y: f64) -> Point {
        Point { x, y }
    }

    pub fn norm(&self) -> f64 {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    pub fn scale(&mut self, k: f64) {
        self.x *= k;
        self.y *= k;
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Color {
    Red,
    Green = 5,
    Blue,
}

impl Color {
    pub fn name(&self) -> &'static str {
        match self {
            Color::Red => "red",
            Color::Green => "green",
            Color::Blue => "blue",
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Pixel {
    pub at: Point,
    pub color: Color,
    pub mark: char,
}

pub fn dist(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

pub fn greet(who: &str) -> String {
    format!("hello, {who}")
}

pub fn shout(s: String) -> String {
    s.to_uppercase()
}

pub fn first_word(s: &str) -> &str {
    s.split_whitespace().next().unwrap_or("")
}

pub fn sum(xs: &[f64]) -> f64 {
    xs.iter().sum()
}

pub fn double_all(xs: &mut [i32]) {
    for x in xs {
        *x *= 2;
    }
}

pub fn squares(n: u32) -> Vec<u64> {
    (1..=n as u64).map(|i| i * i).collect()
}

pub fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(String::from).collect()
}

pub fn join(parts: &[&str], sep: &str) -> String {
    parts.join(sep)
}

pub fn find(xs: &[i32], x: i32) -> Option<usize> {
    xs.iter().position(|&y| y == x)
}

pub fn nickname(id: u32) -> Option<String> {
    (id == 7).then(|| "lucky".to_string())
}

pub fn or_default(x: Option<i64>) -> i64 {
    x.unwrap_or(-1)
}

pub fn parse_num(s: &str) -> Result<i64, std::num::ParseIntError> {
    s.trim().parse()
}

pub fn checked_div(a: i32, b: i32) -> Result<i32, String> {
    if b == 0 {
        Err(format!("{a} / 0"))
    } else {
        Ok(a / b)
    }
}

pub fn next_color(c: Color) -> Color {
    match c {
        Color::Red => Color::Green,
        Color::Green => Color::Blue,
        Color::Blue => Color::Red,
    }
}

pub fn brighten(p: &mut Pixel) {
    p.color = next_color(p.color);
    p.at.scale(2.0);
}

pub fn initial(c: char) -> char {
    c.to_ascii_uppercase()
}

// not callable from Volt: generic, and a closure
pub fn largest<T: PartialOrd + Copy>(xs: &[T]) -> T {
    let mut m = xs[0];
    for &x in xs {
        if x > m {
            m = x;
        }
    }
    m
}

pub fn apply(f: impl Fn(i32) -> i32, x: i32) -> i32 {
    f(x)
}

/// a module whose name is a Volt keyword: Volt sees it as error_
pub mod error {
    #[derive(Clone, Copy, Debug)]
    pub struct Problem {
        pub code: i32,
    }

    pub fn make(code: i32) -> Problem {
        Problem { code }
    }
}

/// parameters named like the glue's own locals
pub fn clash(o: i32, e: i32, a0: i32) -> i32 {
    o * 100 + e * 10 + a0
}

/// can't be built or matched outside this crate: Volt holds it as a handle
#[non_exhaustive]
pub struct Settings {
    pub level: i32,
}

impl Settings {
    pub fn new(level: i32) -> Settings {
        Settings { level }
    }

    pub fn level(&self) -> i32 {
        self.level
    }
}

#[non_exhaustive]
#[derive(Clone, Copy, Debug)]
pub enum Mode {
    Fast,
    Slow,
}

pub fn mode_name(m: Mode) -> String {
    format!("{m:?}")
}

// what only rustdoc sees: a fn a macro makes, the branch of a #[cfg] that holds, an item re-exported
// under another name from a private module, a glob re-export, and consts rustc works out
macro_rules! constant_fn {
    ($name:ident, $v:expr) => {
        pub fn $name() -> i32 {
            $v
        }
    };
}
constant_fn!(answer, 42);

#[cfg(target_pointer_width = "64")]
pub fn word_bits() -> u32 {
    64
}
#[cfg(not(target_pointer_width = "64"))]
pub fn word_bits() -> u32 {
    32
}

mod hidden {
    pub fn twice(x: i32) -> i32 {
        x * 2
    }
    pub struct Pair {
        pub a: i32,
        pub b: i32,
    }
}
pub use hidden::twice as doubled;
pub use hidden::Pair;

pub mod extra {
    pub fn plus_one(x: i32) -> i32 {
        x + 1
    }
}
pub use extra::*;

pub fn pair_sum(p: Pair) -> i32 {
    p.a + p.b
}

pub const AREA: u32 = (LIMIT * LIMIT) as u32;
pub const RATIO: f64 = 1.0 / 4.0;
pub const BIG: bool = AREA > 50;

// generics: each instance a program calls is made for it
pub fn repeat<T: Clone>(x: T, n: usize) -> Vec<T> {
    vec![x; n]
}

pub fn pick<T>(first: bool, a: T, b: T) -> T {
    if first {
        a
    } else {
        b
    }
}

// a const parameter (a Volt value generic) and an impl Trait one (a type each call infers)
pub fn lead<const N: usize>(a: [i32; N]) -> i32 {
    a[0] * N as i32
}

pub fn show(x: impl std::fmt::Display) -> String {
    format!("<{x}>")
}

impl Point {
    pub fn scaled_by<K: Into<f64>>(&self, k: K) -> Point {
        let k = k.into();
        Point { x: self.x * k, y: self.y * k }
    }
}

pub fn dup<T: Clone>(x: &T) -> T {
    x.clone()
}

// a generic type: a Volt type per instance a program names (each impl's bounds apply to its own
// methods: Stack<Point> has no show)
pub struct Stack<T> {
    items: Vec<T>,
}

impl<T> Stack<T> {
    pub fn new() -> Stack<T> {
        Stack { items: Vec::new() }
    }
    pub fn push(&mut self, x: T) {
        self.items.push(x);
    }
    pub fn len(&self) -> usize {
        self.items.len()
    }
}

impl<T: Clone> Stack<T> {
    pub fn top(&self) -> Option<T> {
        self.items.last().cloned()
    }
}

impl<T: std::fmt::Display> Stack<T> {
    pub fn show(&self) -> String {
        self.items.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")
    }
}

pub fn bigger<T: PartialOrd + Copy>(a: &T, b: &T) -> T {
    if *a > *b {
        *a
    } else {
        *b
    }
}

// closures: Volt's passed in (impl Fn, a bound in a where clause, impl FnMut over text, a Box<dyn
// Fn>), Rust's handed out (impl Fn, Box<dyn FnMut>, impl FnOnce)
pub fn each_word(s: &str, mut f: impl FnMut(&str)) {
    for w in s.split_whitespace() {
        f(w);
    }
}

pub fn count_with<F>(xs: &[i32], f: F) -> usize
where
    F: Fn(i32) -> bool,
{
    xs.iter().filter(|x| f(**x)).count()
}

pub fn call_boxed(f: Box<dyn Fn(i32) -> i32>) -> i32 {
    f(10)
}

pub fn adder(n: i32) -> impl Fn(i32) -> i32 {
    move |x| x + n
}

pub fn counter() -> Box<dyn FnMut() -> u32> {
    let mut c = 0;
    Box::new(move || {
        c += 1;
        c
    })
}

pub fn initial_of(word: &str) -> impl FnOnce() -> char {
    let c = word.chars().next().unwrap_or('?');
    move || c
}

// text out of closures: a String a Volt closure makes, and a Rust closure taking and giving one
pub fn mark_each(words: &[&str], f: impl Fn(&str) -> String) -> String {
    words.iter().map(|w| f(w)).collect::<Vec<_>>().join(" ")
}

pub fn greeter(greeting: String) -> impl Fn(String) -> String {
    move |name| format!("{greeting}, {name}")
}

// keeps the closure it's given past the call (a Volt one is Rust's to drop)
pub fn keep_boxed(f: Box<dyn Fn(i32) -> i32>) -> impl Fn(i32) -> i32 {
    move |x| f(x) * 2
}

// traits: Rust's trait objects handed out (Box<dyn Shape>, impl Shape) as values with the trait's
// methods; Volt's types attaching Shape passed where Rust takes &dyn Shape, &mut dyn Shape, impl
// Shape, S: Shape or Box<dyn Shape> (kept by Rust, and dropped by it)
pub trait Shape {
    fn area(&self) -> f64;
    fn name(&self) -> String;
    fn label(&self) -> &str;
    fn grow(&mut self, by: f64);
    fn describe(&self) -> String {
        format!("{} of area {}", self.name(), self.area())
    }
    // a default calling another default: a Volt type's own describe is the one it sees
    fn summary(&self) -> String {
        format!("({})", self.describe())
    }
}

pub struct Circle {
    pub r: f64,
}

impl Shape for Circle {
    fn area(&self) -> f64 {
        3.0 * self.r * self.r
    }
    fn name(&self) -> String {
        "circle".into()
    }
    fn label(&self) -> &str {
        "C"
    }
    fn grow(&mut self, by: f64) {
        self.r += by;
    }
}

pub struct Square {
    side: f64,
}

impl Square {
    pub fn new(side: f64) -> Square {
        Square { side }
    }
}

// counts the squares dropped: one a Volt handle or a Rust value holds is dropped once
static SQUARES_DROPPED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

impl Drop for Square {
    fn drop(&mut self) {
        SQUARES_DROPPED.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

pub fn squares_dropped() -> usize {
    SQUARES_DROPPED.load(std::sync::atomic::Ordering::Relaxed)
}

impl Shape for Square {
    fn area(&self) -> f64 {
        self.side * self.side
    }
    fn name(&self) -> String {
        "square".into()
    }
    fn label(&self) -> &str {
        "S"
    }
    fn grow(&mut self, by: f64) {
        self.side += by;
    }
    fn describe(&self) -> String {
        format!("a square of side {}", self.side)
    }
}

pub fn area_of(s: &dyn Shape) -> f64 {
    s.area()
}

pub fn grow_twice(s: &mut dyn Shape, by: f64) {
    s.grow(by);
    s.grow(by);
}

pub fn describe_it(s: impl Shape) -> String {
    format!("{} [{}]", s.describe(), s.label())
}

pub fn summarize_it(s: &dyn Shape) -> String {
    s.summary()
}

pub fn larger<S: Shape>(a: &S, b: &S) -> f64 {
    a.area().max(b.area())
}

pub fn unit_square() -> Box<dyn Shape> {
    Box::new(Square::new(1.0))
}

pub fn circle_of(r: f64) -> impl Shape {
    Circle { r }
}

// keeps the shapes it's given (a Volt one is freed when the canvas drops it)
pub struct Canvas {
    shapes: Vec<Box<dyn Shape>>,
}

impl Canvas {
    pub fn new() -> Canvas {
        Canvas { shapes: Vec::new() }
    }
    pub fn add(&mut self, s: Box<dyn Shape>) {
        self.shapes.push(s);
    }
    pub fn total(&self) -> f64 {
        self.shapes.iter().map(|s| s.area()).sum()
    }
    pub fn names(&self) -> String {
        self.shapes.iter().map(|s| s.name()).collect::<Vec<_>>().join(",")
    }
}

// a trait with an associated type: Volt's Source<i32>, which Countdown attaches and
// Box<dyn Source<Item = i32>> is a handle of
pub trait Source {
    type Item;
    fn next_item(&mut self) -> Option<Self::Item>;
}

pub struct Countdown {
    n: i32,
}

impl Countdown {
    pub fn new(n: i32) -> Countdown {
        Countdown { n }
    }
}

impl Source for Countdown {
    type Item = i32;
    fn next_item(&mut self) -> Option<i32> {
        if self.n == 0 {
            return None;
        }
        self.n -= 1;
        Some(self.n + 1)
    }
}

pub fn countdown(n: i32) -> Box<dyn Source<Item = i32>> {
    Box::new(Countdown { n })
}

// a generic trait: Convert<f64> and Convert<String>, both attached
pub trait Convert<T> {
    fn convert(&self) -> T;
}

impl Convert<f64> for Countdown {
    fn convert(&self) -> f64 {
        self.n as f64 / 2.0
    }
}

impl Convert<String> for Countdown {
    fn convert(&self) -> String {
        format!("n={}", self.n)
    }
}

// a tuple and an array as the type argument
impl Convert<(i32, bool)> for Countdown {
    fn convert(&self) -> (i32, bool) {
        (self.n * 2, self.n > 0)
    }
}

impl Convert<[i32; 2]> for Countdown {
    fn convert(&self) -> [i32; 2] {
        [self.n, -self.n]
    }
}

// a supertrait the crate declares: its methods come with the trait
pub trait Named {
    fn name(&self) -> String;
}

pub trait Greeter: Named {
    fn greet(&self) -> String {
        format!("hello from {}", self.name())
    }
}

impl Named for Countdown {
    fn name(&self) -> String {
        "countdown".into()
    }
}

impl Greeter for Countdown {}

// a generic trait whose methods take its parameter's values (Store<i32>), one with a generic
// supertrait (Labeled: Convert<i32>), and one with a std supertrait that has methods (Shown: Display)
pub trait Store<T> {
    fn put(&mut self, v: T);
    fn take(&mut self) -> T;
}

// (its std impls: Display below, and derived Debug, PartialEq, Eq, PartialOrd, Ord and Hash)
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Bin {
    held: i32,
}

impl Bin {
    pub fn new() -> Bin {
        Bin { held: 0 }
    }
    pub fn with(n: i32) -> Bin {
        Bin { held: n }
    }
}

impl Store<i32> for Bin {
    fn put(&mut self, v: i32) {
        self.held += v;
    }
    fn take(&mut self) -> i32 {
        std::mem::take(&mut self.held)
    }
}

impl Convert<i32> for Bin {
    fn convert(&self) -> i32 {
        self.held * 100
    }
}

pub trait Labeled: Convert<i32> {
    fn label_n(&self) -> String {
        format!("#{}", self.convert())
    }
}

impl Labeled for Bin {}

impl std::fmt::Display for Bin {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "bin({})", self.held)
    }
}

pub trait Shown: std::fmt::Display {
    fn shown(&self) -> String {
        format!("<{}>", self)
    }
}

impl Shown for Bin {}

// a text instance (Store<String>): its put takes the text as Volt's str, not the trait's T, so it's
// left out there; take gives a std::string
pub struct Words {
    all: String,
}

impl Words {
    pub fn new(s: &str) -> Words {
        Words { all: s.to_string() }
    }
}

impl Store<String> for Words {
    fn put(&mut self, v: String) {
        self.all.push_str(&v);
    }
    fn take(&mut self) -> String {
        std::mem::take(&mut self.all)
    }
}

// an associated const: Countdown::CAP() (one named like an item of its module is left out)
pub trait Limited {
    const CAP: u32;
    const LIMIT: u32;
    fn used(&self) -> u32;
}

impl Limited for Countdown {
    const CAP: u32 = 10;
    const LIMIT: u32 = 3;
    fn used(&self) -> u32 {
        self.n as u32
    }
}

// tuples, fixed-size arrays and 128-bit integers
pub fn swap_pair(p: (i32, f64)) -> (f64, i32) {
    (p.1, p.0)
}

pub fn min_max(xs: &[i64]) -> (i64, i64) {
    (*xs.iter().min().unwrap_or(&0), *xs.iter().max().unwrap_or(&0))
}

pub fn label_of(n: u8) -> (String, u8) {
    (format!("#{n}"), n + 1)
}

pub fn reversed(a: [i32; 3]) -> [i32; 3] {
    [a[2], a[1], a[0]]
}

pub fn big_mul(a: u128, b: u128) -> u128 {
    a * b
}

pub fn negate(x: i128) -> i128 {
    -x
}

constant_fn!(made_by_macro, 7);

// left out without failing the import: a const of a struct type (Volt's types can't attach the
// trait); a tuple as the type argument attaches (Convert<(i32, i32)>, a dyn of Source<Item = (i32,
// i32)>) with next_item's Option of a tuple
pub trait Anchored {
    const START: Pair;
    fn anchor(&self) -> i32;
}

impl Anchored for Countdown {
    const START: Pair = Pair { a: 0, b: 0 };
    fn anchor(&self) -> i32 {
        self.n
    }
}

impl Convert<(i32, i32)> for Countdown {
    fn convert(&self) -> (i32, i32) {
        (self.n, -self.n)
    }
}

pub struct Pairs;

impl Source for Pairs {
    type Item = (i32, i32);
    fn next_item(&mut self) -> Option<(i32, i32)> {
        Some((2, 3))
    }
}

pub fn pairs() -> Box<dyn Source<Item = (i32, i32)>> {
    Box::new(Pairs)
}

// bounds a Volt value doesn't meet (Clone besides Shape, Clone besides Fn): generics rustc builds
// per instance, never a Volt trait value or closure the shim can't pass
pub fn clone_area<S: Shape>(s: &S) -> f64
where
    S: Clone,
{
    s.clone().area()
}

pub fn call_twice<F: Fn(i32) -> i32 + Clone>(f: F) -> i32 {
    let g = f.clone();
    f(1) + g(2)
}

// every self form: through a Box, an Rc or Arc (given up, or lent as &Rc<Self>), pinned
pub struct Node {
    v: i32,
}

impl Node {
    pub fn new(v: i32) -> Node {
        Node { v }
    }
    pub fn boxed_value(self: Box<Self>) -> i32 {
        self.v
    }
    pub fn rc_value(self: std::rc::Rc<Self>) -> i32 {
        self.v * 10
    }
    pub fn arc_value(self: std::sync::Arc<Self>) -> i32 {
        self.v * 100
    }
    pub fn peek_rc(self: &std::rc::Rc<Self>) -> i32 {
        self.v + std::rc::Rc::strong_count(self) as i32
    }
    pub fn bump_pinned(self: std::pin::Pin<&mut Self>) {
        self.get_mut().v += 1;
    }
    pub fn read_pinned(self: std::pin::Pin<&Self>) -> i32 {
        self.v
    }
    pub fn value(&self) -> i32 {
        self.v
    }
    pub fn set(&mut self, v: i32) {
        self.v = v;
    }
}

// references into Rust's data: lent handles (a &mut changes the tree's node), a slice of them,
// and a Vec of owned ones; plain structs and enums copied
pub struct Tree {
    nodes: Vec<Node>,
}

impl Tree {
    pub fn new(n: i32) -> Tree {
        Tree { nodes: (1..=n).map(Node::new).collect() }
    }
    pub fn first(&self) -> &Node {
        &self.nodes[0]
    }
    pub fn first_mut(&mut self) -> &mut Node {
        &mut self.nodes[0]
    }
    pub fn find(&self, v: i32) -> Option<&Node> {
        self.nodes.iter().find(|n| n.v == v)
    }
    pub fn all(&self) -> &[Node] {
        &self.nodes
    }
    pub fn into_nodes(self) -> Vec<Node> {
        self.nodes
    }
}

pub fn corners() -> Vec<Point> {
    vec![Point { x: 0.0, y: 0.0 }, Point { x: 1.0, y: 2.0 }]
}

pub fn palette() -> &'static [Color] {
    &[Color::Red, Color::Blue]
}

// a panic: try_at gives it back as rust_error::PANIC; at stops the program with its message
pub fn at(xs: &[i32], i: usize) -> i32 {
    xs[i]
}

// an error enum keeps its variants: Volt matches them (one Volt can't hold, Raw, as its text);
// Parsed<T> is the crate's alias of Result<T, ParseError>
#[derive(Debug)]
pub enum ParseError {
    Empty,
    BadDigit(char),
    TooLong { max: usize, got: usize },
    Raw(Vec<u8>),
}

pub type Parsed<T> = std::result::Result<T, ParseError>;

pub fn parse_digits(s: &str) -> Parsed<u32> {
    if s.is_empty() {
        return Err(ParseError::Empty);
    }
    if s.len() > 4 {
        return Err(ParseError::TooLong { max: 4, got: s.len() });
    }
    if s.starts_with('#') {
        return Err(ParseError::Raw(s.bytes().collect()));
    }
    let mut n = 0;
    for c in s.chars() {
        n = n * 10 + c.to_digit(10).ok_or(ParseError::BadDigit(c))?;
    }
    Ok(n)
}

// async fns: futures Volt awaits (pending once; woken by another thread; failing with an enum
// error; a method's)
struct YieldOnce(bool);

impl std::future::Future for YieldOnce {
    type Output = ();
    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        if self.0 {
            return std::task::Poll::Ready(());
        }
        self.0 = true;
        cx.waker().wake_by_ref();
        std::task::Poll::Pending
    }
}

pub async fn later(x: i32) -> i32 {
    YieldOnce(false).await;
    x + 1
}

struct FromThread(std::sync::Arc<std::sync::Mutex<(Option<i32>, Option<std::task::Waker>)>>);

impl std::future::Future for FromThread {
    type Output = i32;
    fn poll(self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<i32> {
        let mut s = self.0.lock().unwrap();
        match s.0 {
            Some(v) => std::task::Poll::Ready(v),
            None => {
                s.1 = Some(cx.waker().clone());
                std::task::Poll::Pending
            }
        }
    }
}

pub async fn from_thread(x: i32) -> i32 {
    let state = std::sync::Arc::new(std::sync::Mutex::new((None, None::<std::task::Waker>)));
    let s2 = state.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(20));
        let mut s = s2.lock().unwrap();
        s.0 = Some(x * 2);
        if let Some(w) = s.1.take() {
            w.wake();
        }
    });
    FromThread(state).await
}

pub async fn parse_later(s: &str) -> Parsed<u32> {
    YieldOnce(false).await;
    parse_digits(s)
}

impl Node {
    pub async fn value_later(&self) -> i32 {
        YieldOnce(false).await;
        self.v
    }
}

// a value lent through &Rc<Self> to a method that panics is put back, and dropped once (by its
// handle); a #[non_exhaustive] error enum with a V() variant
static COUNTED_DROPS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

pub struct Counted {
    id: i32,
}

impl Counted {
    pub fn new(id: i32) -> Counted {
        Counted { id }
    }
    pub fn peek(self: &std::rc::Rc<Self>, fail: bool) -> i32 {
        if fail {
            panic!("peek failed");
        }
        self.id
    }
}

impl Drop for Counted {
    fn drop(&mut self) {
        COUNTED_DROPS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }
}

pub fn counted_drops() -> usize {
    COUNTED_DROPS.load(std::sync::atomic::Ordering::Relaxed)
}

#[derive(Debug)]
#[non_exhaustive]
pub enum NetError {
    Timeout,
    Refused(String),
    Closed(),
}

// an error the crate describes with a struct: Volt's catch gets its fields, not only its text
#[derive(Debug)]
pub struct ParseFail {
    pub at: i32,
    pub reason: String,
}

impl std::fmt::Display for ParseFail {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "{} at {}", self.reason, self.at)
    }
}

pub fn parse_fail(s: &str) -> Result<i32, ParseFail> {
    s.parse::<i32>().map_err(|_| ParseFail { at: s.len() as i32, reason: "not a number".into() })
}

pub fn connect(code: i32) -> Result<i32, NetError> {
    match code {
        0 => Err(NetError::Timeout),
        1 => Err(NetError::Refused("busy".into())),
        2 => Err(NetError::Closed()),
        n => Ok(n),
    }
}

// closures and a trait whose signatures carry structs, enums, handles, Vec, slices, arrays and
// Option: Volt's closures, and a Volt type implementing Visit, run through them
pub struct Tally {
    total: i32,
}

impl Tally {
    pub fn new(total: i32) -> Tally {
        Tally { total }
    }

    pub fn total(&self) -> i32 {
        self.total
    }
}

pub fn map_point(p: Point, f: impl Fn(Point) -> Point) -> Point {
    f(p)
}

pub fn nudge(mut p: Point, f: &dyn Fn(&mut Point)) -> Point {
    f(&mut p);
    p
}

pub fn shift_color(c: Color, f: impl Fn(Color, &Point) -> Option<Color>) -> String {
    match f(c, &Point::new(1.0, 2.0)) {
        Some(x) => format!("{x:?}"),
        None => "none".into(),
    }
}

pub fn evens(xs: &[i32], f: impl Fn(&[i32], Option<i32>) -> Vec<i32>) -> String {
    format!("{:?} {:?}", f(xs, Some(2)), f(xs, None))
}

pub fn words_of(s: &str, f: impl Fn(Vec<String>) -> (usize, Option<String>)) -> String {
    let (n, last) = f(s.split(' ').map(String::from).collect());
    format!("{n} {last:?}")
}

pub fn spend(t: Tally, f: impl FnOnce(Tally, &Tally) -> Tally) -> i32 {
    let k = Tally::new(100);
    f(t, &k).total
}

pub fn spots(f: impl Fn(Option<Point>) -> [i32; 3]) -> String {
    format!("{:?} {:?}", f(None), f(Some(Point::new(3.0, 4.0))))
}

pub trait Visit {
    fn at(&mut self, p: Point, c: Color) -> Option<Point>;
    fn many(&self, xs: &[i32], label: Option<String>) -> Vec<String>;
    fn edit(&self, p: &mut Point);
    fn sized(&self, t: &Tally, c: Option<Color>) -> (i32, Color);
    fn made(&self) -> Tally;
    fn flags(&self) -> [bool; 2] {
        [true, false]
    }
}

pub fn run_visit(v: &mut dyn Visit) -> String {
    let at = v.at(Point::new(1.0, 2.0), Color::Blue);
    let none = v.at(Point::new(1.0, 2.0), Color::Red);
    let many = v.many(&[1, 2, 3], Some("xs".into()));
    let mut p = Point::new(5.0, 6.0);
    v.edit(&mut p);
    let t = Tally::new(7);
    let sized = (v.sized(&t, None), v.sized(&t, Some(Color::Green)));
    let made = v.made().total();
    format!("{at:?} {none:?} {many:?} {p:?} {sized:?} {made} {:?}", v.flags())
}

// maps, sets, a Box and raw pointers: a Volt std::map and std::set (copies), the boxed value
// itself, and a Volt T*
pub fn word_counts(text: &str) -> std::collections::HashMap<String, i32> {
    let mut m = std::collections::HashMap::new();
    for w in text.split(' ') {
        *m.entry(w.to_string()).or_insert(0) += 1;
    }
    m
}

pub fn total_counts(m: &std::collections::HashMap<String, i32>) -> i32 {
    m.values().sum()
}

pub fn scaled(m: std::collections::BTreeMap<i32, f64>, k: f64) -> std::collections::BTreeMap<i32, f64> {
    m.into_iter().map(|(a, b)| (a, b * k)).collect()
}

pub fn evens_of(s: &std::collections::HashSet<i32>) -> std::collections::HashSet<i32> {
    s.iter().filter(|x| *x % 2 == 0).copied().collect()
}

pub fn initials(words: std::collections::BTreeSet<String>) -> String {
    words.iter().filter_map(|w| w.chars().next()).collect()
}

pub fn boxed_point(x: f64) -> Box<Point> {
    Box::new(Point::new(x, x * 2.0))
}

pub fn unbox(p: Box<Point>) -> f64 {
    p.x + p.y
}

pub fn read_ptr(p: *const i32) -> i32 {
    unsafe { *p }
}

pub fn bump_ptr(p: *mut i32) {
    unsafe { *p += 1 }
}

// an Option of the crate's enum and struct, from Volt
pub fn describe_opt(c: Option<Color>, p: Option<Point>) -> String {
    format!("{c:?} {p:?}")
}

// a map's values of the crate's struct and enum
pub fn places() -> std::collections::HashMap<String, Point> {
    let mut m = std::collections::HashMap::new();
    m.insert("home".to_string(), Point::new(1.0, 2.0));
    m.insert("work".to_string(), Point::new(3.0, 4.0));
    m
}

pub fn paint(m: &std::collections::BTreeMap<i32, Color>) -> String {
    m.iter().map(|(k, c)| format!("{k}:{c:?}")).collect::<Vec<_>>().join(",")
}

// map keys and set elements of the crate's enum and struct
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Suit {
    Hearts,
    Spades,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Cell {
    pub r: i32,
    pub c: i32,
}

pub fn suit_counts() -> std::collections::HashMap<Suit, i32> {
    let mut m = std::collections::HashMap::new();
    m.insert(Suit::Hearts, 3);
    m.insert(Suit::Spades, 4);
    m
}

pub fn suit_total(m: &std::collections::HashMap<Suit, i32>) -> i32 {
    m.get(&Suit::Hearts).copied().unwrap_or(0) * 10 + m.get(&Suit::Spades).copied().unwrap_or(0)
}

pub fn cells() -> std::collections::BTreeSet<Cell> {
    [Cell { r: 1, c: 2 }, Cell { r: 3, c: 4 }].into_iter().collect()
}

pub fn cell_sum(s: &std::collections::HashSet<Cell>) -> i32 {
    s.iter().map(|x| x.r * 10 + x.c).sum()
}

// Cow<str>: text each way
pub fn cow_upper(s: std::borrow::Cow<str>) -> std::borrow::Cow<'static, str> {
    std::borrow::Cow::Owned(s.to_uppercase())
}

pub fn keep(s: &str) -> std::borrow::Cow<'_, str> {
    std::borrow::Cow::Borrowed(s)
}

// &mut Vec, maps and sets: Volt's, the call's changes written back; Cow<[T]>
pub fn push_evens(v: &mut Vec<i32>, n: i32) {
    for i in 0..n {
        v.push(i * 2);
    }
}

pub fn add_word(m: &mut std::collections::HashMap<String, i32>, w: &str) {
    *m.entry(w.to_string()).or_insert(0) += 1;
}

pub fn add_suit(s: &mut std::collections::BTreeSet<Suit>, x: Suit) -> bool {
    s.insert(x)
}

pub fn doubled_cow(xs: std::borrow::Cow<[i32]>) -> std::borrow::Cow<'static, [i32]> {
    std::borrow::Cow::Owned(xs.iter().map(|x| x * 2).collect())
}

// Rc<T> and Arc<T> of values: the T itself (immutable, so the sharing can't show)
pub fn shared_point(x: f64) -> std::rc::Rc<Point> {
    std::rc::Rc::new(Point::new(x, 2.0))
}

pub fn rc_len(v: std::rc::Rc<Vec<i32>>) -> usize {
    v.len()
}

pub fn arc_name(s: &std::sync::Arc<String>) -> usize {
    s.len()
}

pub fn arc_nums() -> std::sync::Arc<Vec<i32>> {
    std::sync::Arc::new(vec![4, 5, 6])
}

// &Vec<T>: a Vec made for the call
#[allow(clippy::ptr_arg)]
pub fn vec_total(v: &Vec<i32>) -> i32 {
    v.iter().sum()
}

// a future another thread wakes after ms milliseconds, giving how many times it was polled: an await
// that sleeps until its waker polls it twice
struct Late {
    polls: u32,
    ms: u64,
    state: Option<std::sync::Arc<std::sync::Mutex<(bool, Option<std::task::Waker>)>>>,
}

impl std::future::Future for Late {
    type Output = u32;
    fn poll(mut self: std::pin::Pin<&mut Self>, cx: &mut std::task::Context<'_>) -> std::task::Poll<u32> {
        self.polls += 1;
        if self.state.is_none() {
            let s = std::sync::Arc::new(std::sync::Mutex::new((false, Some(cx.waker().clone()))));
            let s2 = s.clone();
            let ms = self.ms;
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(ms));
                let mut g = s2.lock().unwrap();
                g.0 = true;
                if let Some(w) = g.1.take() {
                    w.wake();
                }
            });
            self.state = Some(s);
            return std::task::Poll::Pending;
        }
        let polls = self.polls;
        let s = self.state.clone().unwrap();
        let mut g = s.lock().unwrap();
        if g.0 {
            std::task::Poll::Ready(polls)
        } else {
            g.1 = Some(cx.waker().clone());
            std::task::Poll::Pending
        }
    }
}

pub fn woken_after(ms: u64) -> impl std::future::Future<Output = u32> {
    Late { polls: 0, ms, state: None }
}
