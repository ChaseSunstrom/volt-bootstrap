/* unions and bitfields, for tests/run/c_union.volt */
typedef union {
    int i;
    float f;
    unsigned char bytes[4];
} number;

union wide {
    long long big;
    short little;
};

struct tagged {
    int kind;
    number value;
    union {
        int code;
        double ratio;
    } extra;
};

struct flags {
    unsigned int ready : 1;
    unsigned int level : 3;
    int delta : 4;
    int count;
};

/* anonymous members: their fields are the outer struct's */
struct point3 {
    struct {
        int x;
        int y;
    };
    int z;
};

struct event {
    int type;
    union {
        int key;
        float x;
    };
};

static inline int point3_sum(struct point3 p) { return p.x + p.y + p.z; }
static inline float number_as_float(number n) { return n.f; }
static inline number number_of_int(int i) { number n; n.i = i; return n; }
static inline long long wide_big(const union wide *w) { return w->big; }
static inline double tagged_ratio(struct tagged t) { return t.extra.ratio; }
static inline int flags_total(const struct flags *f) { return f->ready + f->level + f->delta + f->count; }
