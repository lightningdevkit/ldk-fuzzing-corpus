# LDK Fuzzing Corpus

Persistent fuzzing corpus for
[lightningdevkit/rust-lightning](https://github.com/lightningdevkit/rust-lightning).

Each subdirectory of `rust-lightning/` corresponds to one fuzz target, named
after the target's `fuzz/src/bin/<name>_target.rs` file with the `_target`
suffix removed. The contents of each folder are honggfuzz inputs.

## Contributing

Open a pull request adding new corpus inputs to any *existing* fuzz-target
folder under `rust-lightning/`. Automation runs nightly and applies the
following rules. PRs that violate any of them are closed:

- Only **additions** are accepted. Modifications and deletions of existing
  files will close the PR.
- Every added file must live under an **existing** directory. PRs that create
  new top-level folders or new fuzz-target subfolders are closed. (New
  fuzz-target folders are created by maintainers when rust-lightning gains a
  new fuzz target.)
- No file may live under a path component that starts with `.` (e.g.
  `.github/`).
- PRs that conflict with `master` are closed.

PRs that pass all the above are merged automatically.

## Nightly minimization

After PRs are processed, automation:

1. Clones the latest `lightningdevkit/rust-lightning`.
2. Builds every fuzz target with the same configuration as
   `fuzz/ci-fuzz.sh`.
3. Seeds each target's `hfuzz_workspace/<t>_target/input/` from this repo's
   `rust-lightning/<t>/`.
4. Runs `cargo hfuzz run <t>_target` with `HFUZZ_RUN_ARGS="-M …"` so
   honggfuzz drops inputs that don't add unique coverage.
5. Syncs the minimized inputs back into `rust-lightning/<t>/` and pushes a
   single commit to `master`.

If the minimization run trips a crash on a corpus input, the nightly job
fails loudly so the regression can be triaged. The crashing input is left in
place; the cause must be fixed in rust-lightning before nightly will
succeed again.

## Using this corpus locally

```sh
git clone https://github.com/lightningdevkit/ldk-fuzzing-corpus.git
git clone https://github.com/lightningdevkit/rust-lightning.git
cd rust-lightning/fuzz
# (build the fuzz targets per fuzz/README.md, then for each target:)
TARGET=chanmon_consistency
mkdir -p hfuzz_workspace/${TARGET}_target/input
cp ../../ldk-fuzzing-corpus/rust-lightning/${TARGET}/* \
    hfuzz_workspace/${TARGET}_target/input/
cargo hfuzz run ${TARGET}_target
```
