// runtime.c: the runtime (allocator, arguments), defined once in each program
/* Volt runtime definitions: emitted in exactly one C unit per program (see prelude.h). */
/* Threads, one OS layer per platform. volt_rt_thread_start runs job's first word, a void (*)(void *job),
   on a new thread, and volt_rt_thread_join waits for it to finish. volt_rt_wait sleeps while *word ==
   expected (it may return early too, so callers check again); volt_rt_wake wakes one or all sleepers on
   word. Libraries build locks and condition variables over a plain 32-bit word with these. */
#if defined(_WIN32)
#if defined(__i386__) || defined(_M_IX86)
#define VOLT_WINAPI(n, bytes) __asm__("_" n "@" #bytes)
#else
#define VOLT_WINAPI(n, bytes) __asm__(n)
#endif
void *__stdcall volt_CreateThread(void *, size_t, unsigned long(__stdcall *)(void *), void *, unsigned long, unsigned long *) VOLT_WINAPI("CreateThread", 24);
unsigned long __stdcall volt_WaitForSingleObject(void *, unsigned long) VOLT_WINAPI("WaitForSingleObject", 8);
int __stdcall volt_CloseHandle(void *) VOLT_WINAPI("CloseHandle", 4);
int __stdcall volt_SwitchToThread(void) VOLT_WINAPI("SwitchToThread", 0);
static unsigned long __stdcall volt_thread_main(void *job) {
    (*(void (**)(void *))job)(job);
    return 0;
}
int volt_rt_thread_start(void *job, uint64_t *handle) {
    void *h = volt_CreateThread(0, 0, volt_thread_main, job, 0, 0);
    if (!h) return -1;
    *handle = (uint64_t)(uintptr_t)h;
    return 0;
}
void volt_rt_thread_join(uint64_t handle) {
    volt_WaitForSingleObject((void *)(uintptr_t)handle, 0xFFFFFFFFu);
    volt_CloseHandle((void *)(uintptr_t)handle);
}
void volt_rt_thread_yield(void) { volt_SwitchToThread(); }
void *__stdcall volt_LoadLibraryA(const char *) VOLT_WINAPI("LoadLibraryA", 4);
void *__stdcall volt_GetProcAddress(void *, const char *) VOLT_WINAPI("GetProcAddress", 8);
/* WaitOnAddress and WakeByAddress* (Windows 8 on) are looked up, not linked: MinGW would need
   -lsynchronization for them. Where they're missing, waiting yields instead */
typedef int(__stdcall *volt_wait_fn)(volatile void *, void *, size_t, unsigned long);
typedef void(__stdcall *volt_wake_fn)(void *);
static struct { volt_wait_fn wait; volt_wake_fn wake_one, wake_all; } volt_synch;
static int32_t volt_synch_state; /* 0 not looked up, 1 looked up */
static void volt_synch_init(void) {
    if (__atomic_load_n(&volt_synch_state, __ATOMIC_ACQUIRE)) return;
    void *m = volt_LoadLibraryA("api-ms-win-core-synch-l1-2-0.dll");
    void *w = m ? volt_GetProcAddress(m, "WaitOnAddress") : 0;
    void *one = m ? volt_GetProcAddress(m, "WakeByAddressSingle") : 0;
    void *all = m ? volt_GetProcAddress(m, "WakeByAddressAll") : 0;
    if (w && one && all) { /* all or none: a wait with no wake would sleep forever */
        __atomic_store_n(&volt_synch.wait, (volt_wait_fn)w, __ATOMIC_RELAXED);
        __atomic_store_n(&volt_synch.wake_one, (volt_wake_fn)one, __ATOMIC_RELAXED);
        __atomic_store_n(&volt_synch.wake_all, (volt_wake_fn)all, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&volt_synch_state, 1, __ATOMIC_RELEASE);
}
void volt_rt_wait(int32_t *word, int32_t expected) {
    volt_synch_init();
    volt_wait_fn f = __atomic_load_n(&volt_synch.wait, __ATOMIC_RELAXED);
    if (f) f(word, &expected, 4, 0xFFFFFFFFu);
    else volt_SwitchToThread();
}
void volt_rt_wake(int32_t *word, bool all) {
    volt_synch_init();
    volt_wake_fn f = all ? __atomic_load_n(&volt_synch.wake_all, __ATOMIC_RELAXED) : __atomic_load_n(&volt_synch.wake_one, __ATOMIC_RELAXED);
    if (f) f(word);
}
#else
/* pthread_t is a pointer-sized integer or a pointer everywhere this runs */
int volt_pthread_create(uintptr_t *, const void *, void *(*)(void *), void *) VOLT_SYM("pthread_create");
int volt_pthread_join(uintptr_t, void **) VOLT_SYM("pthread_join");
int volt_sched_yield(void) VOLT_SYM("sched_yield");
static void *volt_thread_main(void *job) {
    (*(void (**)(void *))job)(job);
    return 0;
}
int volt_rt_thread_start(void *job, uint64_t *handle) {
    uintptr_t t;
    if (volt_pthread_create(&t, 0, volt_thread_main, job)) return -1;
    *handle = t;
    return 0;
}
void volt_rt_thread_join(uint64_t handle) { volt_pthread_join((uintptr_t)handle, 0); }
void volt_rt_thread_yield(void) { volt_sched_yield(); }
#if defined(__APPLE__)
/* the ulock calls behind libc++'s atomic wait: UL_COMPARE_AND_WAIT | ULF_NO_ERRNO, ULF_WAKE_ALL */
int volt_ulock_wait(uint32_t, void *, uint64_t, uint32_t) VOLT_SYM("__ulock_wait");
int volt_ulock_wake(uint32_t, void *, uint64_t) VOLT_SYM("__ulock_wake");
void volt_rt_wait(int32_t *word, int32_t expected) { volt_ulock_wait(0x01000001u, word, (uint32_t)expected, 0); }
void volt_rt_wake(int32_t *word, bool all) { volt_ulock_wake(0x01000001u | (all ? 0x100u : 0u), word, 0); }
#elif defined(__linux__) && (defined(__x86_64__) || defined(__i386__) || defined(__aarch64__) || defined(__arm__) || defined(__riscv))
/* futex(word, FUTEX_WAIT_PRIVATE / FUTEX_WAKE_PRIVATE, ...) */
long volt_syscall(long, ...) VOLT_SYM("syscall");
#if defined(__x86_64__)
#define VOLT_SYS_FUTEX 202L
#elif defined(__i386__) || defined(__arm__)
#define VOLT_SYS_FUTEX 240L
#else
#define VOLT_SYS_FUTEX 98L
#endif
void volt_rt_wait(int32_t *word, int32_t expected) { volt_syscall(VOLT_SYS_FUTEX, word, 128L, (long)expected, (void *)0); }
void volt_rt_wake(int32_t *word, bool all) { volt_syscall(VOLT_SYS_FUTEX, word, 129L, all ? 0x7fffffffL : 1L); }
#else
/* ponytail: other systems sleep by yielding (correct, but it spins); give them a futex-like call when one matters */
void volt_rt_wait(int32_t *word, int32_t expected) { (void)word; (void)expected; volt_sched_yield(); }
void volt_rt_wake(int32_t *word, bool all) { (void)word; (void)all; }
#endif
#endif
/* a lock on a word: 0 free, 1 held, 2 held and someone may be sleeping on it */
static void volt_lock_word(int32_t *w) {
    int32_t free = 0;
    if (__atomic_compare_exchange_n(w, &free, 1, false, __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) return;
    while (__atomic_exchange_n(w, 2, __ATOMIC_ACQUIRE) != 0) volt_rt_wait(w, 2);
}
static void volt_unlock_word(int32_t *w) {
    if (__atomic_exchange_n(w, 0, __ATOMIC_RELEASE) == 2) volt_rt_wake(w, false);
}
/* A print statement holds the program's streams for all of its output, so lines from different threads
   don't mix. The holder may take it again (printing a value can print). */
static int32_t volt_out_word;
static void *volt_out_owner;
static int volt_out_depth;
static _Thread_local char volt_out_me;
#ifdef VOLT_C_STDOUT
void volt_flockfile(void *) VOLT_SYM("flockfile");
void volt_funlockfile(void *) VOLT_SYM("funlockfile");
#endif
void volt_lock_out(void) {
    if (__atomic_load_n(&volt_out_owner, __ATOMIC_RELAXED) == &volt_out_me) {
        volt_out_depth++;
        return;
    }
    volt_lock_word(&volt_out_word);
#ifdef VOLT_C_STDOUT
    volt_flockfile(volt_c_stdout); /* for volt_to_stdout's unlocked writes */
#endif
    __atomic_store_n(&volt_out_owner, &volt_out_me, __ATOMIC_RELAXED);
    volt_out_depth = 1;
}
void volt_unlock_out(void) {
    if (--volt_out_depth) return;
    __atomic_store_n(&volt_out_owner, (void *)0, __ATOMIC_RELAXED);
#ifdef VOLT_C_STDOUT
    volt_funlockfile(volt_c_stdout);
#endif
    volt_unlock_word(&volt_out_word);
}
/* Allocation for libraries (std::mem binds it with @intrinsic). Debug builds add a header so double/invalid frees panic
   (freed blocks are overwritten with 0xDD, so a use after free reads garbage, and sit in a small
   quarantine before really being freed; realloc always moves, so the same goes for a pointer into a
   block that grew) and count live allocations for --leak-check. */
#ifdef VOLT_DEBUG_ALLOC
size_t volt_live_allocs;
typedef struct { uint64_t magic, size; } volt_hdr;
#define VOLT_LIVE 0x766f6c746c697665ULL
#define VOLT_DEAD 0x766f6c7464656164ULL
static volt_hdr *volt_quarantine[256];
static size_t volt_q_next;
static int32_t volt_q_word; /* guards the quarantine */
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
    __atomic_fetch_add(&volt_live_allocs, 1, __ATOMIC_RELAXED);
    return h + 1;
}
void volt_rt_free(void *p) {
    if (!p) return;
    volt_hdr *h = volt_hdr_of(p, "free of memory the runtime didn't allocate");
    h->magic = VOLT_DEAD;
    volt_memset(h + 1, 0xDD, h->size); /* a read after free sees 0xDD bytes, not the old value */
    __atomic_fetch_sub(&volt_live_allocs, 1, __ATOMIC_RELAXED);
    volt_lock_word(&volt_q_word);
    volt_hdr *old = volt_quarantine[volt_q_next];
    volt_quarantine[volt_q_next] = h;
    volt_q_next = (volt_q_next + 1) % 256;
    volt_unlock_word(&volt_q_word);
    if (old) volt_free(old);
}
void *volt_rt_realloc(void *p, size_t n) {
    if (!p) return volt_rt_malloc(n);
    volt_hdr *h = volt_hdr_of(p, "realloc of memory the runtime didn't allocate");
    /* always a new block, the old one freed (poisoned, quarantined): a pointer still into it reads
       0xDD bytes instead of what happened to be left there */
    void *q = volt_rt_malloc(n);
    if (!q) return 0;
    volt_memcpy(q, p, h->size < n ? h->size : n);
    volt_rt_free(p);
    return q;
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
/* bolt hot's sampler (voltc --profiler builds only; Linux on x86-64 and aarch64). Every 100 us of the
   process's CPU time a SIGPROF records the interrupted pc and the frame-pointer chain above it, and at
   exit the samples go to $VOLT_PROFILE_OUT: "VPROF001", the interval in ns, the number of words, then
   the samples, each its depth and that many addresses (the pc first); then "MAPS", a length and the
   text of /proc/self/maps, so addresses can be named wherever they were loaded (a position-independent
   executable, shared libraries like libc). The chain is only followed on the
   main thread's stack (its bounds read once from /proc/self/maps): code built without frame pointers
   (libc's) leaves anything in the frame register, and a word outside the stack is never read. */
#if defined(VOLT_PROFILE) && defined(__linux__) && (defined(__x86_64__) || defined(__aarch64__))
#include <signal.h>
#include <time.h>
#include <ucontext.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#define VOLT_PROF_WORDS (1u << 22)
#define VOLT_PROF_NS 100000L
static uint64_t volt_prof_buf[VOLT_PROF_WORDS];
static uint64_t volt_prof_n; /* 64-bit: it keeps counting past a full buffer without wrapping */
static uint64_t volt_prof_lo, volt_prof_hi; /* the main thread's stack */
static timer_t volt_prof_timer;
static void volt_prof_tick(int sig, siginfo_t *si, void *ucv) {
    (void)sig;
    (void)si;
    ucontext_t *uc = ucv;
#if defined(__x86_64__)
    uint64_t pc = (uint64_t)uc->uc_mcontext.gregs[16], fp = (uint64_t)uc->uc_mcontext.gregs[10], sp = (uint64_t)uc->uc_mcontext.gregs[15];
#else
    uint64_t pc = uc->uc_mcontext.pc, fp = uc->uc_mcontext.regs[29], sp = uc->uc_mcontext.sp;
#endif
    uint64_t frames[64];
    uint32_t n = 0;
    frames[n++] = pc;
    if (sp >= volt_prof_lo && sp < volt_prof_hi) {
        /* [fp] is the caller's frame pointer and [fp + 8] the return address into it; each frame sits
           higher up the stack than the last */
        uint64_t low = sp;
        while (n < 64 && fp >= low && fp + 16 <= volt_prof_hi && (fp & 7) == 0) {
            uint64_t *f = (uint64_t *)fp;
            if (!f[1]) break;
            frames[n++] = f[1];
            low = fp + 16;
            fp = f[0];
        }
    }
    uint64_t at = __atomic_fetch_add(&volt_prof_n, (uint64_t)n + 1, __ATOMIC_RELAXED);
    if (at + n + 1 > VOLT_PROF_WORDS) return; /* full: later samples are dropped */
    volt_prof_buf[at] = n;
    for (uint32_t i = 0; i < n; i++) volt_prof_buf[at + 1 + i] = frames[i];
}
/* all of buf to fd, through EINTR; whether it all got there */
static int volt_prof_write(int fd, const char *buf, uint64_t len) {
    while (len) {
        ssize_t w = write(fd, buf, len < (1u << 30) ? (size_t)len : (size_t)(1u << 30));
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return 0;
        buf += w;
        len -= (uint64_t)w;
    }
    return 1;
}
/* (a thread caught between reserving its slot and filling it when this runs leaves a zero depth there:
   the samples end at it) */
static void volt_prof_dump(void) {
    timer_delete(volt_prof_timer);
    signal(SIGPROF, SIG_IGN);
    const char *path = getenv("VOLT_PROFILE_OUT");
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    uint64_t words = __atomic_load_n(&volt_prof_n, __ATOMIC_RELAXED);
    if (words > VOLT_PROF_WORDS) words = VOLT_PROF_WORDS;
    /* a sample cut off at the end of the buffer isn't written */
    uint64_t end = 0;
    while (end < words && end + 1 + volt_prof_buf[end] <= words && volt_prof_buf[end]) end += 1 + volt_prof_buf[end];
    uint64_t head[3];
    volt_memcpy(&head[0], "VPROF001", 8);
    head[1] = (uint64_t)VOLT_PROF_NS;
    head[2] = end;
    /* a short file is worse than none: stop at the first failed write (bolt hot says it can't read it) */
    if (!volt_prof_write(fd, (const char *)head, sizeof head) || !volt_prof_write(fd, (const char *)volt_prof_buf, end * 8)) {
        close(fd);
        return;
    }
    static char maps[1 << 18];
    uint64_t ml = 0;
    int mf = open("/proc/self/maps", O_RDONLY);
    if (mf >= 0) {
        ssize_t r;
        while (ml < sizeof maps && (r = read(mf, maps + ml, sizeof maps - ml)) > 0) ml += (uint64_t)r;
        close(mf);
    }
    uint64_t mh[2];
    volt_memcpy(&mh[0], "MAPS\0\0\0\0", 8);
    mh[1] = ml;
    if (volt_prof_write(fd, (const char *)mh, sizeof mh)) volt_prof_write(fd, maps, ml);
    close(fd);
}
__attribute__((constructor)) static void volt_prof_start(void) {
    if (!getenv("VOLT_PROFILE_OUT")) return;
    /* the main thread's stack: the [stack] line of /proc/self/maps */
    char maps[1 << 16];
    int fd = open("/proc/self/maps", O_RDONLY);
    ssize_t len = fd < 0 ? 0 : read(fd, maps, sizeof maps - 1);
    if (fd >= 0) close(fd);
    maps[len > 0 ? len : 0] = 0;
    for (char *line = maps; *line;) {
        char *nl = line;
        while (*nl && *nl != '\n') nl++;
        int is_stack = 0;
        for (char *c = line; c + 6 < nl; c++) {
            if (volt_memcmp(c, "[stack]", 7) == 0) is_stack = 1;
        }
        if (is_stack) {
            volt_prof_lo = strtoull(line, &line, 16);
            volt_prof_hi = strtoull(line + 1, 0, 16);
            break;
        }
        line = *nl ? nl + 1 : nl;
    }
    struct sigaction sa;
    volt_memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = volt_prof_tick;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGPROF, &sa, 0);
    struct sigevent ev;
    volt_memset(&ev, 0, sizeof ev);
    ev.sigev_notify = SIGEV_SIGNAL;
    ev.sigev_signo = SIGPROF;
    if (timer_create(CLOCK_PROCESS_CPUTIME_ID, &ev, &volt_prof_timer) != 0) return;
    struct itimerspec every = { { 0, VOLT_PROF_NS }, { 0, VOLT_PROF_NS } };
    timer_settime(volt_prof_timer, 0, &every, 0);
    atexit(volt_prof_dump);
}
#endif
