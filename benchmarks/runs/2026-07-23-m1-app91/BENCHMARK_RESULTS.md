# MDLBSG v0.1 Reproducible Benchmark Results

Run ID: `MDLBSG_BENCHMARK_EVIDENCE_2026-07-23_004505Z`  
Benchmark script SHA-256: `b227fe4f71209bc4aa4cf363186837a22fada978e4ce5f400ee8893ac2899f48`  
Configured compressor memory budget: `4 GiB`

> Peak RAM below is the highest sampled total RSS of the benchmark command and its descendant processes. It is measured every 0.10 seconds; it is not a kernel-enforced hard limit.

| Corpus | Type | Files | Encoder input | Archive | Smaller | Core time | Speed | Sampled peak RAM | Exact restore |
|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| enwik9 | file | 1 | 1,000,000,000 B | 182,914,445 B | 81.71% | 301.926 s | 3.16 MiB/s | 1.42 GiB | YES |
| corpus_game | folder | 1,703 | 227,555,328 B | 166,429,735 B | 26.86% | 75.134 s | 2.89 MiB/s | 1.66 GiB | YES |
| corpus_json | folder | 2 | 189,788,160 B | 11,557,116 B | 93.91% | 34.948 s | 5.18 MiB/s | 1.78 GiB | YES |
| corpus_sealed | folder | 5 | 45,871,616 B | 42,124,476 B | 8.17% | 7.183 s | 6.09 MiB/s | 1.16 GiB | YES |
| corpus_code | folder | 6,282 | 162,274,304 B | 13,489,866 B | 91.69% | 40.029 s | 3.87 MiB/s | 1.59 GiB | YES |

## Notes

- Turbo mode is used for every compression run.
- Cache is disabled during compression and restoration so restoration exercises the decoder.
- For folders, `Encoder input` is the tar bundle actually passed into the compressor. Source logical bytes and deterministic tree hashes are retained in `results.jsonl` and `RESULTS.csv`.
- Exact restoration means the deterministic content-and-path manifest SHA-256 matched before and after restoration.
- Timing can vary across nominally identical Macs because of temperature, power state, background work, and storage performance.

## Recorded Environment

```text
run_id: MDLBSG_BENCHMARK_EVIDENCE_2026-07-23_004505Z
run_started_utc: 2026-07-23T00:45:05Z
benchmark_script_sha256: b227fe4f71209bc4aa4cf363186837a22fada978e4ce5f400ee8893ac2899f48
installed_app_version: 91
benchmark_mode: turbo
configured_memory_budget_gb: 4
memory_budget_rule: half of physical RAM, minimum 2 GiB
memory_limit_kind: compressor budget/guard, not an operating-system hard cap
memory_measurement: sampled process-tree RSS every 0.10s
cache_during_run: off
cache_state_before_run: off

macOS_product_name: macOS
macOS_product_version: 15.2
macOS_build_version: 24C101
kernel_release: 24.2.0
architecture: arm64
hardware_model: MacBookPro17,1
cpu_brand: Apple M1
physical_memory_bytes: 8589934592
logical_cpu_count: 8
performance_core_logical_count: 4
performance_core_physical_count: 4
low_power_mode: 0
power_source: 'Battery Power'
source_volume_free_space: 2.6Gi

mdlbsg_version_output:
  wrapper: threads=4 (performance cores) mem_budget=4GB
  built: 2026-07-22 07:02:07
  app_version: App 82 (TRUE-DETACH RC1)
  package_marker: MDLBSG_APP_82_TRUE_DETACH_2026_07_21
  installer_path: ~/Downloads/MDLBSG_App_85_FRESH_PROGRESS_WRAPPER_2026-07-22/INSTALL_MDLBSG.command
  compressor_source: ~/Downloads/MDLBSG_App_85_FRESH_PROGRESS_WRAPPER_2026-07-22/MDLBSG_CompressorWindow.applescript
  compressor_source_sha256: 2c17ae0d397bb1e70d2657dccd3d6ae6f19d7fe26b76cb7af3443709dea749a0
  installed_app: /Applications/MDLBSG Compressor.app
  compiled_main_scpt_sha256: 526306903595cdb8602d7d395344690cacb69eb8c041286f746aa3d13b4816b4
  decompiled_results_dialog_count: 1
  staged_equals_installed: YES
  transient_ui: detached launcher helper
  results_detach: native double-fork launcher
  transient_app_quit: YES
  detached_launcher_selftest: PASS
  progress_owner: transient Compressor app (forced quit after handoff)
  compressor_bundle_id: com.mdlbsg.compressor
  decompressor_bundle_id: com.mdlbsg.decompressor
  core_src_sha256: d3411c532481c399d4caf6edcaa3cb2cf7422dbe032d9be7e427da686203c93b
  turbo_src_sha256: 72208457bf6f7002054fa4669a5c57c5b2f6dbe95f338bad4fb076de23ba6b5b
run_finished_utc: 2026-07-23T01:01:51Z
```
