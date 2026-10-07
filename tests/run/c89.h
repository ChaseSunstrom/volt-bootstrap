/* A header written for C89: bool is its own typedef, and a definition is in the old K&R style (both
   errors in C23, and the typedef one in any C with <stdbool.h>) */
typedef int bool;
static int kr_add(a, b)
    int a;
    int b;
{
    return a + b;
}
static bool is_even(int x) { return x % 2 == 0; }
/* no prototype: a caller passes char as int and float as double */
static double kr_mix(c, f)
    char c;
    float f;
{
    return c + f;
}
