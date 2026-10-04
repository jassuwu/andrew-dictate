# Needle engine

The C engine that runs [Whistle](https://huggingface.co/Cactus-Compute/whistle),
Cactus Compute's 16.9 MB speech-to-text model. Apache-2.0 (`LICENSE`), by
Cactus Compute, Inc.

Copied as is from the `macos-arm64` folder of
[Cactus-Compute/needle3](https://huggingface.co/Cactus-Compute/needle3) at
commit `c7c415a3d1b3d929014bc6e866d51ebb971f7089` (engine 3.1.0):

| file | sha-256 |
|---|---|
| `libneedle.a` | `a3b9163abe7b4bd52487c4005506cb35c5163bb9b9587af4ae07ed7587de697d` |
| `include/needle.h` | as published |

`include/module.modulemap` is ours: it lets Swift `import Needle`.

The engine holds one model per kind for the whole process and is not
thread-safe; `WhistleRuntime` is the only caller and takes one call at a
time. The model file itself is not here: it downloads when Whistle is
picked (`ModelFiles`), pinned to a commit and checked against its sha-256.

To move the pin: download the three files at the new commit, replace them,
update the table, and check `needle.h` for changes to `needle_load` and
`needle_transcribe` — the C ABI changed in 3.1.0.
