#!/bin/bash
# Clone rust-lightning, pre-seed honggfuzz's input directories from the
# persistent corpus, run rust-lightning's own `ci-fuzz.sh` with
# `FUZZ_MINIMIZE=true` (which fuzzes each target then runs honggfuzz `-M`
# to drop inputs that don't contribute coverage), and sync the resulting
# minimized inputs back into `$CORPUS_DIR/rust-lightning/<target>/`. The
# caller is responsible for committing+pushing the result.
#
# Delegating to the upstream ci-fuzz.sh keeps us in lock-step with the
# canonical build configuration — including its split into the
# `fuzz-fake-hashes` and `fuzz-real-hashes` subcrates and any future
# refactors — so we don't have to maintain a parallel build pipeline.

set -euxo pipefail

CORPUS_DIR="${CORPUS_DIR:?CORPUS_DIR must be set to the corpus repo root}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
RUST_LIGHTNING_URL="${RUST_LIGHTNING_URL:-https://github.com/lightningdevkit/rust-lightning}"
RUST_LIGHTNING_REF="${RUST_LIGHTNING_REF:-master}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Always start from a fresh clone so the build mirrors the canonical
# rust-lightning state at run time.
rm -rf rust-lightning
git clone --depth=1 --branch "$RUST_LIGHTNING_REF" "$RUST_LIGHTNING_URL"
cd rust-lightning/fuzz

# Pre-seed each target's honggfuzz input dir from the persistent corpus.
# `ci-fuzz.sh` will create new `hfuzz_workspace/<name>_target/input/`
# directories for any target we don't pre-seed.
for D in "$CORPUS_DIR"/rust-lightning/*/; do
    NAME=$(basename "$D")
    DST="hfuzz_workspace/${NAME}_target/input"
    mkdir -p "$DST"
    find "$D" -mindepth 1 -maxdepth 1 -type f ! -name '.gitkeep' \
        -exec cp -a {} "$DST"/ \;
done

# Run the upstream CI script with minimization enabled. It builds the fuzz
# subcrates, fuzzes each target, then re-runs honggfuzz with `-M` to drop
# redundant corpus entries.
export FUZZ_MINIMIZE=true
CI_FAILED=0
./ci-fuzz.sh || CI_FAILED=$?

# Sync the (possibly minimized) inputs back into the persistent corpus, even
# if ci-fuzz.sh failed partway — completed targets are still useful and
# crashing inputs are stored as `SIG*` outside `input/`, so we won't pick
# them up here.
for INPUT_DIR in hfuzz_workspace/*/input; do
    [ -d "$INPUT_DIR" ] || continue
    BASENAME=$(basename "$(dirname "$INPUT_DIR")")    # e.g. chanmon_consistency_target
    NAME="${BASENAME%_target}"                        # e.g. chanmon_consistency
    DST="$CORPUS_DIR/rust-lightning/$NAME"

    mkdir -p "$DST"
    # Wipe the corpus folder so files dropped during minimization actually
    # disappear, then copy the minimized set in.
    find "$DST" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -exec rm -rf {} +
    find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type f \
        -exec cp -a {} "$DST"/ \;

    # Keep `.gitkeep` only when the folder is empty.
    if [ -z "$(find "$DST" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -print -quit)" ]; then
        : > "$DST/.gitkeep"
    else
        rm -f "$DST/.gitkeep"
    fi
done

if [ "$CI_FAILED" -ne 0 ]; then
    echo "ci-fuzz.sh exited $CI_FAILED — corpus updated with whatever finished"
    exit "$CI_FAILED"
fi

echo "Minimization complete."
