/* _BitInt members (c_bitint.volt): the smallest Volt integer of N bits or more, at C's offsets */
struct bits {
    unsigned _BitInt(24) u24;
    _BitInt(12) s12;
    int after;
};

static inline long bits_sum(const struct bits *b) { return (long)b->u24 + (long)b->s12 + b->after; }
