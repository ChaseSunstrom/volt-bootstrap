// what the C compiler lays out: Volt's matching structs must agree (layout_i386.volt)
struct c_wide {
    char a;
    long long b;
};

struct c_dbl {
    char a;
    double b;
    int c;
};
