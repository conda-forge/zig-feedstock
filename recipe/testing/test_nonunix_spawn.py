"""Compile the shared argument encoder and check CRT-compatible quoting."""
# NOTE: not wired into recipe.yaml yet - needs a C compiler and zig_impl build 1.
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', help='Native Zig executable (otherwise use cc)')
    args = parser.parse_args()
    cases = ['', 'plain', 'two words', 'tab\tvalue', 'a "quoted" value',
             'C:\\Program Files\\', 'backslash\\" and space',
             'two\\\\" and space', 'trailing space \\', '&|<>^%']
    expected = [subprocess.list2cmdline([value]) for value in cases]
    # The encoder deliberately quotes even whitespace-free arguments.
    expected[1] = '"plain"'
    expected[-1] = '"&|<>^%"'
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'process.h').write_text(
            '#define _P_WAIT 0\n'
            'static int _spawnv(int m, const char *p, const char *const *a) '
            '{ (void)m; (void)p; (void)a; return 0; }\n')
        rows = ',\n'.join('{' + json.dumps(value) + ',' + json.dumps(want) + '}'
                            for value, want in zip(cases, expected))
        source = root / 'quote.c'
        source.write_text('''#include <assert.h>
#include "nonunix_spawn.h"
int main(void) {
    const char *cases[][2] = {
''' + rows + '''};
    for (size_t i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        char *actual = zig_quote_nonunix_arg(cases[i][0]);
        assert(actual && strcmp(actual, cases[i][1]) == 0);
        free(actual);
    }
    const char *argv[] = {"program", "two words", "", NULL};
    assert(zig_spawn_wait("program", argv) == 0);
    return 0;
}
''')
        binary = root / 'quote.exe'
        compiler = [args.zig, 'cc'] if args.zig else ['cc']
        subprocess.run([*compiler, '-Wall', '-Wextra', '-Werror', '-I' + str(root),
                        '-I' + str(Path(__file__).resolve().parents[1] / 'building'),
                        str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    print('PASS: Windows argument quoting (10 cases)')


if __name__ == '__main__':
    main()
