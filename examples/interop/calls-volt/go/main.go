// Go calls the Volt library greet through its cgo package (bindings/greet.go): owned text comes
// back as a string, an export struct is a type with Close
package main

import (
	"fmt"

	"client/greet"
)

func main() {
	fmt.Println("add", greet.Add(2, 3))
	fmt.Println(greet.Hello("volt"))
	c := greet.NewTally("clicks")
	defer c.Close()
	c.Add(1)
	n := c.Add(2)
	fmt.Println(c.Name(), n)
}
