#include "allocation_counter.h"

#if defined(__linux__) && defined(__GLIBC__)
#include <errno.h>
#include <stddef.h>

// glibc's own entry points, which the wrappers below forward to. Defining
// malloc in the executable interposes it for every shared library too — the
// Swift runtime included — because the dynamic linker resolves the symbol to
// the executable's definition first.
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);

// Thread-local and initial-exec, so reading them never allocates.
static __thread int counting __attribute__((tls_model("initial-exec")));
static __thread uint64_t counted __attribute__((tls_model("initial-exec")));

void *malloc(size_t size) {
    if (counting) counted++;
    return __libc_malloc(size);
}

void *calloc(size_t count, size_t size) {
    if (counting) counted++;
    return __libc_calloc(count, size);
}

void *realloc(void *pointer, size_t size) {
    if (counting) counted++;
    return __libc_realloc(pointer, size);
}

void *aligned_alloc(size_t alignment, size_t size) {
    if (counting) counted++;
    return __libc_memalign(alignment, size);
}

int posix_memalign(void **out, size_t alignment, size_t size) {
    if (counting) counted++;
    void *pointer = __libc_memalign(alignment, size);
    if (pointer == NULL) return ENOMEM;
    *out = pointer;
    return 0;
}

int flight_allocations_supported(void) { return 1; }

void flight_allocations_begin(void) {
    counted = 0;
    counting = 1;
}

uint64_t flight_allocations_end(void) {
    counting = 0;
    return counted;
}

#else

int flight_allocations_supported(void) { return 0; }
void flight_allocations_begin(void) {}
uint64_t flight_allocations_end(void) { return 0; }

#endif
