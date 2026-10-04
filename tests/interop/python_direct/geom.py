"""Ordinary Python: nothing in it is written for Volt"""
from __future__ import annotations

import enum
import math
from dataclasses import dataclass

VERSION = "1.2"
LIMIT = 10
RATIO = 0.5


class Color(enum.Enum):
    RED = 1
    GREEN = 2
    BLUE = 3


@dataclass
class Point:
    x: float
    y: float

    def norm(self) -> float:
        return math.hypot(self.x, self.y)

    def scale(self, k: float) -> None:
        self.x *= k
        self.y *= k

    @staticmethod
    def origin() -> Point:
        return Point(0.0, 0.0)

    @classmethod
    def parse(cls, s: str) -> Point:
        a, b = s.split(",")
        return cls(float(a), float(b))


class Shape:
    name: str
    color: Color

    def __init__(self, name: str, sides: list[float]):
        self.name = name
        self.sides = list(sides)
        self.color = Color.GREEN

    def perimeter(self) -> float:
        return sum(self.sides)

    def add(self, side: float) -> None:
        self.sides.append(side)

    @property
    def count(self) -> int:
        return len(self.sides)

    def describe(self, prefix: str = "a") -> str:
        return f"{prefix} {self.name} with {self.count} sides"


class Square(Shape):
    def __init__(self, side: float):
        super().__init__("square", [side] * 4)

    def area(self) -> float:
        return self.sides[0] ** 2


def dist(a: Point, b: Point) -> float:
    return math.hypot(a.x - b.x, a.y - b.y)


def add(a: int, b: int = 2) -> int:
    return a + b


def upper(s: str) -> str:
    return s.upper()


def total(xs: list[float]) -> float:
    return sum(xs)


def double_all(xs: list[int]) -> None:
    """changes Volt's array: the change comes back"""
    for i in range(len(xs)):
        xs[i] *= 2


def squares(n: int) -> list[int]:
    return [(i + 1) ** 2 for i in range(n)]


def words(s: str) -> list[str]:
    return s.split()


def join(parts: list[str], sep: str = "-") -> str:
    return sep.join(parts)


def find(xs: list[int], x: int) -> int | None:
    return xs.index(x) if x in xs else None


def next_color(c: Color) -> Color:
    return {Color.RED: Color.GREEN, Color.GREEN: Color.BLUE, Color.BLUE: Color.RED}[c]


def longest(a: Shape, b: Shape) -> Shape:
    return a if a.perimeter() >= b.perimeter() else b


def greet(name: str, *, loud: bool = False) -> str:
    s = f"hello, {name}"
    return s.upper() if loud else s


def checksum(data: bytes) -> int:
    return sum(data)


def divide(a: int, b: int) -> int:
    return a // b


def maybe(name: str) -> Shape | None:
    return None if name == "" else Shape(name, [1.0])


# Volt can't call these: they're listed in a comment of what bolt writes
def apply(f, x: int) -> int:
    return f(x)


def many(*xs: int) -> int:
    return len(xs)
