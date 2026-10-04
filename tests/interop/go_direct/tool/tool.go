// A main package (a program of its own): Volt calls its exported funcs all the same
package main

import "fmt"

func Version() string { return "tool 3" }

func main() { fmt.Println(Version()) }
