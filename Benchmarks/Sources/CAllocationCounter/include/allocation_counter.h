#ifndef FLIGHT_ALLOCATION_COUNTER_H
#define FLIGHT_ALLOCATION_COUNTER_H

#include <stdint.h>

/// Whether allocations can be counted on this platform.
int flight_allocations_supported(void);

/// Starts counting allocations made by the calling thread.
void flight_allocations_begin(void);

/// Stops counting and returns how many were made since `begin`.
uint64_t flight_allocations_end(void);

#endif
