MDLBSG v0.1 license-preserving Hugging Face corpus benchmark evidence

This directory records:
- the exact benchmark script and its SHA-256;
- the macOS/M1 environment without hardware serial numbers;
- hashes of the installed MDLBSG wrapper, cores, handlers, app plist, and app script;
- deterministic source and restored manifests;
- raw compression/restoration logs;
- sampled process-tree memory measurements;
- CSV, JSONL, and GitHub-ready Markdown results.

Configured compressor memory budget: 4 GiB.
This is the budget passed to the compressor, not a macOS-enforced hard ceiling.

Original enwik9 and licensed Hugging Face corpus folders are never modified.\nEach folder includes its pinned source revision, dataset card, licenses, and checksums.
