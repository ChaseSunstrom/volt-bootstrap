// Go calls the Volt library through voltc bindings --lang go (cgo): errors come back as *Error
// values, owned text as a string, an export struct is a type with Close
package main

import (
	"errors"
	"fmt"
	"strings"

	"client/mathlib"
)

func main() {
	fmt.Println("add", mathlib.MlAdd(2, 3))
	a := mathlib.Vec2{X: 1, Y: 2}
	b := mathlib.Vec2{X: 3, Y: 4}
	fmt.Println("dot", mathlib.MlDot(a, b))
	mathlib.MlScale(&a, 2)
	fmt.Println("scale", a.X, a.Y)
	fmt.Println("len", mathlib.MlLen("hello"))
	fmt.Println("clash", mathlib.MlClash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14))
	fmt.Println("next", int(mathlib.MlNext(mathlib.ColorGreen)))
	r, _ := mathlib.MlSqrt(9)
	fmt.Println("sqrt", r, 1)
	if _, err := mathlib.MlSqrt(-1); errors.Is(err, mathlib.MathErrorNegative) {
		fmt.Println("error negative")
	}
	fmt.Println("greet", mathlib.MlGreet("volt"))
	s, _ := mathlib.MlRepeat("ab", 2)
	fmt.Println("repeat", s)
	if _, err := mathlib.MlRepeat("ab", -1); err != nil {
		fmt.Println("repeat", strings.ToLower(err.Error()))
	}
	fmt.Println("sum", mathlib.MlSum([]float64{1, 2, 3.5}))
	ys := []int32{4, 5, 6}
	i, _ := mathlib.MlFind(ys, 6)
	_, found := mathlib.MlFind(ys, 9)
	none := "?"
	if !found {
		none = "none"
	}
	fmt.Println("find", i, none)
	var seen []string
	total := int32(0)
	mathlib.MlEach(ys, func(x int32) {
		seen = append(seen, fmt.Sprint(x))
		total += x
	})
	fmt.Println("each", strings.Join(seen, " "), "=", total)
	c := mathlib.NewCounter("clicks")
	defer c.Close()
	c.Add(2)
	fmt.Println("counter", c.Name(), c.Add(3))
	if _, err := c.Take(9); err != nil {
		var e *mathlib.Error
		if errors.As(err, &e) {
			fmt.Println("take", strings.ToLower(e.Name))
		}
	}
}
