"""Check shim execution targets without executing a foreign compiler."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

RECIPE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('activation', RECIPE / 'install_zig_activation.py')
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)


class NonunixShimTargetTests(unittest.TestCase):
    def test_execution_architecture_is_not_codegen_architecture(self):
        for cross, on_target, codegen, native, expected in [
            (False, True, 'aarch64', 'x86_64', 'aarch64-windows-gnu'),
            (True, False, 'aarch64', 'x86_64', None),
            (True, True, 'x86_64', 'aarch64', 'aarch64-windows-gnu'),
            (True, True, 'x86', 'aarch64', 'aarch64-windows-gnu'),
            (False, False, 'x86_64', 'x86_64', None),
        ]:
            with self.subTest(cross=cross, codegen=codegen, expected=expected), tempfile.TemporaryDirectory() as tmp:
                env = {
                    'PREFIX': tmp, 'RECIPE_DIR': str(RECIPE),
                    'CROSS_COMPILER': str(cross), 'SHIM_RUNS_ON_TARGET': str(on_target),
                    'SHIM_ZIG_TRIPLET': 'aarch64-windows-gnu',
                    'ZIG_TRIPLET': codegen + '-windows-msvc',
                    'CONDA_TRIPLET': ('i686' if codegen == 'x86' else codegen) + '-w64-mingw32',
                    'NATIVE_TRIPLET': native + '-w64-mingw32',
                    'NATIVE_ZIG_TRIPLET': native + '-windows-gnu',
                }
                with patch.dict(os.environ, env, clear=True), patch.object(activation, '_compile_c_shim') as compile_shim:
                    activation.main()
                self.assertEqual(compile_shim.call_count, 17 if cross else 8)
                for call in compile_shim.call_args_list:
                    self.assertEqual(call.kwargs['target'], expected)


if __name__ == '__main__':
    unittest.main()
