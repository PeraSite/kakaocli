#include "KakaoRecovery.h"
#include <CommonCrypto/CommonDigest.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
    uint8_t target[64];
    uint64_t max_id;
    double deadline;
    _Atomic uint64_t next;
    _Atomic uint64_t found;
    _Atomic bool cancelled;
} search_context;

static double monotonic_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}

static int decimal(uint64_t value, char *buffer) {
    char reversed[24]; int n = 0;
    do { reversed[n++] = (char)('0' + value % 10); value /= 10; } while (value);
    for (int i = 0; i < n; i++) buffer[i] = reversed[n - i - 1];
    return n;
}

static void *search_worker(void *data) {
    search_context *ctx = data;
    const uint64_t block = 500000;
    char text[24]; uint8_t digest[64];
    while (!atomic_load(&ctx->cancelled) && atomic_load(&ctx->found) == UINT64_MAX) {
        uint64_t start = atomic_fetch_add(&ctx->next, block);
        if (start >= ctx->max_id) break;
        uint64_t end = ctx->max_id - start < block ? ctx->max_id : start + block;
        for (uint64_t i = start; i < end; i++) {
            if ((i & 0xfff) == 0 && (atomic_load(&ctx->cancelled) ||
                atomic_load(&ctx->found) != UINT64_MAX || monotonic_seconds() >= ctx->deadline)) return NULL;
            int length = decimal(i, text);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            CC_SHA512(text, (CC_LONG)length, digest);
#pragma clang diagnostic pop
            if (memcmp(digest, ctx->target, 64) == 0) {
                atomic_store(&ctx->found, i);
                return NULL;
            }
        }
    }
    return NULL;
}

int kakao_recover_user_id(const uint8_t target[64], uint64_t max_id,
                         unsigned workers, double timeout_seconds, uint64_t *result) {
    if (!target || !result || !max_id || max_id > 100000000000ULL ||
        !workers || workers > 64 || timeout_seconds <= 0 || timeout_seconds > 86400) return -1;
    search_context ctx;
    memcpy(ctx.target, target, 64);
    ctx.max_id = max_id; ctx.deadline = monotonic_seconds() + timeout_seconds;
    atomic_init(&ctx.next, 0); atomic_init(&ctx.found, UINT64_MAX); atomic_init(&ctx.cancelled, false);
    pthread_t *pool = calloc(workers, sizeof(pthread_t));
    if (!pool) return -1;
    unsigned created = 0;
    for (; created < workers; created++) {
        if (pthread_create(&pool[created], NULL, search_worker, &ctx)) {
            atomic_store(&ctx.cancelled, true); break;
        }
    }
    for (unsigned i = 0; i < created; i++) pthread_join(pool[i], NULL);
    free(pool);
    if (created != workers) return -1;
    uint64_t found = atomic_load(&ctx.found);
    if (found == UINT64_MAX) return 0;
    *result = found;
    return 1;
}
