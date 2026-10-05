#ifndef KAKAO_RECOVERY_H
#define KAKAO_RECOVERY_H
#include <stdint.h>
/* 1: found, 0: exhausted or timed out, -1: invalid input / thread failure. */
int kakao_recover_user_id(const uint8_t target[64], uint64_t max_id,
                         unsigned workers, double timeout_seconds, uint64_t *result);
#endif
