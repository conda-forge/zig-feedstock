/* Spike repro for the win-64 native OCaml crash (0xC0000005 in caml_try_realloc_stack).
 *
 * Models the crash shape WITHOUT OCaml:
 *   - deep non-tail recursion (frames accumulate toward the guard page)
 *   - a >4KB stack frame per call (forces the Win64 __chkstk stack probe)
 *   - a __thread read every frame (models caml_get_domain_state() TLS access)
 *
 * Discriminator: a CORRECT Win64 probe faults at the guard page as
 * EXCEPTION_STACK_OVERFLOW (0xC00000FD), which a handler can see. A missing/incorrect
 * probe steps past the guard into an unmapped page and faults as
 * EXCEPTION_ACCESS_VIOLATION (0xC0000005), bypassing the stack-overflow handler --
 * exactly the 0xC0000005 seen in OCaml. The VEH prints which one arrives.
 *
 * SetThreadStackGuarantee reserves room so the VEH can run on overflow (as OCaml does).
 */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

/* models caml_get_domain_state(): one TLS slot read per frame */
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
    return EXCEPTION_CONTINUE_SEARCH; /* let it terminate; we only want the label */
}

/* >4KB volatile frame, touched at both ends so it is materialized and probed */
static uintptr_t recurse(int depth) {
    volatile char buf[8192];
    buf[0] = (char)depth;
    buf[sizeof(buf) - 1] = (char)(depth >> 8);
    uintptr_t s = tls_domain_state + (uintptr_t)buf[0] + (uintptr_t)buf[sizeof(buf) - 1];
    if (depth <= 0) return s;
    return s ^ recurse(depth - 1); /* non-tail: frames accumulate */
}

int main(int argc, char **argv) {
    ULONG guarantee = 65536;
    SetThreadStackGuarantee(&guarantee);
    AddVectoredExceptionHandler(1, veh);
    int depth = (argc > 1) ? atoi(argv[1]) : 100000;
    fprintf(stderr, "depth=%d frame~=%zu bytes\n", depth, (size_t)8192);
    fflush(stderr);
    uintptr_t r = recurse(depth);
    printf("SURVIVED r=%p (no fault at this depth)\n", (void *)r);
    return 0;
}
