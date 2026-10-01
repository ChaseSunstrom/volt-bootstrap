// runtime.c: the runtime (allocator, arguments), defined once in each program
/* Volt runtime definitions: emitted in exactly one C unit per program (see prelude.h). */
/* Allocation for libraries (std::mem binds it with @intrinsic). Debug builds add a header so double/invalid frees panic
   (freed blocks are overwritten with 0xDD, so a use after free reads garbage, and sit in a small
   quarantine before really being freed) and count live
   allocations for --leak-check. */
#ifdef VOLT_DEBUG_ALLOC
size_t volt_live_allocs;
typedef struct { uint64_t magic, size; } volt_hdr;
#define VOLT_LIVE 0x766f6c746c697665ULL
#define VOLT_DEAD 0x766f6c7464656164ULL
static volt_hdr *volt_quarantine[256];
static size_t volt_q_next;
static volt_hdr *volt_hdr_of(void *p, const char *what) {
    volt_hdr *h = (volt_hdr *)p - 1;
    if (h->magic != VOLT_LIVE) volt_panic(h->magic == VOLT_DEAD ? "double free" : what, "<allocator>");
    return h;
}
void *volt_rt_malloc(size_t n) {
    volt_hdr *h = volt_malloc(sizeof(volt_hdr) + n);
    if (!h) return 0;
    h->magic = VOLT_LIVE;
    h->size = n;
    volt_live_allocs++;
    return h + 1;
}
void volt_rt_free(void *p) {
    if (!p) return;
    volt_hdr *h = volt_hdr_of(p, "free of memory the runtime didn't allocate");
    h->magic = VOLT_DEAD;
    volt_memset(h + 1, 0xDD, h->size); /* a read after free sees 0xDD bytes, not the old value */
    volt_live_allocs--;
    if (volt_quarantine[volt_q_next]) volt_free(volt_quarantine[volt_q_next]);
    volt_quarantine[volt_q_next] = h;
    volt_q_next = (volt_q_next + 1) % 256;
}
void *volt_rt_realloc(void *p, size_t n) {
    if (!p) return volt_rt_malloc(n);
    volt_hdr *h = volt_hdr_of(p, "realloc of memory the runtime didn't allocate");
    volt_hdr *nh = volt_realloc(h, sizeof(volt_hdr) + n);
    if (!nh) return 0;
    nh->size = n;
    return nh + 1;
}
#else
size_t volt_live_allocs;
void *volt_rt_malloc(size_t n) { return volt_malloc(n); }
void volt_rt_free(void *p) { volt_free(p); }
void *volt_rt_realloc(void *p, size_t n) { return volt_realloc(p, n); }
#endif
int volt_argc;
char **volt_argv;
int volt_rt_argc(void) { return volt_argc; }
volt_str volt_rt_arg(int i) { return (volt_str){ (const uint8_t *)volt_argv[i], volt_strlen(volt_argv[i]) }; }
