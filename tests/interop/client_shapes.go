// Go calls shapelib (voltc bindings --lang go): a generic's instances, a struct held by a type with
// methods, owned values passed in, a Volt trait both ways (any Go value with its methods, lent or
// given; one Volt made, a *VoltShape), closures taking and giving text, handles and errors, closures
// given back, lists, slices of text and handles, and optionals. The library's leak report goes to
// stderr last
package main

/*
#cgo LDFLAGS: -lshapelib
#include <stddef.h>
extern size_t volt_live_allocs;
*/
import "C"

import (
	"errors"
	"fmt"
	"os"

	"client/shapelib"
)

// Go's own shape; Volt calls Close when it's done with one it was given
type circle struct {
	r float64
}

func (c *circle) Area() float64   { return 3 * c.r * c.r }
func (c *circle) Name() string    { return "circle" }
func (c *circle) Grow(by float64) { c.r += by }
func (c *circle) Close()          { fmt.Println("circle gone") }

func errName(err error) string {
	var e *shapelib.Error
	if errors.As(err, &e) {
		return e.Name
	}
	return "?"
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
func extras() {
	positive := func(x int32) error {
		if x <= 0 {
			return shapelib.BankErrorOverdrawn
		}
		return nil
	}
	ok := shapelib.Checked(positive, 1) == nil
	fmt.Println("checked", ok, errName(shapelib.Checked(positive, -1)))
	lim := shapelib.Limiter()
	defer lim.Close()
	fmt.Println("limit", lim.Call(3) == nil, errName(lim.Call(12)))
	sign := shapelib.Labeler()
	defer sign.Close()
	fmt.Println("sign", sign.Call(5), sign.Call(-1))
}

// lists (slices out and in), slices of text and handles, optional text and handles
func lists() {
	a := shapelib.AccountOpen("ann")
	a.Deposit(5)
	b := shapelib.AccountOpen("bobby")
	b.Deposit(9)
	ab := []*shapelib.Account{a, b}
	names := shapelib.Owners(ab)
	fmt.Println("owners", len(names), names[0], names[1])
	fmt.Print("richest ", shapelib.Richest(ab))
	fmt.Println(" after", a.Get(), b.Get())
	opened := shapelib.OpenAll([]string{"cy", "dee"})
	fmt.Println("opened", len(opened), opened[1].Owner())
	for _, x := range opened {
		x.Close()
	}
	sq := shapelib.SquaresUpto(4)
	fmt.Println("squares", len(sq), sq[3], "sum", shapelib.SumAll(sq))
	parts := []string{"a", "b", "c"}
	fmt.Println("joined", shapelib.Joined(parts, "-"), "total", shapelib.TotalLen(parts))
	ann := "ann"
	fmt.Printf("%s; %s\n", shapelib.Greeting(&ann), shapelib.Greeting(nil))
	n1, ok1 := shapelib.Nickname(a)
	_, ok2 := shapelib.Nickname(b)
	fmt.Println("nick", b2i(ok1), n1, b2i(ok2))
	c := shapelib.OpenIf("eve", true)
	d := shapelib.OpenIf("x", false)
	fmt.Println("open_if", b2i(c != nil), b2i(d == nil))
	fmt.Println("close_if", shapelib.CloseIf(c), shapelib.CloseIf(nil))
	// a and b are given to Volt, which closes them
	fmt.Println("close_all", shapelib.CloseAll(ab))
	one, three := int64(1), int64(3)
	fmt.Println("some", shapelib.CountSome([]*int64{&one, nil, &three}))
	fmt.Println("rows", shapelib.TotalRows([][]int64{{1, 2}, {3}}))
	fmt.Println("lists closed", shapelib.ClosedAccounts())
}

func run() {
	extras()
	fmt.Println("biggest", shapelib.BiggestI32([]int32{3, 9, 4}), shapelib.BiggestF64([]float64{1.5, 0.5}))
	a := shapelib.AccountOpen("ann")
	a.Deposit(250)
	a.Rename("bea")
	n := a.Deposit(50)
	fmt.Println("account", a.Owner(), n)
	n = shapelib.Visit(a, func(b *shapelib.Account) int64 { return b.Deposit(1) })
	fmt.Println("visit", n, "get", a.Get())
	n = shapelib.CloseAccount(a)
	fmt.Println("closed", n, shapelib.ClosedAccounts())
	c := &circle{r: 1}
	defer c.Close()
	fmt.Println(shapelib.Describe(c))
	fmt.Println("grown", shapelib.GrowTwice(&circle{r: 1}))
	sq := shapelib.MakeSquare(2)
	defer sq.Close()
	sq.Grow(1)
	fmt.Println(sq.Name(), sq.Area(), shapelib.Describe(sq))
	fmt.Println(shapelib.Shout(func(s string) string { return s + "!" }, "hey"))
	twice := func(x int32) (int32, error) {
		if x > 5 {
			return 0, shapelib.BankErrorOverdrawn
		}
		return x * 2, nil
	}
	t, _ := shapelib.TryTwice(twice, 1)
	_, err := shapelib.TryTwice(twice, 4)
	fmt.Println("try", t, errName(err))
	fmt.Println("opened", shapelib.OpenedBy(func(owner string) *shapelib.Account {
		b := shapelib.AccountOpen(owner)
		b.Deposit(7)
		return b
	}))
	fmt.Println("closed", shapelib.ClosedAccounts())
	d := shapelib.Doubler()
	defer d.Close()
	hi := shapelib.Greeter()
	defer hi.Close()
	fmt.Println(d.Call(21), hi.Call("volt"))
	lists()
}

// an account a running call lent to Volt can't be closed or given away by a callback meanwhile
// (it prints only what was wrongly accepted)
func inUse() {
	a := shapelib.AccountOpen("busy")
	defer a.Close()
	refused := func(what string, f func()) {
		defer func() {
			if recover() == nil {
				fmt.Println("accepted:", what)
			}
		}()
		f()
	}
	refused("closing an account a call holds", func() {
		shapelib.Visit(a, func(*shapelib.Account) int64 {
			a.Close()
			return 0
		})
	})
	refused("giving away an account a call holds", func() {
		shapelib.Visit(a, func(*shapelib.Account) int64 { return shapelib.CloseAccount(a) })
	})
	refused("closing an account a call holds in a slice", func() {
		shapelib.VisitOver([]*shapelib.Account{a}, func(*shapelib.Account) int64 {
			a.Close()
			return 0
		})
	})
	refused("lending and giving one account in one call", func() {
		shapelib.LendGive(a, a)
	})
	// a callback that panics leaves what the call lent as it was (closable after)
	func() {
		defer func() { recover() }()
		shapelib.VisitThen(func(*shapelib.Account) int64 { panic("thrown") }, a)
	}()
}

// what Volt writes into a slice of optionals comes back (it prints only what's wrong)
func fillSome() {
	three := int64(3)
	xs := []*int64{&three, nil}
	shapelib.FillSome(xs)
	if xs[0] == nil || xs[1] == nil || *xs[0] != 6 || *xs[1] != 20 {
		fmt.Println("fill_some: Volt's writes didn't come back")
	}
}

func main() {
	run()
	inUse()
	fillSome()
	fmt.Fprintf(os.Stderr, "volt live: %d\n", C.volt_live_allocs)
}
