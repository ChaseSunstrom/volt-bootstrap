/* a struct holding a union, as glibc's pthread_mutex_t is (macOS's and Windows' headers have none) */
typedef union { int whole; char bytes[4]; } kept_bits;
typedef struct { kept_bits bits; int count; } kept_lock;
int kept_lock_count(kept_lock *l);
