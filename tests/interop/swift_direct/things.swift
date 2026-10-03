// More of the same module: classes, arrays, optionals, errors (tests/interop.rs, swift_direct)
import Foundation

enum ParseError: Error {
    case notANumber(String)
}

final class Counter {
    private(set) var count = 0
    let label: String

    init(label: String) {
        self.label = label
    }

    convenience init(label: String, start: Int) {
        self.init(label: label)
        count = start
    }

    @discardableResult
    func bump(by k: Int = 1) -> Int {
        count += k
        return count
    }
}

struct Inventory {
    var items: [String] = []

    mutating func add(_ item: String) { items.append(item) }

    func summary() -> String { items.joined(separator: "+") }
}

func total(_ xs: [Double]) -> Double { xs.reduce(0, +) }

func squares(upTo n: Int) -> [Int] { (1...n).map { $0 * $0 } }

func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }

func shout(_ parts: [String]) -> String { parts.map { $0.uppercased() }.joined(separator: " ") }

func find(_ xs: [Int32], _ x: Int32) -> Int? { xs.firstIndex(of: x) }

func orDefault(_ x: Int?) -> Int { x ?? -1 }

func parse(_ text: String) throws -> Int {
    guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { throw ParseError.notANumber(text) }
    return n
}

func makeCounter(_ label: String) -> Counter { Counter(label: label, start: 100) }

private func hidden() {}
