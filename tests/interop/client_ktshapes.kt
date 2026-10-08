// Kotlin/Native calls ktshapes (voltc bindings --lang kotlin): what shapelib's clients don't call
import ktshapes.*

// Kotlin's own sizer, kept by a holder Volt made: Volt closes it when the holder goes
class Sizer(val k: Long) : sizer, AutoCloseable {
    override fun size(t: thing): Long = t.get() + k

    override fun make(n: Long): thing = thing(n)

    override fun label(): String = "kotlin"

    override fun close() = println("sizer gone")
}

fun main() {
    holder(Sizer(1)).use { h -> println("measure ${h.measure(4)} ${h.tag()}") }
    fixed_sizer(2).use { f -> holder(f).use { h -> println("fixed ${h.measure(3)} ${h.tag()}") } }
    val seen = mutableListOf<Long>()
    each_thing(3) { t -> t.use { seen.add(it.get()) } }
    println("each $seen")
    // a callback that threw: Volt's later calls of it are skipped, and what they're given is freed
    val failed = runCatching { each_thing(3) { t -> t.use { throw IllegalStateException("each") } } }
    println("failed ${failed.exceptionOrNull()?.message} ${gone_things()}")
    // members named like AutoCloseable's close
    thing(7).use { t -> println("close_ ${t.close_()} ${t.get()}") }
    shut(object : stream {
        override fun close_() = println("shut")
    })
    println("label ${label_of({ x -> "n$x" }, 7)}")
    println("slice ${with_slice { xs -> xs.sum() }}")
    println("result ${with_result({ r -> r.getOrElse { -1L } }, true)} ${with_result({ r -> if (r.isFailure) 9L else 0L }, false)}")
    println("maybe ${maybe_text(true)} ${maybe_text(false)}")
    println("cstr ${cstr_len("hello")}")
    println("some ${some_list()}")
    getter().use { g -> thing(8).use { t -> println("getter ${g(t)}") } }
    val big = keep_big(listOf(thing(1), thing(5), thing(9)), 5)
    println("big ${big.map { it.get() }}")
    big.forEach { it.close() }
    thing(4).use { t -> println("lend ${lend_then(t) { it * 2 }}") }
    println("give ${give_then(thing(6)) { it + 1 }}")
    val r = rec("ab", "tag", intArrayOf(1, 2, 3), doubleArrayOf(1.0, 2.0), Result.success(1L), hue.BLUE, 4)
    println("rec ${rec_sum(r)}")
    rec_bump(r)
    println("bumped ${r.nums[0]} ${r.c} ${r.name} ${r.tag} ${r.h} ${r.res.getOrNull()}")
    println("made ${rec_make { n -> rec("xyz", null, intArrayOf(0, 0, n.toInt()), doubleArrayOf(), Result.failure(VoltException.of(oops.BAD)), hue.RED, 0) }}")
    println("total2 ${total2(listOf(longArrayOf(1, 2), longArrayOf(3)))}")
    println("text ${count_text(listOf("ab", null, "c"))}")
    println("blues ${blues(listOf(hue.RED, hue.BLUE, hue.BLUE))}")
    println("first_two ${first_two(longArrayOf(4, 5, 6)).toList()}")
    thing(5).use { t -> println("maybe_get ${maybe_get(t)} ${maybe_get(null)}") }
    println("slice_back ${slice_back { n -> LongArray(n.toInt()) { it.toLong() } }}")
    // a VoltException of code 0 is no error: Volt gets E's first
    println("str_result ${str_result { "four" }} ${str_result { throw VoltException.of(oops.BAD) }} ${str_result { throw VoltException(0u, "none") }}")
    println("text_in ${text_in { it.length.toLong() }}")
    println("list_or ${list_or(true)} ${runCatching { list_or(false) }.exceptionOrNull()?.message}")
    sizer_or(true).use { s -> println("sizer_or ${s.label()}") }
    println("gone ${gone_things()}")
}
