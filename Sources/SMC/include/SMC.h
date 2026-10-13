#pragma once
#include <stdbool.h>

/// Opens a connection to AppleSMC. Only reads are ever issued on it.
bool smc_open(void);
void smc_close(void);

/// Reads a four-character key of type 'flt '. Returns false if the key is
/// missing or has another type.
bool smc_read_float(const char *key, float *value);
