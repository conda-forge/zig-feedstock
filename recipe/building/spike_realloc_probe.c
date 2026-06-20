/* Build-29 item 3/4 diagnostic probe (runs in Windows CI; Linux host cannot exec win .exe).
 * Models the OCaml caml_try_realloc_stack crash WITHOUT OCaml:
 *   - deep non-tail recursion (frames accumulate toward the guard page)
 *   - a >4KB stack frame per call (forces the Win64 __chkstk stack probe)
 *   - a __thread read each frame (models caml_get_domain_state() TLS)
 *
 * A correct Win64 probe faults at the guard page as EXCEPTION_STACK_OVERFLOW
 * (0xC00000FD); a missing/incorrect probe steps past the guard and faults as
 * EXCEPTION_ACCESS_VIOLATION (0xC0000005), bypassing the stack-overflow handler --
 * exactly the 0xC0000005 seen in OCaml. The VEH prints which one arrives.
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

static __thread volatile uintptr_t tls_domain_state = 0xdeadbeefU;

static LONG CALLBACK veh(PEXCEPTION_POINTERS ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code == EXCEPTION_STACK_OVERFLOW) {
        fprintf(stderr, "[VEH] STACK_OVERFLOW (0xC00000FD): clean guard-page fault -> reserve/item6\n");
    } else if (code == EXCEPTION_ACCESS_VIOLATION) {
        fprintf(stderr, "[VEH] ACCESS_VIOLATION (0xC0000005) at addr %p: probe bypassed guard -> chkstk/item4\n",
                (void *)ep->ExceptionRecord->ExceptionInformation[1]);
    } else {
        fprintf(stderr, "[VEH] code=0x%08lx\n", (unsigned long)code);
    }
    fflush(stderr);
    return EXCEPTION_CONTINUE_SEARCH;
}

/* noinline + optnone keep the recursion genuine under -O2. Without them the optimizer
 * turns this XOR-accumulator (XOR is associative/commutative) into a loop, the stack
 * never grows, and the probe vacuously "SURVIVES" at any depth. The >8KB volatile frame
 * still forces the Win64 __chkstk probe even under optnone (probe emission is a backend
 * decision keyed on frame size > 1 page, independent of the opt level). */
__attribute__((noinline, optnone))
static uintptr_t recurse(int depth) {
    volatile char buf[8192];
    buf[0] = (char)depth;
    buf[sizeof(buf) - 1] = (char)(depth >> 8);
    uintptr_t s = tls_domain_state + (uintptr_t)buf[0] + (uintptr_t)buf[sizeof(buf) - 1];
    if (depth <= 0) return s;
    uintptr_t r = s ^ recurse(depth - 1);
    /* volatile reload of the frame AFTER the recursive call: forces this frame to stay
     * live across the call, defeating any recursion-to-iteration transform. */
    return r ^ (uintptr_t)buf[0];
}

int main(int argc, char **argv) {
    ULONG guarantee = 65536;
    SetThreadStackGuarantee(&guarantee);
    AddVectoredExceptionHandler(1, veh);
    /* Default depth 2000 (~16MB of 8KB frames): overflows the lld-link default 1MB
     * reserve but fits inside a -Wl,--stack,0x4000000 (64MB) reserve, so the two
     * variants give DIFFERENT verdicts and the --stack -> /STACK: fix is observable. */
    int depth = (argc > 1) ? atoi(argv[1]) : 2000;
    fprintf(stderr, "depth=%d frame~=%zu bytes\n", depth, (size_t)8192);
    fflush(stderr);
    uintptr_t r = recurse(depth);
    printf("SURVIVED r=%p (no fault at this depth)\n", (void *)r);
    return 0;
}
