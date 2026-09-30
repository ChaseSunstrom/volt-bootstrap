#define ANSWER 42
#define SCALE 2.5
#define MASK (1u << 4)
enum color { RED, GREEN = 5, BLUE };
typedef struct { int x; int y; } point;
struct pair { int a; int b; };
static inline int point_sum(point p) { return p.x + p.y; }
static inline void point_scale(point *p, int k) { p->x *= k; p->y *= k; }
static inline int pair_diff(const struct pair *p) { return p->a - p->b; }
struct named { int id; char name[8]; };
static inline int name_len(const struct named *n) { int i = 0; while (n->name[i]) i++; return i; }
