// Kotlin/Native calls the Volt library through voltc bindings --lang kotlin, over cinterop of the
// C header: errors are thrown as VoltException subclasses, owned text comes back as a String, an
// export struct is an AutoCloseable class (a Cleaner frees it too, once it's collected)
@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

import kotlinx.cinterop.*
import mathlib.*

fun n(v: Double): String = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

fun main() {
    println("add ${ml_add(2, 3)}")
    val a = vec2(1.0, 2.0)
    val b = vec2(3.0, 4.0)
    println("dot ${n(ml_dot(a, b))}")
    ml_scale(a, 2.0)
    println("scale ${n(a.x)} ${n(a.y)}")
    println("len ${ml_len("hello")}")
    println("clash ${ml_clash(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, "ab", 13, 14)}")
    val tg = ml_tags_make()
    val head = "tags ${tg.from} ${tg.type} ${tg.self} ${tg.int}"
    tg.int = 5
    println("$head ${ml_tags_sum(tg)}")
    memScoped {
        val bp = alloc<IntVar>()
        bp.value = 7
        val bq = alloc<DoubleVar>()
        bq.value = 2.5
        ml_bump(bp.ptr, bq.ptr)
        println("bump ${bp.value} ${n(bq.value)}")
    }
    println("next ${ml_next(color.GREEN).value}")
    println("sqrt ${n(ml_sqrt(9.0))} 1")
    try {
        ml_sqrt(-1.0)
    } catch (e: math_error) {
        println("error ${if (e.code == math_error.NEGATIVE) "negative" else "?"}")
    }
    println("greet ${ml_greet("volt")}")
    println("repeat ${ml_repeat("ab", 2)}")
    try {
        ml_repeat("ab", -1)
    } catch (e: VoltException) {
        println("repeat ${e.name.lowercase()}")
    }
    println("sum ${n(ml_sum(doubleArrayOf(1.0, 2.0, 3.5)))}")
    val ys = intArrayOf(4, 5, 6)
    println("find ${ml_find(ys, 6)} ${if (ml_find(ys, 9) == null) "none" else "?"}")
    val seen = mutableListOf<Int>()
    ml_each(ys) { seen.add(it) }
    println("each ${seen.joinToString(" ")} = ${seen.sum()}")
    val c = counter("clicks")
    c.use {
        it.add(2)
        println("counter ${it.name()} ${it.add(3)}")
        try {
            it.take(9)
        } catch (e: math_error) {
            println("take ${e.name.lowercase()}")
        }
    }

    // a callback's exception comes out of the call (the later calls are skipped), and a closed
    // counter throws
    var calls = 0
    try {
        ml_each(ys) {
            calls++
            throw IllegalStateException("stop at $it")
        }
        error("no error")
    } catch (e: IllegalStateException) {
        check(e.message == "stop at 4" && calls == 1) { "callback error: ${e.message} $calls" }
    }
    check(runCatching { c.add(1) }.isFailure) { "closed counter accepted" }
}
