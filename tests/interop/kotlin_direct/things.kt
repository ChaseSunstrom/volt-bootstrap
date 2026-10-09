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
