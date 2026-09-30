// ---------- types ----------

typedef struct v_shape v_shape;
typedef struct v_point v_point;

struct v_shape {
    uint8_t tag;
    union {
        int32_t v1;
    } u;
};

struct v_point {
    int32_t x;
    int32_t y;
};

// ---------- functions ----------

static int32_t v_main(void);
static v_point v_add(v_point, v_point);
static int32_t v_area(v_shape);
int32_t volt_ext_printf(const char*, ...) VOLT_SYM("printf");
