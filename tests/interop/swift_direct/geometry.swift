// Ordinary Swift: nothing here is written for Volt (tests/interop.rs, swift_direct)
import Foundation

struct Point {
    var x: Double
    var y: Double

    var length: Double { (x * x + y * y).squareRoot() }

    func scaled(by k: Double) -> Point { Point(x: x * k, y: y * k) }

    mutating func shift(dx: Double, dy: Double) {
        x += dx
        y += dy
    }

    static func origin() -> Point { Point(x: 0, y: 0) }
}

enum Color: Int {
    case red = 1, green, blue = 7

    var name: String { "\(self)" }

    func next() -> Color { self == .blue ? .red : (self == .red ? .green : .blue) }
}

struct Pixel {
    var at: Point
    var color: Color
}

func distance(_ a: Point, _ b: Point) -> Double {
    (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
}

func greet(name: String, times: Int) -> String {
    Array(repeating: "hi \(name)", count: times).joined(separator: ", ")
}

func brighten(_ p: inout Pixel) {
    p.color = p.color.next()
    p.at.x += 1
}

let LIMIT = 10
let NAME = "geometry"
let RATIO: Double = 1.5
