package geo

import kotlin.math.sqrt

const val LIMIT = 10
const val NAME = "geometry"
const val RATIO = 1.5

/** a point: its properties are plain, so Volt has it by value */
data class Point(val x: Double, val y: Double) {
    fun length(): Double = sqrt(x * x + y * y)

    fun scaled(k: Double): Point = Point(x * k, y * k)

    companion object {
        fun origin(): Point = Point(0.0, 0.0)
    }
}

fun distance(a: Point, b: Point): Double = (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)

enum class Color {
    RED,
    GREEN,
    BLUE;

    fun next(): Color = entries[(ordinal + 1) % entries.size]

    fun title(): String = name.lowercase()
}

data class Pixel(val at: Point, val color: Color)

fun brighten(p: Pixel): Pixel = Pixel(Point(p.at.x + 1.0, p.at.y), Color.RED)

fun greet(name: String, times: Int): String = List(times) { "hi $name" }.joinToString(", ")

/* a block comment /* nested */ with "a quote" and fun inside */
private fun hidden(): Int = 1
