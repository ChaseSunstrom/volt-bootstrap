package geo

/** a class: Volt holds it by handle, and a copy shares the object */
class Counter(val label: String) {
    var count: Int = 0
        private set

    constructor(label: String, start: Int) : this(label) {
        count = start
    }

    fun bump(k: Int): Int {
        count += k
        return count
    }
}

fun makeCounter(label: String): Counter = Counter(label, 100)

object Registry {
    private val names = mutableListOf<String>()

    fun add(name: String): Int {
        names.add(name)
        return names.size
    }
}

fun total(xs: List<Double>): Double = xs.sum()

fun squares(n: Int): List<Int> = (1..n).map { it * it }

fun words(s: String): List<String> = s.split(" ")

fun shout(parts: List<String>): String = parts.joinToString(" ") { it.uppercase() }

fun find(xs: List<Int>, x: Int): Int? = xs.indexOf(x).takeIf { it >= 0 }

fun orDefault(x: Int?): Int = x ?: -1

fun parse(s: String): Int = s.trim().toIntOrNull() ?: throw IllegalArgumentException("not a number: $s")

val describe = """a "raw" string with ${'$'}{no} template"""

// overloads: Volt overloads, told apart by their types
fun describe(x: Int): String = "int $x"
fun describe(x: Double): String = "double $x"
fun describe(s: String): String = "text $s"

// a vararg parameter: a trailing T[..]
fun sum(label: String, vararg xs: Int): String = "$label ${xs.sum()}"

fun joined(vararg parts: String): String = parts.joinToString("+")

// typealiases: their types
typealias Meters = Double
typealias Names = List<String>

fun walk(d: Meters): Meters = d * 2

fun count(ns: Names): Int = ns.size

// extension funs: a method of an imported class, an attach fn on str and i32
fun Counter.doubled(): Int = count * 2

fun String.exclaim(): String = uppercase() + "!"

fun Int.squared(): Int = this * this

// nested types: Outer_Inner
class Garage(val name: String) {
    class Car(val wheels: Int) {
        fun describe(): String = "car with $wheels wheels"
    }

    enum class Size { SMALL, LARGE }

    object Rules {
        fun limit(): Int = 3
    }

    fun park(c: Car, s: Size): String = "$name: ${c.wheels} ${s.name.lowercase()}"
}

// suspend funs: what they give, when they don't suspend
suspend fun quick(n: Int): Int = n + 1

suspend fun parked(): Int = kotlin.coroutines.suspendCoroutine { }
