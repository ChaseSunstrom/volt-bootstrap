@file:OptIn(ExperimentalUnsignedTypes::class)
// Kotlin/Native calls shapelib (voltc bindings --lang kotlin): a generic's instances, a struct held
// by a class with methods, owned values passed in, a Volt trait as a Kotlin interface both ways,
// callbacks taking and giving text, handles and errors, closures given back as callable classes,
// and lists as Lists
import shapelib.*

// Kotlin's own shape: Volt calls it through the trait's table, and closes one it was given
class Circle(var r: Double) : shape, AutoCloseable {
    override fun area(): Double = 3 * r * r

    override fun name(): String = "circle"

    override fun grow(by: Double) {
        r += by
    }

    override fun close() = println("circle gone")
}

fun num(d: Double): String = if (d == d.toLong().toDouble()) d.toLong().toString() else d.toString()

fun twice(x: Int): Int {
    if (x > 5) {
        throw VoltException.of(bank_error.OVERDRAWN)
    }
    return x * 2
}

// what C and C++ don't print: an E!void callback, closures given back giving E!void and a str
fun extras() {
    var ok = true
    try {
        checked({ x -> if (x <= 0) throw VoltException.of(bank_error.OVERDRAWN) }, 1)
    } catch (e: VoltException) {
        ok = false
    }
    var err = ""
    try {
        checked({ throw VoltException.of(bank_error.OVERDRAWN) }, 1)
    } catch (e: bank_error) {
        err = e.name
    }
    println("checked $ok $err")
    limiter().use { lim ->
        val under = runCatching { lim(3) }.isSuccess
        val over = try {
            lim(12)
            ""
        } catch (e: bank_error) {
            e.name
        }
        println("limit $under $over")
    }
    labeler().use { sign -> println("sign ${sign(5)} ${sign(-1)}") }
}

// lists (Lists both ways), Lists of text and handles, null for none
fun lists() {
    val a = account.open("ann")
    a.deposit(5)
    val b = account.open("bobby")
    b.deposit(9)
    val ab = listOf(a, b)
    val os = owners(ab)
    println("owners ${os.size} ${os[0]} ${os[1]}")
    print("richest ${richest(ab)}")
    println(" after ${a.get()} ${b.get()}")
    val opened = open_all(listOf("cy", "dee"))
    println("opened ${opened.size} ${opened[1].owner()}")
    opened.forEach { it.close() }
    val sq = squares_upto(4)
    println("squares ${sq.size} ${sq[3]} sum ${sum_all(sq)}")
    val parts = listOf("a", "b", "c")
    println("joined ${joined(parts, "-")} total ${total_len(parts)}")
    println("${greeting("ann")}; ${greeting(null)}")
    val n1 = nickname(a)
    val n2 = nickname(b)
    println("nick ${if (n1 != null) 1 else 0} $n1 ${if (n2 != null) 1 else 0}")
    val c = open_if("eve", true)
    val d = open_if("x", false)
    println("open_if ${if (c != null) 1 else 0} ${if (d == null) 1 else 0}")
    println("close_if ${close_if(c)} ${close_if(null)}")
    println("close_all ${close_all(ab)}")
    println("some ${count_some(listOf(1L, null, 3L))}")
    println("rows ${total_rows(listOf(longArrayOf(1, 2), longArrayOf(3)))}")
    val rot = rotated(longArrayOf(11, 12, 13))
    val sw = swapped(doubleArrayOf(1.5, 2.5))
    val bu = bumped(ubyteArrayOf(1u, 2u, 3u))
    println("arrays ${rot.joinToString(" ")} ${sw.joinToString(" ")} ${bu.joinToString(" ")}")
    val t0 = object : tagged {
        override fun type(): Int = 1
        override fun from(x: Int): Int = x + 1
        override fun int(): Int = 2
        override fun close_(): Int = 3
    }
    make_tagged(5).use { tv ->
        println("tagged ${tagged_sum(t0)} ${tv.type()} ${tv.from(4)} ${tv.int()} ${tv.close_()} ${tagged_sum(tv)}")
    }
    println("lists closed ${closed_accounts()}")
}

// what only Kotlin checks: what Kotlin code Volt called threw comes out of the call (Volt got a
// stand-in), and what a call can't give or close is refused before anything is given
fun safety() {
    fun failure(f: () -> Unit): String = try {
        f()
        "none"
    } catch (e: IllegalStateException) {
        e.message ?: "?"
    }
    val raised = listOf(
        failure { shout({ throw IllegalStateException("shout") }, "hey") },
        failure { try_twice({ throw IllegalStateException("twice") }, 1) },
        failure {
            describe(object : shape {
                override fun area(): Double = 1.0

                override fun name(): String = throw IllegalStateException("name")

                override fun grow(by: Double) {}
            })
        },
    )
    println("raised ${raised.joinToString(" ")}")
    val a = account.open("ann")
    a.deposit(5)
    var kept: account? = null
    val refused = listOf(
        failure {
            visit(a) {
                a.close()
                0L
            }
        },
        failure { close_all(listOf(a, a)) },
        failure {
            visit(a) {
                kept = it
                0L
            }
            kept!!.get()
        },
    )
    println("refused ${refused.joinToString("; ")}")
    println("kept ${a.owner()} ${a.get()}")
    a.close()
    println("closed ${failure { a.get() }}")
}

fun main() {
    extras()
    println("biggest ${biggest_i32(intArrayOf(3, 9, 4))} ${num(biggest_f64(doubleArrayOf(1.5, 0.5)))}")
    val a = account.open("ann")
    a.deposit(250)
    a.rename("bea")
    var n = a.deposit(50)
    println("account ${a.owner()} $n")
    n = visit(a) { it.deposit(1) }
    println("visit $n get ${a.get()}")
    n = close_account(a)
    println("closed $n ${closed_accounts()}")
    val c = Circle(1.0)
    println(describe(c))
    println("grown ${num(grow_twice(Circle(1.0)))}")
    make_square(2.0).use { sq ->
        sq.grow(1.0)
        println("${sq.name()} ${num(sq.area())} ${describe(sq)}")
    }
    println(shout({ "$it!" }, "hey"))
    print("try ${try_twice(::twice, 1)}")
    try {
        try_twice(::twice, 4)
    } catch (e: bank_error) {
        println(" ${e.name}")
    }
    n = opened_by { owner -> account.open(owner).also { it.deposit(7) } }
    println("opened $n")
    println("closed ${closed_accounts()}")
    doubler().use { d -> greeter().use { hi -> println("${d(21)} ${hi("volt")}") } }
    lists()
    c.close()
    safety()
}
