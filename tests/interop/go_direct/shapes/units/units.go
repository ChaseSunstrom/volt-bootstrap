package units

import "strconv"

func Meters(x float64) string { return strconv.FormatFloat(x, 'f', -1, 64) + " m" }
