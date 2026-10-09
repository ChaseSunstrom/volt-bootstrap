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
    // structs with text, an array and a struct in them (in, out, in a list, from a lambda), one with
    // a pointer, E!T as a parameter (a Result)
    val la = ml_label("ab", intArrayOf(1, 2, 3), vec2(7.0, 0.0))
    println("label ${ml_label_len(la)}")
    val lb = ml_label_of("ab", 3)
    println("label_of ${lb.name} ${lb.sizes.joinToString(" ")} ${lb.at.x}")
    println("labels ${ml_labels_len(listOf(la, lb))}")
    println("holder ${ml_holder_k(ml_holder(null, 3))}")
    println("or ${ml_or(Result.success(4.5), 9.5)} ${ml_or(Result.failure(VoltException.of(math_error.NEGATIVE)), 9.5)}")
    println("ask ${ml_ask { k -> ml_label("abc", intArrayOf(k, k, k), vec2(3.0, 0.0)) }}")
    ml_relabel(lb, 4)
    println("relabel ${lb.name} ${lb.sizes.joinToString(" ")}")
    println("count ${ml_labels_count(listOf(la, lb))}")
    println("note ${ml_note_len(ml_note("abc", 1, 3))}")
    println("or_label ${ml_or_label(Result.success(la))} ${ml_or_label(Result.failure(VoltException.of(math_error.NEGATIVE)))}")

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
