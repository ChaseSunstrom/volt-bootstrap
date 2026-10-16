/* streams reached through a function, as UCRT's stdout is: #define stdout (__acrt_iob_func(1)) */
struct counter { int n; };
static struct counter volt_counters[3] = { { 10 }, { 20 }, { 30 } };
static struct counter *__counter_at(unsigned i) { return &volt_counters[i]; }
#define first_counter (__counter_at(0))
#define third_counter __counter_at(2)
/* not one call: left out */
#define both_counters (__counter_at(0)->n + __counter_at(1)->n)
