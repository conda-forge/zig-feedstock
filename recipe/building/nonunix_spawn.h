#ifndef ZIG_NONUNIX_SPAWN_H
#define ZIG_NONUNIX_SPAWN_H

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>

/* _spawnv joins strings with spaces; unlike execv it does not encode argv.
 * Quote each argument using the Microsoft CRT backslash/quote rules.
 * https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments
 */
static char *zig_quote_nonunix_arg(const char *arg) {
    size_t len = strlen(arg);
    if (len > (SIZE_MAX - 3) / 2) {
        errno = ENOMEM;
        return NULL;
    }
    char *out = malloc(2 * len + 3);
    if (!out) return NULL;
    char *dst = out;
    *dst++ = '"';
    while (*arg) {
        size_t slashes = 0;
        while (*arg == '\\') { slashes++; arg++; }
        size_t escaped = (*arg == '"' || *arg == '\0') ? 2 * slashes : slashes;
        while (escaped--) *dst++ = '\\';
        if (*arg == '"') *dst++ = '\\';
        if (*arg) *dst++ = *arg++;
    }
    *dst++ = '"';
    *dst = '\0';
    return out;
}

static int zig_spawn_wait(const char *path, const char *const *argv) {
    size_t count = 0;
    while (argv[count]) count++;
    char **quoted = calloc(count + 1, sizeof(*quoted));
    if (!quoted) return -1;
    size_t i;
    for (i = 0; i < count; i++) {
        quoted[i] = zig_quote_nonunix_arg(argv[i]);
        if (!quoted[i]) break;
    }
    int ret = i == count ? (int)_spawnv(_P_WAIT, path, (const char *const *)quoted) : -1;
    int saved_errno = errno;
    for (size_t j = 0; j < i; j++) free(quoted[j]);
    free(quoted);
    errno = saved_errno;
    return ret;
}
#endif
