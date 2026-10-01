// a Go library a Volt program uses: bolt builds it with go build -buildmode=c-archive, and cgo writes
// gomath.h from the //export funcs
package main

import "C"

import (
	"strings"
	"unsafe"
)

//export gm_add
func gm_add(a, b C.int) C.int { return a + b }

//export gm_upper
func gm_upper(s *C.char) *C.char { return C.CString(strings.ToUpper(C.GoString(s))) }

//export gm_sum
func gm_sum(xs *C.double, n C.int) C.double {
	sl := unsafe.Slice(xs, int(n))
	var t C.double
	for _, x := range sl {
		t += x
	}
	return t
}

//export gm_words
func gm_words(s string) int { return len(strings.Fields(s)) }

// a c-archive is a main package; main isn't run
func main() {}
