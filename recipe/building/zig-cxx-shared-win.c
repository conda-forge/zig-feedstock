/*
 * non-unix DLL linker wrapper: invokes ld.lld directly in MinGW mode.
 *
 * Bypasses zig's c++ driver which force-merges libc++ statically into DLLs.
 * Translates compiler-driver flags into raw linker flags for PE/COFF.
 *
 * Placeholders replaced at install time:
 *   ZIG_TARGET_ARCH - target architecture (e.g. x86_64, aarch64)
 *
 * Compiled during package build with zig cc.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>
#include <windows.h>

#define ZIG_TARGET_ARCH "@ZIG_TARGET_ARCH@"

/* --- PE emulation mode (architecture-dependent) --- */
static const char *get_emulation(void) {
    if (strcmp(ZIG_TARGET_ARCH, "aarch64") == 0)
        return "arm64pe";
    return "i386pep";
}

/* --- Flag classification helpers --- */
static int starts_with(const char *s, const char *prefix) {
    return strncmp(s, prefix, strlen(prefix)) == 0;
}

static int str_eq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

/* Flags that consume the next argument (skip both) */
static int is_skip_with_arg(const char *arg) {
    return str_eq(arg, "-target");
}

/* Flags that are dropped (single arg) */
static int is_drop_flag(const char *arg) {
    return starts_with(arg, "-mcpu=") ||
           str_eq(arg, "-nostdlib++") ||
           starts_with(arg, "-stdlib=") ||
           starts_with(arg, "-f") ||
           starts_with(arg, "-O") ||
           str_eq(arg, "-g") ||
           (starts_with(arg, "-g") && arg[2] >= '0' && arg[2] <= '9') ||
           starts_with(arg, "-D") ||
           starts_with(arg, "-I") ||
           starts_with(arg, "-std=") ||
           str_eq(arg, "-pedantic") ||
           str_eq(arg, "-shared");  /* --shared added explicitly in exec line */
}

/* -W flags: drop all except -Wl,* */
static int is_drop_w_flag(const char *arg) {
    if (!starts_with(arg, "-W"))
        return 0;
    if (starts_with(arg, "-Wl,"))
        return 0;  /* -Wl,* is handled separately */
    return 1;  /* Drop -Werror=*, -Wno-*, -Wall, etc. */
}

/* -Xlinker passthrough flags to drop */
static int is_xlinker_drop(const char *arg) {
    return str_eq(arg, "-Bsymbolic-functions") ||
           str_eq(arg, "-Bsymbolic") ||
           str_eq(arg, "--color-diagnostics") ||
           starts_with(arg, "--dependency-file=");
}

/* --- Find ld.lld --- */
static int find_lld(char *out, size_t out_size) {
    /* 1. Check CONDA_PREFIX\Library\bin\ld.lld.exe */
    const char *conda = getenv("CONDA_PREFIX");
    if (conda && conda[0]) {
        snprintf(out, out_size, "%s\\Library\\bin\\ld.lld.exe", conda);
        if (GetFileAttributesA(out) != INVALID_FILE_ATTRIBUTES)
            return 1;
    }

    /* 2. Search PATH for ld.lld.exe */
    char found[MAX_PATH];
    if (SearchPathA(NULL, "ld.lld.exe", NULL, MAX_PATH, found, NULL)) {
        strncpy(out, found, out_size - 1);
        out[out_size - 1] = '\0';
        return 1;
    }

    /* 3. Search PATH for lld.exe */
    if (SearchPathA(NULL, "lld.exe", NULL, MAX_PATH, found, NULL)) {
        strncpy(out, found, out_size - 1);
        out[out_size - 1] = '\0';
        return 1;
    }

    return 0;
}

/* --- Response file expansion --- */

/* Read entire file into malloc'd buffer. Returns NULL on failure. */
static char *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    if (len < 0 || len > 16 * 1024 * 1024) { /* 16 MB sanity limit */
        fclose(f);
        return NULL;
    }
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t n = fread(buf, 1, (size_t)len, f);
    fclose(f);
    buf[n] = '\0';
    *out_len = n;
    return buf;
}

/*
 * Parse response file content into tokens (MSVC/GCC convention):
 *   - Whitespace-separated tokens
 *   - Double-quoted strings preserve interior whitespace
 *   - Backslash-double-quote is an escaped quote inside double-quotes
 * Returns number of tokens parsed. Tokens are _strdup'd into out[].
 */
static int parse_rsp_tokens(const char *content, const char **out, int max) {
    int count = 0;
    const char *p = content;
    char token[8192];

    while (*p && count < max) {
        /* skip whitespace */
        while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r')
            p++;
        if (!*p) break;

        int ti = 0;
        int in_quote = 0;

        while (*p && ti < (int)sizeof(token) - 1) {
            if (in_quote) {
                if (*p == '\\' && p[1] == '"') {
                    token[ti++] = '"';
                    p += 2;
                } else if (*p == '"') {
                    in_quote = 0;
                    p++;
                } else {
                    token[ti++] = *p++;
                }
            } else {
                if (*p == '"') {
                    in_quote = 1;
                    p++;
                } else if (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
                    break;
                } else {
                    token[ti++] = *p++;
                }
            }
        }

        if (ti > 0) {
            token[ti] = '\0';
            out[count++] = _strdup(token);
        }
    }
    return count;
}

/*
 * Expand argv: replace @file entries with parsed file contents.
 * Returns new argc. Caller must free expanded_argv (but not individual strings
 * from original argv -- only _strdup'd ones from response files).
 */
static int expand_response_files(int argc, char *argv[],
                                  const char ***out_argv) {
    /* Worst case: each @file expands to many args. Start with generous alloc. */
    int capacity = argc * 2 + 4096;
    const char **expanded = malloc(sizeof(char *) * capacity);
    if (!expanded) return -1;

    int ni = 0;
    for (int i = 0; i < argc; i++) {
        if (argv[i][0] == '@' && argv[i][1] != '\0') {
            const char *path = argv[i] + 1;
            size_t flen;
            char *content = read_file(path, &flen);
            if (content) {
                /* Parse tokens from file */
                int space = capacity - ni - (argc - i);
                if (space < 1024) {
                    capacity *= 2;
                    const char **tmp = realloc(expanded, sizeof(char *) * capacity);
                    if (!tmp) { free(content); free(expanded); return -1; }
                    expanded = tmp;
                    space = capacity - ni - (argc - i);
                }
                int n = parse_rsp_tokens(content, expanded + ni, space);
                ni += n;
                free(content);
                continue;
            }
            /* File not found: pass @arg through (LLD will handle or error) */
        }
        if (ni >= capacity - 1) {
            capacity *= 2;
            const char **tmp = realloc(expanded, sizeof(char *) * capacity);
            if (!tmp) { free(expanded); return -1; }
            expanded = tmp;
        }
        expanded[ni++] = argv[i];
    }

    *out_argv = expanded;
    return ni;
}

/* --- Parse -Wl,<comma-separated> into individual args --- */
static int add_wl_args(const char *wl_arg, const char **out, int idx, int max) {
    /* Skip the -Wl, prefix */
    const char *rest = wl_arg + 4;
    char buf[4096];
    strncpy(buf, rest, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *token = strtok(buf, ",");
    while (token && idx < max) {
        if (token[0] != '\0') {
            out[idx++] = _strdup(token);
        }
        token = strtok(NULL, ",");
    }
    return idx;
}

int main(int argc, char *argv[]) {
    /* Expand @response files before flag translation */
    const char **src_argv;
    int src_argc = expand_response_files(argc, argv, &src_argv);
    if (src_argc < 0) {
        fprintf(stderr, "ERROR: zig-cxx-shared: response file expansion failed\n");
        return 1;
    }

    /* Allocate output argv (generous: expanded args + emulation + shared + NULL) */
    int max_args = src_argc * 2 + 16;
    const char **new_argv = malloc(sizeof(char *) * max_args);
    if (!new_argv) {
        fprintf(stderr, "ERROR: zig-cxx-shared: malloc failed\n");
        return 1;
    }

    /* Find linker */
    char lld_path[MAX_PATH];
    if (!find_lld(lld_path, MAX_PATH)) {
        fprintf(stderr, "ERROR: zig-cxx-shared: no linker found (ld.lld.exe / lld.exe)\n");
        free(new_argv);
        return 1;
    }

    /* Build args: lld -m <emulation> --shared <translated flags...> */
    int ni = 0;
    new_argv[ni++] = lld_path;
    new_argv[ni++] = "-m";
    new_argv[ni++] = get_emulation();
    new_argv[ni++] = "--shared";

    int skip_next = 0;
    int grab_next = 0;  /* For -Xlinker: grab next arg as raw linker flag */

    for (int i = 1; i < src_argc && ni < max_args - 1; i++) {
        const char *arg = src_argv[i];

        if (skip_next) {
            skip_next = 0;
            continue;
        }

        if (grab_next) {
            grab_next = 0;
            if (!is_xlinker_drop(arg)) {
                new_argv[ni++] = arg;
            }
            continue;
        }

        if (is_skip_with_arg(arg)) {
            skip_next = 1;
            continue;
        }

        if (is_drop_flag(arg) || is_drop_w_flag(arg)) {
            continue;
        }

        if (str_eq(arg, "-Xlinker")) {
            grab_next = 1;
            continue;
        }

        if (starts_with(arg, "-Wl,")) {
            ni = add_wl_args(arg, new_argv, ni, max_args - 1);
            continue;
        }

        /* Pass through everything else */
        new_argv[ni++] = arg;
    }

    new_argv[ni] = NULL;

    /* Diagnostic: print summary when ZIG_CXX_SHARED_VERBOSE is set */
    const char *verbose = getenv("ZIG_CXX_SHARED_VERBOSE");
    if (verbose && verbose[0]) {
        fprintf(stderr, "[zig-cxx-shared] argc=%d (expanded=%d) -> ni=%d, lld=%s\n",
                argc, src_argc, ni, lld_path);
        /* Print first 20 and last 5 args to avoid flooding */
        for (int j = 0; j < ni && j < 20; j++)
            fprintf(stderr, "  [%d] %s\n", j, new_argv[j]);
        if (ni > 25) {
            fprintf(stderr, "  ... (%d args omitted)\n", ni - 25);
            for (int j = ni - 5; j < ni; j++)
                fprintf(stderr, "  [%d] %s\n", j, new_argv[j]);
        } else if (ni > 20) {
            for (int j = 20; j < ni; j++)
                fprintf(stderr, "  [%d] %s\n", j, new_argv[j]);
        }
        fflush(stderr);
    }

    /* Execute linker */
    int ret = (int)_spawnv(_P_WAIT, lld_path, new_argv);
    free(new_argv);
    free(src_argv);

    if (ret == -1) {
        fprintf(stderr, "ERROR: zig-cxx-shared: failed to exec %s: %s\n",
                lld_path, strerror(errno));
        return 1;
    }
    return ret;
}
