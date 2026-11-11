/* Chromium-HaikuOS: __cxa_thread_atexit for thread_local objects with
 * destructors. Haiku's libroot does not provide it and Chromium's
 * libc++abi build leaves it out on this target. Destructors registered on
 * a thread run (newest first) when that thread exits, through a pthread
 * key destructor. As with libc++abi's fallback, destructors registered on
 * the main thread are not run at process exit. */
#include <pthread.h>
#include <stdlib.h>

typedef void (*haiku_tls_dtor_fn)(void*);

struct haiku_tls_dtor {
    haiku_tls_dtor_fn fn;
    void* obj;
    struct haiku_tls_dtor* next;
};

static pthread_key_t g_key;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void run_dtors(void* p)
{
    struct haiku_tls_dtor* n = (struct haiku_tls_dtor*)p;
    while (n != NULL) {
        struct haiku_tls_dtor* next = n->next;
        n->fn(n->obj);
        free(n);
        n = next;
    }
}

static void make_key(void)
{
    pthread_key_create(&g_key, run_dtors);
}

__attribute__((visibility("default")))
int __cxa_thread_atexit(haiku_tls_dtor_fn fn, void* obj, void* dso_symbol)
{
    (void)dso_symbol;
    pthread_once(&g_once, make_key);
    struct haiku_tls_dtor* n = (struct haiku_tls_dtor*)malloc(sizeof(*n));
    if (n == NULL)
        return -1;
    n->fn = fn;
    n->obj = obj;
    n->next = (struct haiku_tls_dtor*)pthread_getspecific(g_key);
    if (pthread_setspecific(g_key, n) != 0) {
        free(n);
        return -1;
    }
    return 0;
}
