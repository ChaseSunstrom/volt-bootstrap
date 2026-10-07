/* C23: bool, true and nullptr as keywords (no header), constexpr, typeof, [[attributes]] */
constexpr int c23_limit = 10;
[[nodiscard]] static inline int c23_twice(int x) {
    typeof(x) y = x * 2;
    return y;
}
static inline bool c23_ok(void) { return true; }
static inline int *c23_none(void) { return nullptr; }
