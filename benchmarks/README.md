# MDLBSG Benchmarks

This directory contains reproducible benchmark evidence for published MDLBSG results.

## Runs

- [2026-07-23 — Apple M1, App 91, Turbo mode](runs/2026-07-23-m1-app91/BENCHMARK_RESULTS.md)

- [2026-07-23 — Apple M1, App 91, licensed Hugging Face corpus suite](runs/2026-07-23-m1-app91-hf-licensed/BENCHMARK_RESULTS.md)\n\n## What the evidence records

Each run can include:

- the benchmark runner and its SHA-256;
- macOS and hardware environment information;
- hashes of the installed wrapper, compression cores, handlers, app plist, and compiled app script;
- exact corpus and archive hashes;
- raw compression and restoration logs;
- sampled process-tree memory measurements;
- deterministic source and restored file-tree manifests;
- CSV, JSONL, and Markdown summaries.

## App and compression-core provenance

The July 23 run recorded the installed macOS app bundle as **App 91**.

The unchanged command-line compression body still reports older App 82/App 85 lineage inside its embedded `BUILD_INFO`. App 91 repaired the application menu and installer layers without rebuilding the protected compression cores. The exact binaries used are identified by SHA-256 in the run evidence.

## Measurement notes

- Turbo mode was used.
- The configured 4 GiB value is a compressor budget/guard, not an operating-system hard cap.
- Process-tree RSS was sampled every 0.10 seconds.
- Cache was disabled.
- Exact restoration required deterministic source and restored manifests to match.
- Timing varies with temperature, storage, power state, and background work.
