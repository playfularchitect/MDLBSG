<div align="center">

# MDLBSG Compressor

**Experimental lossless compression for macOS, designed to balance small archives, practical speed, and moderate memory use.**

Compress files and folders, restore `.mdl` archives exactly, and queue additional jobs while another job is running.

<br>

![Status](https://img.shields.io/badge/status-experimental-orange)
![Platform](https://img.shields.io/badge/platform-macOS-black?logo=apple&logoColor=white)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-black?logo=apple&logoColor=white)
![Benchmark](https://img.shields.io/badge/enwik9-174.4%20MB-green)
![Full chain](https://img.shields.io/badge/full%20chain-291%20s-blue)
![Restore](https://img.shields.io/badge/restore-byte--exact-brightgreen)

</div>

> [!NOTE]
> MDLBSG is an early public release and an active compression research project. The downloadable public app and the newest private research champion (soon to be public) are described separately below.

## In 10 Seconds

MDLBSG is a lossless compressor: it makes data smaller and can restore every original byte exactly.


On the standard 1,000,000,000 byte `enwik9` Wikipedia benchmark, the newest research engine compressed the file to **174,398,752 bytes in 291 seconds** on an 8 GiB M1 Mac, using about **1.99 GB peak compression RAM**.


That result is not the smallest archive on the historical leaderboard and it is not the fastest compressor. 


Its value is the combination: among **215 listed compressors with complete package size, compression time, and RAM measurements**, none are simultaneously smaller, faster, and lower memory than MDLBSG.

> [!IMPORTANT]
> The **174 MB research champion is not yet the same engine shipped in the v0.1 public app**. The current downloadable release remains App 91, documented below.

---

## Why I Find This Interesting

Compression always trades between three costs:

1. **Final package size** — how many bytes must be stored or transmitted.
2. **Compression time** — how long the work takes.
3. **Peak RAM** — how much memory the machine must provide.

A compressor may create a smaller archive by taking hours or using tens of gigabytes of RAM. Another may finish quickly but leave a much larger file. MDLBSG is being developed around the combined tradeoff rather than one number alone.

### Current research-champion result

| Input | Archive | Full compression chain | Peak compression RAM | Exact restoration |
|---:|---:|---:|---:|:---:|
| 1,000,000,000 B | **174,398,752 B** | **291.005 s** | **1,987.9 MB** | **YES** |


```text
174,398,752-byte archive
+   203,959-byte program package
= 174,602,711-byte final package
```

### Leaderboard context

Using Matt Mahoney's [Large Text Compression Benchmark](http://www.mattmahoney.net/dc/text.html), which supplies the compressor list and historical enwik9 measurements:

- **Size only placement:** approximately **52nd of 218** after including the program package.
- **Complete three metric entries:** **215**.
- **Three way Pareto layer:** **Layer 1**.
- **Compressors that beat MDLBSG on size, time, and RAM simultaneously:** **0**.

“Pareto Layer 1” does not mean MDLBSG wins every individual measurement. It means no listed compressor with complete data is at least as good on all three measurements and strictly better on one.

For example:

| Compressor | Final package | Compression time | RAM | Tradeoff |
|---|---:|---:|---:|---|
| **MDLBSG V20A** | **174,602,711 B** | **291 s** | **1,988 MB** | Balanced research champion |
| `ccmx` | 174,157,106 B | 1,313 s | 1,332 MB | Smaller and lower-memory, but about 4.5× slower |
| `mcomp` | 174,560,882 B | 473 s | 1,643 MB | About 42 KB smaller as a package, but substantially slower |
| `bit` | 174,487,532 B | 2,050 s | 663 MB | Smaller package and less RAM, but about 7× slower |

> [!WARNING]
> Historical leaderboard timings were collected on different computers and in different eras. They are useful for broad tradeoff context, not as a controlled same machine speed race. The Pareto analysis is therefore descriptive, not an official leaderboard category or submission.

---

## How the Research Engine Works

At a high level, the research engine uses two stages:

1. **Representation transform:** common words become compact symbols, allowing later prediction models to see more useful language within the same history window.
2. **Predictive compression:** multiple specialized models estimate what comes next, a learned mixer decides which models to trust, and a range coder spends fewer bits on likely events.

Recent work on the latest private version reduced the word transform stage from roughly three minutes to **13.10 seconds** without changing its output. The improvement came from preserving the same representation while replacing repeated temporary string creation with a more direct counting and lookup body.

The central research goal is straightforward:

> Preserve exact restoration while pushing the combined frontier of archive size, speed, and memory.

---

## Current Public Release

**MDLBSG Compressor v0.1 Public Beta**  
Internal build: **App 91**

See the [release notes](docs/releases/v0.1.0.md) for the tested behavior, current limitations, package name, and checksum.

---

## Why I Built It

I built MDLBSG because I was curious about creating my own custom compressor and understanding prediction, representation, memory, and computation from first principles.

I use the full 1,000,000,000-byte `enwik9` dataset as the main research benchmark because it gives compression programs a shared, difficult test. Every accepted result must restore the original data exactly.

---

## What the Public App Has Been Tested On

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
> This does not mean every possible file, folder, archive, or Mac configuration has been tested. Testing outside my own environment is still limited.

---

## Public App Benchmarks: App 91

A reproducible public-app benchmark was recorded on **July 23, 2026** using:

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
- [Inspect the full reproducible App 91 evidence](benchmarks/runs/2026-07-23-m1-app91-hf-licensed/BENCHMARK_RESULTS.md)

---

## What the Public App Currently Does

### Compress files and folders

Files and folders can be dragged onto MDLBSG Compressor or selected through the application menu.

### Restore MDLBSG archives

MDLBSG archives can be dropped onto the application, or double-clicked, to restore their original contents.

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

Drag a supported MDLBSG archive onto **MDLBSG Compressor**, or double-click the `.mdl` archive that appears in your Downloads folder.

The application will restore the contents of the archive.

### Queue more work

You can drag another file, folder, or archive onto the application while a job is already running.

The new item will wait and begin automatically after the active job finishes.

---

## Current Limitations

MDLBSG Compressor is still experimental.

Current limitations include:

- The newest 174 MB research champion is not yet integrated into the v0.1 public app.
- It has primarily been tested on Apple Silicon Macs.
- It is not currently notarized by Apple.
- Installation may require Apple Command Line Tools.
- Performance and compression results depend on the input.
- Damaged or unusual archives may not always produce ideal error messages.
- The interface, archive format, and installation process may change in future releases.

> [!CAUTION]
> Keep original copies of important files until you have restored and checked the compressed archive yourself.
