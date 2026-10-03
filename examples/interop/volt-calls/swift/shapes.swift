// Ordinary Swift: nothing in it is written for Volt
struct Point {
    var x: Double
    var y: Double

    var length: Double { (x * x + y * y).squareRoot() }
}

final class Tally {
    private(set) var total = 0

    func add(_ n: Int) -> Int {
        total += n
        return total
    }
}

enum MathError: Error {
    case divisionByZero
}

func divide(_ a: Int, by b: Int) throws -> Int {
    if b == 0 { throw MathError.divisionByZero }
    return a / b
}

func shout(_ words: [String]) -> String { words.map { $0.uppercased() }.joined(separator: " ") }
