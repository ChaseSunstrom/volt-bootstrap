// An ordinary Go package: nothing in it is written for Volt
package geom

import (
	"errors"
	"math"
	"strconv"
	"strings"
)

// Version is the package's version
const Version = "1.2"

const (
	Limit = 10
	Ratio = 0.5
)

// Point is a plain struct: Volt holds it by value
type Point struct {
	X, Y float64
}

func (p Point) Norm() float64 { return math.Hypot(p.X, p.Y) }

func (p *Point) Scale(k float64) {
	p.X *= k
	p.Y *= k
}

func Dist(a, b Point) float64 { return math.Hypot(a.X-b.X, a.Y-b.Y) }

func Mid(a, b Point) Point { return Point{(a.X + b.X) / 2, (a.Y + b.Y) / 2} }

// Color is an enum
type Color int

const (
	Red Color = iota
	Green
	Blue
)

func (c Color) Name() string { return [...]string{"red", "green", "blue"}[c] }

func Next(c Color) Color { return (c + 1) % 3 }

// Pixel holds a Point and a Color: still plain
type Pixel struct {
	At    Point
	Color Color
}

func Brighten(p *Pixel) { p.Color = Next(p.Color) }

// Shape holds a string and a slice: Volt holds a handle to it
type Shape struct {
	Name  string
	sides []float64
}

func NewShape(name string, sides []float64) *Shape {
	return &Shape{Name: name, sides: append([]float64(nil), sides...)}
}

func (s *Shape) Add(side float64) { s.sides = append(s.sides, side) }

func (s *Shape) Perimeter() float64 {
	t := 0.0
	for _, x := range s.sides {
		t += x
	}
	return t
}

func (s Shape) Describe() string { return s.Name + " with " + strconv.Itoa(len(s.sides)) + " sides" }

func (s *Shape) Side(i int) (float64, error) {
	if i < 0 || i >= len(s.sides) {
		return 0, errors.New("no side " + strconv.Itoa(i))
	}
	return s.sides[i], nil
}

func Longest(a, b *Shape) *Shape {
	if a.Perimeter() >= b.Perimeter() {
		return a
	}
	return b
}

func Sum(xs []float64) float64 {
	t := 0.0
	for _, x := range xs {
		t += x
	}
	return t
}

// Double changes Volt's array in place
func Double(xs []int) {
	for i := range xs {
		xs[i] *= 2
	}
}

func Squares(n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = (i + 1) * (i + 1)
	}
	return out
}

func Join(parts []string, sep string) string { return strings.Join(parts, sep) }

func Words(s string) []string { return strings.Fields(s) }

func Upper(s string) string { return strings.ToUpper(s) }

func Parse(s string) (int, error) { return strconv.Atoi(strings.TrimSpace(s)) }

func Find(xs []int, x int) (int, bool) {
	for i, y := range xs {
		if y == x {
			return i, true
		}
	}
	return 0, false
}

func Check(ok bool) error {
	if !ok {
		return errors.New("not ok")
	}
	return nil
}

// a func, a variadic and a generic: Volt calls these too
func Apply(f func(int) int, x int) int { return f(x) }

func Total(xs ...int) int { return len(xs) }

func Ident[T any](x T) T { return x }
