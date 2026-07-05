/* wrapper_utils.h - shared string utilities for zig-wrapper.c and cross-zig-shim.c
 *
 * Keep this header minimal: only functions that are truly shared between
 * multiple translation units belong here. File-local helpers stay in their
 * respective .c files.
 */
#ifndef WRAPPER_UTILS_H
#define WRAPPER_UTILS_H

#include <string.h>

static inline int str_eq(const char *a, const char *b) { return strcmp(a, b) == 0; }

#endif /* WRAPPER_UTILS_H */
