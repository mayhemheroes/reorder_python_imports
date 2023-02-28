#!/usr/bin/env python3

import atheris
import sys
import fuzz_helpers
import random

with atheris.instrument_imports(include=['reorder_python_imports']):
    import reorder_python_imports as r

def TestOneInput(data):
    fdp = fuzz_helpers.EnhancedFuzzedDataProvider(data)
    tpl = fuzz_helpers.build_fuzz_tuple(fdp, [str])
    st = fuzz_helpers.build_fuzz_set(fdp, [tuple, str])
    try:
        r.fix_file_contents(fdp.ConsumeRemainingString(), to_add=tpl, to_remove=st, to_replace=tpl)
    except (SyntaxError, ValueError):
        return -1
    except KeyError:
        if random.random() > .99:
            raise
        return -1

def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
