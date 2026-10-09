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
	tg := mathlib.MlTagsMake()
	fmt.Printf("tags %d %d %d %d", tg.From, tg.Type, tg.Self, tg.Int)
	tg.Int = 5
	fmt.Printf(" %d\n", mathlib.MlTagsSum(tg))
	bp, bq := int32(7), 2.5
	mathlib.MlBump(&bp, &bq)
	fmt.Println("bump", bp, bq)
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
	// structs with text, an array and a struct in them (in, out, in a slice, from a func), one with
	// a pointer, E!T as a parameter (a value and an error)
	la := mathlib.MlLabel{Name: "ab", Sizes: [3]int32{1, 2, 3}, At: mathlib.Vec2{X: 7}}
	fmt.Println("label", mathlib.MlLabelLen(la))
	lb := mathlib.MlLabelOf("ab", 3)
	fmt.Println("label_of", lb.Name, lb.Sizes[0], lb.Sizes[1], lb.Sizes[2], lb.At.X)
	fmt.Println("labels", mathlib.MlLabelsLen([]mathlib.MlLabel{la, lb}))
	fmt.Println("holder", mathlib.MlHolderK(mathlib.MlHolder{P: nil, K: 3}))
	fmt.Println("or", mathlib.MlOr(4.5, nil, 9.5), mathlib.MlOr(0, mathlib.MathErrorNegative, 9.5))
	fmt.Println("ask", mathlib.MlAsk(func(k int32) mathlib.MlLabel {
		return mathlib.MlLabel{Name: "abc", Sizes: [3]int32{k, k, k}, At: mathlib.Vec2{X: 3}}
	}))
	mathlib.MlRelabel(&lb, 4)
	fmt.Println("relabel", lb.Name, lb.Sizes[0], lb.Sizes[1], lb.Sizes[2])
	fmt.Println("count", mathlib.MlLabelsCount([]mathlib.MlLabel{la, lb}))
	fmt.Println("note", mathlib.MlNoteLen(mathlib.MlNote{Str: "abc", C: 1, K: 3}))
	fmt.Println("or_label", mathlib.MlOrLabel(la, nil), mathlib.MlOrLabel(mathlib.MlLabel{}, mathlib.MathErrorNegative))
	fmt.Println("given", mathlib.MlSumGiven(3, func(k int32) []int64 { return []int64{int64(k), 10 * int64(k)} }), mathlib.MlAreaGiven(func(k int32) []mathlib.Vec2 {
		return []mathlib.Vec2{{X: 1.5, Y: float64(k)}, {X: 2, Y: 3.25}}
	}))
	deep := [][][]int64{{{1, 2}, {3}}, {{4}}}
	d := mathlib.MlDeep(deep)
	fmt.Println("deep", d, deep[0][0][1], deep[1][0][0], "words", mathlib.MlWords([][]string{{"ab", "c"}, {}, {"def"}}))
}
