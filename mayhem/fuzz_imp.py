#!/usr/bin/env python3
"""Atheris fuzz harness for reorder-python-imports.

Feeds arbitrary fuzzer-generated Python source through fix_file_contents (the
library's core entry point: partition_source -> parse_imports ->
replace_imports -> remove_duplicated_imports -> apply_import_sorting), plus
fuzzer-derived to_add / to_remove / to_replace arguments, so libFuzzer reaches
the real tokenizer/parser/sorting code paths.

The library raises SyntaxError / ValueError for malformed source or malformed
import specs — those are expected, defined errors, not defects, so we catch
them and keep exploring. Any other exception is a genuine unexpected defect;
we re-raise it only ~1% of the time (matching the original fuzz-imp harness)
so the corpus can keep growing instead of re-crashing on every mutation.
"""

import os
import random
import sys

# The module under test is a single root-level module (reorder_python_imports.py at the repo
# root); make it importable regardless of the launcher's cwd.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import atheris

import fuzz_helpers

with atheris.instrument_imports(include=['reorder_python_imports']):
    import reorder_python_imports as r


@atheris.instrument_func
def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    try:
        to_add = fuzz_helpers.build_fuzz_tuple(fdp, [str])
        to_remove = fuzz_helpers.build_fuzz_set(fdp, [tuple, str])
        to_replace = r.Replacements.make([])
        r.fix_file_contents(
            fdp.ConsumeRemainingString(),
            to_add=to_add,
            to_remove=to_remove,
            to_replace=to_replace,
        )
    except (SyntaxError, ValueError):
        return
    except KeyError:
        return
    except Exception:
        # A genuine, unexpected defect. Re-raise it occasionally so it surfaces
        # as a Mayhem POV, while suppressing most hits so the corpus keeps
        # growing (re-raising on every hit would stall exploration).
        if random.random() > .99:
            raise
        return


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == '__main__':
    main()
