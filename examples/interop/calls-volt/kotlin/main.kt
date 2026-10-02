// Kotlin/Native calls the Volt library greet through its package (bindings/greet.kt, over cinterop
// of the C header): owned text comes back as a String, an export struct is AutoCloseable
import greet.*

fun main() {
    println("add ${add(2, 3)}")
    println(hello("volt"))
    tally("clicks").use {
        it.add(1)
        val n = it.add(2)
        println("${it.name()} $n")
    }
}
