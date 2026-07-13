#!/usr/bin/env bash
#
# mayhem/build.sh — build the reorder-python-imports Atheris fuzz harness + its standalone
# reproducer, and prepare the project's own test suite. Runs inside the commit image
# (mayhem/Dockerfile) as `mayhem` in /mayhem. Python adaptation of the C/C++ template.
#
# What it does (must be idempotent + air-gapped on re-run — SPEC §6.2 item 9 / §6.5):
#   1. Populate / reuse an in-image wheelhouse under /opt/toolchains/python (HOME-independent),
#      then install atheris + classify-imports + the test deps OFFLINE from that wheelhouse into
#      a fixed site dir on PYTHONPATH. The first (CI, online) build fills the wheelhouse; the
#      air-gapped PATCH re-run resolves entirely from it (pip --no-index --find-links).
#   2. Compile launcher.c -> the ELF Mayhem target `fuzz_imp` (Atheris is a Python script; Mayhem
#      needs an ELF cmd, and the gate needs DWARF < 4 — hence a compiled wrapper).
#   3. Build the same launcher as the standalone (run-once) reproducer `fuzz_imp-standalone`.
#   4. Compile run_tests.c -> `reorder_run_tests`, the NON-system ELF wrapper test.sh runs the
#      suite through (so the anti-reward-hack sabotage check bites — SPEC §6.3).
#
# reorder_python_imports itself is a pure-Python single-module project (reorder_python_imports.py
# at the repo root) kept as the editable source tree — we expose it via PYTHONPATH (=/mayhem), so
# a PATCH agent's edits take effect with no reinstall. Everything here is ADDITIVE — the harness
# only CALLS the module, never edits it.
#
# The base image exports the build contract (CC, SANITIZER_FLAGS, DEBUG_FLAGS, ...). For a Python
# target we only need DEBUG_FLAGS here: the launcher is a thin C exec wrapper, so building it with
# $SANITIZER_FLAGS would just instrument the wrapper, NOT the fuzzed Python — Atheris instruments
# the reorder_python_imports module itself at import time (with atheris.instrument_imports), which
# is where coverage actually comes from. The default SANITIZER_FLAGS (ASan+UBSan, halting) still
# flows through the image ENV and governs Atheris's native libFuzzer runtime.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export DEBUG_FLAGS CC MAYHEM_JOBS

SRC="${SRC:-/mayhem}"
cd "$SRC"

# ── Python toolchain caches at a FIXED, $HOME-independent prefix (SPEC §6.2 item 8) ──
PY_PREFIX=/opt/toolchains/python
WHEELHOUSE="$PY_PREFIX/wheelhouse"
export PYTHONUSERBASE="$PY_PREFIX/user"
mkdir -p "$WHEELHOUSE" "$PYTHONUSERBASE"

PY="$(command -v python3)"

# 1) Wheelhouse: download every runtime/test dependency ONCE (online). On the air-gapped re-run
#    the directory is already populated, so pip never reaches the network. classify-imports is the
#    module's sole runtime dependency; pytest runs the suite; covdefaults+coverage complete the
#    project's requirements-dev.txt.
PKGS=(atheris pytest classify-imports covdefaults coverage)
need_download=0
"$PY" -c "import os,glob,sys; sys.exit(0 if glob.glob(os.path.join('$WHEELHOUSE','atheris-*.whl')) else 1)" || need_download=1
if [ "$need_download" -eq 1 ]; then
  echo ">> populating wheelhouse (online) at $WHEELHOUSE"
  "$PY" -m pip download --dest "$WHEELHOUSE" "${PKGS[@]}"
else
  echo ">> wheelhouse already populated — reusing $WHEELHOUSE (air-gapped re-run path)"
fi

# 2) Install the deps into the fixed site dir, OFFLINE from the wheelhouse. --no-index +
#    --find-links guarantees no PyPI access (works on the air-gapped re-run). Guarded to be
#    idempotent: once the site dir holds atheris+pytest we SKIP the reinstall.
# NOTE: user-site (PYTHONUSERBASE), NOT --target + PYTHONPATH — the project warns on stderr when
# $PYTHONPATH is set, which breaks its own suite's output assertions.
if "$PY" -c 'import atheris, pytest, classify_imports' 2>/dev/null; then
  echo ">> deps already installed in $PYTHONUSERBASE — skipping (idempotent re-run)"
else
  echo ">> installing deps (offline) into $PYTHONUSERBASE"
  # --break-system-packages: PEP 668 marks the base's python externally-managed; installs go to
  # our own PYTHONUSERBASE user-site, not the distro site-packages, so this is safe.
  "$PY" -m pip install --no-index --find-links="$WHEELHOUSE" --user --break-system-packages "${PKGS[@]}"
fi

# Record the user base + interpreter for test.sh to consume.
cat > "$PY_PREFIX/env.sh" <<EOF
export PYTHONUSERBASE="$PYTHONUSERBASE"
export PYTHON_BIN="$PY"
EOF

# Sanity: the harness imports must resolve offline now (repo root on sys.path via cwd for -c).
(cd "$SRC" && "$PY" -c 'import atheris, pytest; import reorder_python_imports; print("imports OK")')

# 3) Compile the ELF launcher target + the standalone reproducer (DWARF < 4 via $DEBUG_FLAGS).
#    The launcher execs $PY on the harness; PYTHONPATH is baked into the env the binary inherits
#    at run time (the Dockerfile sets ENV PYTHONPATH), so the Python side finds atheris + the module.
HARNESS="$SRC/mayhem/fuzz_imp.py"
echo ">> compiling fuzz_imp (+ standalone) with DEBUG_FLAGS=$DEBUG_FLAGS"
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz_imp"
# The standalone reproducer is the same launcher: libFuzzer runs a single input file once when the
# harness is given a file path (no fuzzing loop) — exactly the run-once reproducer contract.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" -DHARNESS="\"$HARNESS\"" \
    "$SRC/mayhem/launcher.c" -o "$SRC/fuzz_imp-standalone"

# 4) The pytest oracle runs through a compiled NON-system ELF wrapper so the gate's
#    anti-reward-hack sabotage check (which neuters non-system binaries to exit(0)) actually bites
#    the suite — a test.sh that shelled straight to /usr/bin python would be spared.
$CC $DEBUG_FLAGS -DPYTHON="\"$PY\"" "$SRC/mayhem/run_tests.c" -o "$SRC/reorder_run_tests"

echo ">> build.sh complete"
ls -la "$SRC/fuzz_imp" "$SRC/fuzz_imp-standalone" "$SRC/reorder_run_tests"
