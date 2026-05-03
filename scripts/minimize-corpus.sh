#!/bin/bash
# Clone rust-lightning, build every fuzz target the same way the upstream
# fuzz CI does, and run honggfuzz in minimization mode (`-M`) over each
# target's corpus. The minimized corpus is written back into
# `$CORPUS_DIR/rust-lightning/<target>/` so the caller can commit it.

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

# Mirror the dependency pins ci-fuzz.sh expects on Rust 1.63.
cargo update -p regex --precise "1.9.6"
cargo update -p syn --precise "2.0.106"
cargo update -p quote --precise "1.0.41"
(
    cd write-seeds
    cargo update -p regex --precise "1.9.6"
    cargo update -p syn --precise "2.0.106"
    cargo update -p quote --precise "1.0.41"
)

# Regenerate the message and target files exactly the way ci-fuzz.sh does.
(
    cd src/msg_targets
    rm msg_*.rs
    ./gen_target.sh
)
(
    cd src/bin
    rm ./*_target.rs
    ./gen_target.sh
)

export RUSTFLAGS="--cfg=secp256k1_fuzz --cfg=hashes_fuzz"

# Bootstrap full_stack with the deterministic seeds write-seeds produces.
mkdir -p hfuzz_workspace/full_stack_target/input
(
    cd write-seeds
    RUSTFLAGS="$RUSTFLAGS --cfg=fuzzing" \
        cargo run ../hfuzz_workspace/full_stack_target/input
    cargo clean
)

cargo install --color always --force honggfuzz --no-default-features

# ci-fuzz.sh disables LTO before building to speed things up; do the same.
sed -i 's/lto = true//' Cargo.toml
export HFUZZ_BUILD_ARGS="--features honggfuzz_fuzz"
cargo --color always hfuzz build -j8

CRASHED_TARGETS=()

for TARGET_FILE in src/bin/*_target.rs; do
    BASENAME=$(basename "$TARGET_FILE" .rs)        # e.g. chanmon_consistency_target
    NAME="${BASENAME%_target}"                     # e.g. chanmon_consistency
    INPUT_DIR="hfuzz_workspace/${BASENAME}/input"
    SRC_CORPUS="${CORPUS_DIR}/rust-lightning/${NAME}"

    echo "::group::Minimizing ${NAME}"
    mkdir -p "$INPUT_DIR" "$SRC_CORPUS"

    # Seed honggfuzz's input dir from the persistent corpus. Skip the
    # .gitkeep marker we use to keep empty target folders in tree.
    find "$SRC_CORPUS" -mindepth 1 -maxdepth 1 -type f ! -name '.gitkeep' \
        -exec cp -a {} "$INPUT_DIR"/ \;

    # If there's nothing to minimize, skip the run — honggfuzz with `-M`
    # over an empty corpus has no work to do and may exit non-zero.
    if [ -z "$(find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]; then
        echo "Empty corpus for ${NAME}; skipping."
        : > "$SRC_CORPUS/.gitkeep"
        echo "::endgroup::"
        continue
    fi

    # `-M` makes honggfuzz drop inputs that don't add unique coverage. It
    # processes the existing corpus once and exits.
    HFUZZ_RUN_ARGS="-M --exit_upon_crash -v -n8" \
        cargo --color always hfuzz run "$BASENAME" || true

    if [ -f "hfuzz_workspace/${BASENAME}/HONGGFUZZ.REPORT.TXT" ]; then
        echo "Crash during minimization of ${NAME}:"
        cat "hfuzz_workspace/${BASENAME}/HONGGFUZZ.REPORT.TXT"
        for CASE in hfuzz_workspace/"${BASENAME}"/SIG*; do
            [ -f "$CASE" ] || continue
            xxd -p "$CASE"
        done
        CRASHED_TARGETS+=("$NAME")
        echo "::endgroup::"
        continue
    fi

    # Replace the corpus contents with the minimized set. Wipe everything
    # except .gitkeep, then sync the minimized inputs over.
    find "$SRC_CORPUS" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' \
        -exec rm -rf {} +
    find "$INPUT_DIR" -mindepth 1 -maxdepth 1 -type f \
        -exec cp -a {} "$SRC_CORPUS"/ \;

    # If the directory is now empty, keep .gitkeep so the folder survives in
    # git. If it has content, drop .gitkeep — it's just clutter at that point.
    if [ -z "$(find "$SRC_CORPUS" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' -print -quit)" ]; then
        : > "$SRC_CORPUS/.gitkeep"
    else
        rm -f "$SRC_CORPUS/.gitkeep"
    fi

    echo "::endgroup::"
done

if [ ${#CRASHED_TARGETS[@]} -gt 0 ]; then
    echo "Minimization crashed on: ${CRASHED_TARGETS[*]}"
    exit 1
fi

echo "Minimization complete."
