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

// overloads: Volt tells these apart by their types...
func describe(_ x: Int) -> String { "int \(x)" }
func describe(_ x: Double) -> String { "double \(x)" }
func describe(_ s: String) -> String { "text \(s)" }

// ...and these by their labels alone: move_by and move_to
func move(by k: Int) -> Int { k + 1 }
func move(to k: Int) -> Int { k * 10 }

// a getter that throws, and one that's async
struct Gauge {
    var level: Int = 3

    var checked: Int {
        get throws {
            if level < 0 { throw ParseError.notANumber("level") }
            return level * 2
        }
    }

    var slow: Int {
        get async {
            await Task.yield()
            return level + 100
        }
    }
}

func later(_ n: Int) async -> Int {
    await Task.yield()
    return n * 2
}

func laterOrFail(_ n: Int) async throws -> Int {
    await Task.yield()
    if n < 0 { throw ParseError.notANumber("negative") }
    return n
}

// an actor: what it isolates is reached through await
actor Tally {
    var n = 0

    func add(_ k: Int) -> Int {
        n += k
        return n
    }

    nonisolated func name() -> String { "tally" }
}

// the main actor's: called from the main thread
@MainActor func onMain() -> Int { 7 }

@MainActor func onMainLater() async -> Int {
    await Task.yield()
    return 9
}

// #if: the branch that holds for this swiftc
#if os(Linux) || os(macOS) || os(Windows)
func platformKnown() -> Bool { true }
#else
func platformKnown() -> Bool { false }
#endif

#if canImport(NoSuchModuleHere)
func impossible() -> Int { 0 }
#endif
