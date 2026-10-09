// point.c: the code from tests/cgen/point.volt

// area (tests/cgen/point.volt:19)
static int32_t v_area(v_shape s) {
    v_shape* _mp;
    int32_t r;

    _mp = &s;
    switch (_mp->tag) {
    case (uint8_t)0:
        return 0;
        break;
    case (uint8_t)1:
        r = _mp->u.v1;
        return volt_mul_i32(volt_mul_i32(3, r, "tests/cgen/point.volt:22:32"), r, "tests/cgen/point.volt:22:32");
        break;
    default:
        volt_panic("no match arm matched", "tests/cgen/point.volt:20:5");
        break;
    }
}

// add (tests/cgen/point.volt:15)
static v_point v_add(v_point a, v_point b) {
    int32_t _s1;
    int32_t _s2;

    _s1 = volt_add_i32(a.x, b.x, "tests/cgen/point.volt:16:17");
    _s2 = volt_add_i32(a.y, b.y, "tests/cgen/point.volt:16:31");
    return (v_point){ .x = _s1, .y = _s2 };
}

// main (tests/cgen/point.volt:26)
static int32_t v_main(void) {
    v_point p;
    int32_t total;
    int32_t _lo;
    int32_t _hi;
    int32_t _it;
    int32_t i;
    int32_t shown;

    p = v_add((v_point){ .x = 1, .y = 2 }, (v_point){ .x = 3, .y = 4 });
    total = 0;
    _lo = 0;
    _hi = 3;
    if (_lo < _hi) {
        _it = _lo;
        for (;;) {
            i = _it;
            total = volt_add_i32(total, i, "tests/cgen/point.volt:30:9");
            if (_it == ((int32_t)((uint32_t)_hi - (uint32_t)1))) {
                goto volt_l3;
            }
            _it = (int32_t)((uint32_t)_it + (uint32_t)1);
        }
    }
    volt_l3:;
    shown = (total > 2) ? total : 0;
    if (total > 2) {
        volt_ext_printf("%d %d %d %d\n", p.x, p.y, v_area((v_shape){ .tag = (uint8_t)1, .u.v1 = 2 }), shown);
    } else {
        volt_ext_printf("small\n");
    }
    return 0;
}

// the C entry point: runs main (tests/cgen/point.volt:26)
int main(int argc, char **argv) {
    volt_argc = argc;
    volt_argv = argv;
    return (int32_t)v_main();
}

