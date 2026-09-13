#!/usr/bin/env bash
# Per-repo build script. Runs paideia-as build over every .pdx source.
#
# Resolves paideia-as via (in order):
#   1. $PAIDEIA_AS env var
#   2. paideia-os checkout sibling to this repo: ../paideia-os/tools/paideia-as/target/release/paideia-as
#   3. $HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as
#   4. paideia-as on $PATH (must be >= 0.21.0)
#
# Requires paideia-as >= 0.21.0. The 0.9.0 shipped in $PATH by default does not
# accept the syntax used in this repo.
#
# rm.ENH-010 (paideia-os/rm#24): tests/ modules are compiled into a
# distinct rm-tests target under build-out/rm-tests/ (separate from the
# shipped build-out/rm/*.o), and the tests/ *.pdx modules are compiled
# alongside src/ *.pdx so the RmElevateSmoke / RmGolden regression
# harnesses can call into the src modules without a linker step
# (paideia-as build --emit elf64 emits one .o per .pdx; the harness runs
# via the QEMU smoke matrix's per-tool invocation, not via a link).
#
# Modes:
#   bash tools/build.sh          -> ship build (build-out/*.o from src/)
#                                    plus syntax-check compile of tests/*.pdx
#                                    (default; preserves pre-ENH-010 behaviour)
#   bash tools/build.sh --tests  -> rm-tests target: build-out/rm-tests/*.o
#                                    from BOTH src/ and tests/, so the M4
#                                    regression harnesses (RmElevateSmoke,
#                                    RmGolden) are the compiled shape that
#                                    ships alongside a signed release for
#                                    the QEMU smoke matrix's rm-tests entry.

set -euo pipefail
cd "$(dirname "$0")/.."

MIN_VERSION="0.21.0"

resolve_paideia_as() {
    if [ -n "${PAIDEIA_AS:-}" ] && [ -x "$PAIDEIA_AS" ]; then
        echo "$PAIDEIA_AS"; return
    fi
    for cand in \
        "../paideia-os/tools/paideia-as/target/release/paideia-as" \
        "$HOME/Development/PaideiaOS/tools/paideia-as/target/release/paideia-as"
    do
        if [ -x "$cand" ]; then
            echo "$cand"; return
        fi
    done
    if command -v paideia-as >/dev/null 2>&1; then
        command -v paideia-as; return
    fi
    return 1
}

version_ge() {
    # $1 = have, $2 = want ; returns 0 if have >= want
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

MODE="ship"
for arg in "$@"; do
    case "$arg" in
        --tests) MODE="tests" ;;
        --ship)  MODE="ship"  ;;
        *)
            echo "[build] FAIL: unknown arg '$arg' (expected --tests|--ship)" >&2
            exit 2
            ;;
    esac
done

PA="$(resolve_paideia_as || true)"
if [ -z "$PA" ]; then
    echo "[build] FAIL: paideia-as not found. Set PAIDEIA_AS or clone paideia-os as a sibling." >&2
    exit 2
fi
VER="$("$PA" --version | awk '{print $2}')"
if ! version_ge "$VER" "$MIN_VERSION"; then
    echo "[build] FAIL: paideia-as $VER is too old, need >= $MIN_VERSION (found $PA)" >&2
    exit 2
fi
echo "[build] paideia-as $VER at $PA (mode=$MODE)"

if [ "$MODE" = "tests" ]; then
    BUILD_DIR="build-out/rm-tests"
else
    BUILD_DIR="build-out"
fi
mkdir -p "$BUILD_DIR"

FAIL=0
COUNT=0
for pdx in src/*.pdx; do
    [ -f "$pdx" ] || continue
    COUNT=$((COUNT + 1))
    obj="$BUILD_DIR/$(basename "$pdx" .pdx).o"
    if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
        FAIL=$((FAIL + 1))
    fi
done

if [ -d tests ]; then
    for pdx in tests/*.pdx; do
        [ -f "$pdx" ] || continue
        COUNT=$((COUNT + 1))
        if [ "$MODE" = "tests" ]; then
            obj="$BUILD_DIR/$(basename "$pdx" .pdx).o"
        else
            obj="$BUILD_DIR/tests-$(basename "$pdx" .pdx).o"
        fi
        if ! "$PA" build --emit elf64 "$pdx" -o "$obj" 2>&1; then
            FAIL=$((FAIL + 1))
        fi
    done
fi

echo "[build] $COUNT source(s), $FAIL failure(s)"
[ "$FAIL" -eq 0 ] || exit 1
echo "[build] OK"
