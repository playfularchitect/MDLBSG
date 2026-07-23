<div align="center">

# MDLBSG Compressor

**An experimental custom compression application for macOS.**

It can compress files and folders, restore .mdl archives, and queue additional work while another job is already running.

<br>

![Status](https://img.shields.io/badge/status-experimental-orange)
![Platform](https://img.shields.io/badge/platform-macOS-black?logo=apple&logoColor=white)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-black?logo=apple&logoColor=white)
![Benchmark](https://img.shields.io/badge/benchmark-enwik9-green)

</div>

> [!NOTE]
> This is an early public release.

## Current Release

**MDLBSG Compressor v0.1 Public Beta**  
Internal build: **App 91**

See the [release notes](docs/releases/v0.1.0.md) for the tested behavior, current limitations, package name, and checksum.

---

## Why I Built It

I built MDLBSG because I was curious about creating my own custom compressor.

I used the 1,000,000,000-byte `enwik9` dataset as the main benchmark while I was developing and testing the compression system.

---

## What It Has Been Tested On

Development and testing have primarily been done on:

- macOS
- Apple Silicon
- The full 1,000,000,000-byte `enwik9` dataset
- Regular files in my Downloads folder
- Folders
- Compression followed by exact restoration
- Multiple files submitted through the live queue

The tested compression paths restore the original data exactly.

> [!WARNING]
> **Fair warning:** This does not mean every possible file, folder, archive, or Mac configuration has been tested, as I have not done extensive testing outside of my own environment.

---

## Technical Details and Measured Results

A reproducible public benchmark was recorded on **July 23, 2026** using:

- **Mac:** MacBook Pro (`MacBookPro17,1`)
- **Processor:** Apple M1
- **Memory:** 8 GiB physical RAM
- **macOS:** 15.2 (`24C101`)
- **Mode:** Turbo
- **Threads:** 4 performance-core threads
- **Configured compressor memory budget:** 4 GiB
- **Cache:** Disabled
- **Low Power Mode:** Off
- **Power source during the run:** Battery

The 4 GiB value is the compressor's configured memory budget, not a macOS-enforced hard ceiling. Process-tree RAM was sampled every 0.10 seconds.

| Corpus | Files | Encoder input | Archive | Smaller | Core compression time | Speed | Peak compression RAM | Exact restore |
|---|---:|---:|---:|---:|---:|---:|---:|:---:|
| `enwik9` | 1 | 1,000,000,000 B | 182,914,445 B | 81.71% | 303.392 s | 3.14 MiB/s | 1.52 GiB | YES |
| `corpus_hf_wikitext` | 8 | 201,426,432 B | 41,912,702 B | 79.19% | 69.190 s | 2.78 MiB/s | 1.84 GiB | YES |
| `corpus_hf_gsm8k` | 6 | 5,524,480 B | 966,166 B | 82.51% | 3.689 s | 1.43 MiB/s | 1.47 GiB | YES |
| `corpus_hf_dolly` | 6 | 14,016,512 B | 2,659,610 B | 81.03% | 7.119 s | 1.88 MiB/s | 1.56 GiB | YES |
| `corpus_hf_code_cc0` | 6 | 134,310,400 B | 7,991,022 B | 94.05% | 31.343 s | 4.09 MiB/s | 1.79 GiB | YES |

All five restored outputs matched deterministic source content-and-path manifests exactly.

The highest sampled compression RAM was **1.84 GiB** on `corpus_hf_wikitext`. The highest sampled process-tree RAM across compression and restoration was **2.16 GiB** during `enwik9` restoration.

For folders, **Encoder input** is the deterministic tar bundle passed to the compressor. The downloadable corpus folders preserve their pinned Hugging Face source revision, dataset card, license materials, construction policy, and SHA-256 manifest.

- [Download the licensed benchmark corpora](https://github.com/playfularchitect/MDLBSG/releases/tag/corpora-v1.0.0)
- [Inspect the full reproducible evidence](benchmarks/runs/2026-07-23-m1-app91-hf-licensed/BENCHMARK_RESULTS.md)

---\n\n## What It Currently Does

### Compress files and folders

Files and folders can be dragged onto MDLBSG Compressor or selected through the application menu.

### Restore MDLBSG archives

MDLBSG archives can be dropped onto the application, or double clicked, to restore their original contents.

### Queue multiple jobs

When another item is submitted while a job is already running, it is added to a single live queue.

Only one job runs at a time. The next queued item begins after the current one finishes.

### Choose a compression mode

The application menu allows the active compression mode to be changed.

> [!IMPORTANT]
> I recommend using the Turbo version only for this release, as the other versions have not been tested extensively.

### Optional cache

The plaintext cache is disabled by default.

It can be enabled, disabled, or cleared through **Cache Settings** in the application menu.

---

## Installation

1. Download the latest release ZIP from the GitHub **Releases** page.
2. Extract the ZIP.
3. Open the extracted folder.
4. Run:

```text
RUN_ME_FIRST.command
```

5. Follow the instructions shown in Terminal.

> [!NOTE]
> The current installer may require Apple Command Line Tools because parts of the compressor are built locally during installation.

---

## How to Use It

### Open the menu

Open **MDLBSG Compressor** normally to access the main menu.

From there, you can:

- Choose files
- Choose a folder
- Change the compression mode
- Manage the optional cache
- Quit the application

### Compress something

Drag a file or folder onto **MDLBSG Compressor**.

The application will open a progress window and create the compressed archive.

### Restore something

Drag a supported MDLBSG archive onto **MDLBSG Compressor**, or double click the `.mdl` archive that appears in your Downloads folder.

The application will restore the contents of the archive.

### Queue more work

You can drag another file, folder, or archive onto the application while a job is already running.

The new item will wait and begin automatically after the active job finishes.

---

## Current Limitations

MDLBSG Compressor is still experimental.

Current limitations include:

- It has primarily been tested on Apple Silicon Macs.
- It is not currently notarized by Apple.
- Installation may require Apple Command Line Tools.
- Performance and compression results depend on the input.
- Damaged or unusual archives may not always produce ideal error messages.
- The interface, archive format, and installation process may change in future releases.

> [!CAUTION]
> Keep original copies of important files until you have restored and checked the compressed archive yourself.
