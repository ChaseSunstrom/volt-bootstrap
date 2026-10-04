// A module's root package, importing another package of the module
package shapes

import "example.com/shapes/units"

func Area(w, h float64) float64 { return w * h }

func Label(w, h float64) string { return units.Meters(w*h) + "²" }
