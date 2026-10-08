// More of package geom, all of it ordinary Go: generics, funcs both ways, maps, sets, slices of
// structs, arrays, channels and goroutines, interfaces, pointers, several results, variadics,
// panics and constants of every type
package geom

import (
	"cmp"
	"errors"
	"sort"
	"strconv"
	"strings"
)

// Max is generic: Volt gets an instance per use
func Max[T cmp.Ordered](xs ...T) T {
	m := xs[0]
	for _, x := range xs[1:] {
		if x > m {
			m = x
		}
	}
	return m
}

func Map[T, U any](xs []T, f func(T) U) []U {
	out := make([]U, 0, len(xs))
	for _, x := range xs {
		out = append(out, f(x))
	}
	return out
}

// Stack is a generic type: a type per instance a program names
type Stack[T any] struct {
	items []T
}

func (s *Stack[T]) Push(x T) { s.items = append(s.items, x) }

func (s *Stack[T]) Pop() (T, bool) {
	var zero T
	if len(s.items) == 0 {
		return zero, false
	}
	x := s.items[len(s.items)-1]
	s.items = s.items[:len(s.items)-1]
	return x, true
}

func (s *Stack[T]) Len() int { return len(s.items) }

// Op is a named func type
type Op func(a, b int) int

func Fold(xs []int, start int, op Op) int {
	for _, x := range xs {
		start = op(start, x)
	}
	return start
}

func Adder(n int) func(int) int { return func(x int) int { return x + n } }

func Greeter(greeting string) func(string) string {
	return func(who string) string { return greeting + ", " + who }
}

// callbacks taking the package's types, and giving errors
func CountIf(ps []Point, keep func(Point) bool) int {
	n := 0
	for _, p := range ps {
		if keep(p) {
			n++
		}
	}
	return n
}

func Each(words []string, f func(string) error) error {
	for _, w := range words {
		if err := f(w); err != nil {
			return errors.New("each: " + err.Error())
		}
	}
	return nil
}

// slices of structs both ways; a *Point changes in place
func Corners(w, h float64) []Point { return []Point{{0, 0}, {w, 0}, {w, h}, {0, h}} }

func Centroid(ps []Point) Point {
	var c Point
	for _, p := range ps {
		c.X += p.X / float64(len(ps))
		c.Y += p.Y / float64(len(ps))
	}
	return c
}

func Shift(ps []Point, dx float64) {
	for i := range ps {
		ps[i].X += dx
	}
}

// maps, and a map used as a set
func Count(words []string) map[string]int {
	m := map[string]int{}
	for _, w := range words {
		m[w]++
	}
	return m
}

func Lookup(m map[string]int, k string) int { return m[k] }

// Inventory is a named map type with a method
type Inventory map[string]int

func (inv Inventory) Total() int {
	t := 0
	for _, n := range inv {
		t += n
	}
	return t
}

func Unique(words []string) map[string]struct{} {
	s := map[string]struct{}{}
	for _, w := range words {
		s[w] = struct{}{}
	}
	return s
}

// a set of structs
func Visited(ps []Point) map[Point]struct{} {
	s := map[Point]struct{}{}
	for _, p := range ps {
		s[p] = struct{}{}
	}
	return s
}

// SumValues is generic over a map of its type parameter
func SumValues[K comparable](m map[K]int) int {
	t := 0
	for _, v := range m {
		t += v
	}
	return t
}

func Places() map[string]Point { return map[string]Point{"home": {1, 2}, "work": {5, 5}} }

func Grid(n int) [][]int {
	g := make([][]int, n)
	for i := range g {
		g[i] = make([]int, n)
		for j := range g[i] {
			g[i][j] = i * j
		}
	}
	return g
}

func Shapes() []*Shape { return []*Shape{NewShape("a", []float64{1}), NewShape("b", []float64{1, 2})} }

func Names(ss []*Shape) string {
	var names []string
	for _, s := range ss {
		names = append(names, s.Name)
	}
	sort.Strings(names)
	return strings.Join(names, "+")
}

// Triple is a named array type
type Triple [3]int

func (t Triple) Sum() int { return t[0] + t[1] + t[2] }

func MakeTriple(a, b, c int) Triple { return Triple{a, b, c} }

// channels: a goroutine's values come through one
func Range(n int) <-chan int {
	c := make(chan int)
	go func() {
		for i := 0; i < n; i++ {
			c <- i
		}
		close(c)
	}()
	return c
}

func Collect(c <-chan int) []int {
	var out []int
	for x := range c {
		out = append(out, x)
	}
	return out
}

// Pipe calls f from its own goroutine (another thread)
func Pipe(in <-chan int, f func(int) int) <-chan int {
	out := make(chan int, 1)
	go func() {
		for x := range in {
			out <- f(x)
		}
		close(out)
	}()
	return out
}

// Figure is an interface: a Volt trait
type Figure interface {
	Area() float64
	Name() string
}

// Square is a plain struct implementing Figure
type Square struct {
	Side float64
}

func (s Square) Area() float64 { return s.Side * s.Side }

func (s Square) Name() string { return "square" }

func Tell(f Figure) string {
	return f.Name() + " of area " + strconv.FormatFloat(f.Area(), 'f', -1, 64)
}

func UnitSquare() Figure { return Square{1} }

func Larger(a, b Figure) Figure {
	if a.Area() >= b.Area() {
		return a
	}
	return b
}

// Store's methods give (T, bool) and take a func: a Volt type's give T? and take a fn
type Store interface {
	Get(k string) (int, bool)
	Each(f func(k string) bool) int
}

func Probe(s Store) string {
	n, ok := s.Get("a")
	_, found := s.Get("zz")
	return strconv.Itoa(n) + " " + strconv.FormatBool(ok) + " " + strconv.FormatBool(found) + " " + strconv.Itoa(s.Each(func(k string) bool { return k != "stop" }))
}

// pointers to numbers
func Incr(p *int) { *p++ }

func NewCounter(start int) *int { return &start }

// Chunk is generic over a slice of slices: slice<std::vec<T>>, a handle of Go's
func Chunk[T any](xs []T, n int) [][]T {
	var out [][]T
	for len(xs) > n {
		out, xs = append(out, xs[:n]), xs[n:]
	}
	return append(out, xs)
}

// callbacks giving several results, and a slice
func Spread(f func(int) (int, string)) string { n, s := f(2); return strings.Repeat(s, n) }

func SumOf(f func() []int) int {
	t := 0
	for _, x := range f() {
		t += x
	}
	return t
}

// several results
func MinMax(xs []int) (lo, hi int) {
	lo, hi = xs[0], xs[0]
	for _, x := range xs {
		lo, hi = min(lo, x), max(hi, x)
	}
	return
}

func Cut(s, sep string) (before, after string, found bool) { return strings.Cut(s, sep) }

func Divmod(a, b int) (int, int, error) {
	if b == 0 {
		return 0, 0, errors.New("divide by zero")
	}
	return a / b, a % b, nil
}

// variadics
func Joinf(sep string, parts ...string) string { return strings.Join(parts, sep) }

// a panic: an index out of range
func At(xs []int, i int) int { return xs[i] }

// a named basic type, and constants of every type
type Celsius float64

func (c Celsius) Fahrenheit() float64 { return float64(c)*9/5 + 32 }

const Boiling Celsius = 100

const Small float32 = 0.25

const Tabbed = "tab\there \"quoted\" é"
