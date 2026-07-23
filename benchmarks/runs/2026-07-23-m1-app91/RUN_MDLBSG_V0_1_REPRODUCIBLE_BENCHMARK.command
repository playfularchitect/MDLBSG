#!/usr/bin/env bash
set -euo pipefail
umask 077

# MDLBSG v0.1 reproducible benchmark evidence runner.
# It never modifies the source corpora. Cache use is disabled only for the run
# and restored to its prior on/off state afterward.

SOURCE_DIR="${1:-$HOME/Downloads}"
MODE="${MDLBSG_BENCHMARK_MODE:-turbo}"
EXPECTED_APP_VERSION="${EXPECTED_APP_VERSION:-91}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
MAX_COMMAND_SECONDS="${MAX_COMMAND_SECONDS:-900}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-0.10}"

TEST_NAMES=(
  enwik9
  corpus_game
  corpus_json
  corpus_sealed
  corpus_code
)

UTC_STAMP="$(date -u '+%Y-%m-%d_%H%M%SZ')"
RUN_NAME="MDLBSG_BENCHMARK_EVIDENCE_${UTC_STAMP}"
RUN_ROOT="$HOME/Downloads/$RUN_NAME"
EVIDENCE="$RUN_ROOT/evidence"
WORK="$RUN_ROOT/work"
RAW="$EVIDENCE/raw"
MANIFESTS="$EVIDENCE/manifests"
RESULTS_JSONL="$EVIDENCE/results.jsonl"
FINAL_ZIP="$HOME/Downloads/$RUN_NAME.zip"

CLI="$HOME/.mdlbsg/bin/mdlbsg"
BUILD_INFO="$HOME/.mdlbsg/bin/BUILD_INFO"
CACHE_ENABLE_FILE="$HOME/.mdlbsg/cache_enabled"
CACHE_WAS_ON=0
CURRENT_TEST=""

fail() {
  echo
  echo "BENCHMARK FAILED: $*" >&2
  echo "Evidence collected so far remains at:" >&2
  echo "$RUN_ROOT" >&2
  exit 1
}

restore_cache_state() {
  if [[ "$CACHE_WAS_ON" == "1" ]]; then
    "$CLI" cache on >/dev/null 2>&1 || true
  else
    "$CLI" cache off >/dev/null 2>&1 || true
  fi
}

cleanup_on_exit() {
  restore_cache_state
}
trap cleanup_on_exit EXIT

[[ "$(uname -s)" == "Darwin" ]] \
  || fail "This benchmark runner is for macOS."

for tool in \
  /bin/bash \
  /usr/bin/awk \
  /usr/bin/ditto \
  /usr/bin/find \
  /usr/bin/grep \
  /usr/bin/python3 \
  /usr/bin/sed \
  /usr/bin/shasum \
  /usr/bin/stat \
  /usr/bin/tar \
  /usr/bin/unzip
 do
  [[ -x "$tool" ]] || fail "Required tool is missing: $tool"
done

[[ -x "$CLI" ]] \
  || fail "MDLBSG is not installed at $CLI"

case "$MODE" in
  turbo) ;;
  *) fail "This public benchmark is locked to Turbo mode. Got: $MODE" ;;
esac

[[ -d "$SOURCE_DIR" ]] \
  || fail "Source directory was not found: $SOURCE_DIR"

for name in "${TEST_NAMES[@]}"; do
  [[ -e "$SOURCE_DIR/$name" ]] \
    || fail "Required benchmark input is missing: $SOURCE_DIR/$name"
done

[[ -f "$SOURCE_DIR/enwik9" ]] \
  || fail "enwik9 must be a regular file."

ENWIK9_BYTES="$(/usr/bin/stat -f%z "$SOURCE_DIR/enwik9")"
[[ "$ENWIK9_BYTES" == "1000000000" ]] \
  || fail "enwik9 is $ENWIK9_BYTES bytes; expected exactly 1,000,000,000 bytes."

for name in corpus_game corpus_json corpus_sealed corpus_code; do
  [[ -d "$SOURCE_DIR/$name" ]] \
    || fail "$name must be a folder."
done

[[ ! -e "$RUN_ROOT" ]] || fail "Run folder already exists: $RUN_ROOT"
mkdir -p "$RAW" "$MANIFESTS" "$WORK"
: > "$RESULTS_JSONL"

# Preserve the exact benchmark script used as evidence.
cp "$0" "$EVIDENCE/RUN_MDLBSG_V0_1_REPRODUCIBLE_BENCHMARK.command"
chmod 755 "$EVIDENCE/RUN_MDLBSG_V0_1_REPRODUCIBLE_BENCHMARK.command"
SCRIPT_SHA="$(/usr/bin/shasum -a 256 "$EVIDENCE/RUN_MDLBSG_V0_1_REPRODUCIBLE_BENCHMARK.command" | /usr/bin/awk '{print $1}')"

cat > "$WORK/run_and_measure.py" <<'PY'
#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def process_snapshot():
    try:
        text = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid=,rss=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return {}

    rows = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 3:
            continue
        try:
            pid = int(parts[0])
            ppid = int(parts[1])
            rss_kb = int(parts[2])
        except ValueError:
            continue
        command = parts[3] if len(parts) == 4 else ""
        rows[pid] = (ppid, rss_kb, command)
    return rows


def descendants(rows, root_pid):
    found = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _rss, _cmd) in rows.items():
            if pid not in found and ppid in found:
                found.add(pid)
                changed = True
    return found


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--interval", type=float, default=0.10)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("No command supplied")

    log_path = Path(args.log)
    json_path = Path(args.json)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.parent.mkdir(parents=True, exist_ok=True)

    start_utc = utc_now()
    start_mono = time.monotonic()
    peak_tree_kb = 0
    peak_single_kb = 0
    peak_processes = []
    samples = 0
    timed_out = False

    env = os.environ.copy()
    env["LC_ALL"] = "C"
    env["LANG"] = "C"

    with log_path.open("w", encoding="utf-8", errors="replace") as log_file:
        log_file.write(f"label={args.label}\n")
        log_file.write(f"start_utc={start_utc}\n")
        log_file.write("command=" + json.dumps(command) + "\n")
        log_file.flush()

        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            bufsize=1,
            env=env,
            start_new_session=True,
        )

        def tee_output():
            assert proc.stdout is not None
            for line in proc.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log_file.write(line)
                log_file.flush()

        reader = threading.Thread(target=tee_output, daemon=True)
        reader.start()

        try:
            while proc.poll() is None:
                elapsed = time.monotonic() - start_mono
                if elapsed > args.timeout:
                    timed_out = True
                    try:
                        os.killpg(proc.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    time.sleep(2.0)
                    if proc.poll() is None:
                        try:
                            os.killpg(proc.pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    break

                rows = process_snapshot()
                pids = descendants(rows, proc.pid)
                total_kb = sum(rows.get(pid, (0, 0, ""))[1] for pid in pids)
                single = sorted(
                    (
                        {
                            "pid": pid,
                            "rss_kb": rows.get(pid, (0, 0, ""))[1],
                            "command": rows.get(pid, (0, 0, ""))[2],
                        }
                        for pid in pids
                    ),
                    key=lambda item: item["rss_kb"],
                    reverse=True,
                )
                if total_kb > peak_tree_kb:
                    peak_tree_kb = total_kb
                    peak_processes = single[:8]
                if single:
                    peak_single_kb = max(peak_single_kb, single[0]["rss_kb"])
                samples += 1
                time.sleep(max(0.02, args.interval))
        finally:
            return_code = proc.wait()
            reader.join(timeout=5.0)

        end_utc = utc_now()
        wall_seconds = time.monotonic() - start_mono
        payload = {
            "label": args.label,
            "command": command,
            "start_utc": start_utc,
            "end_utc": end_utc,
            "wall_seconds": wall_seconds,
            "return_code": return_code,
            "timed_out": timed_out,
            "sample_interval_seconds": args.interval,
            "memory_samples": samples,
            "peak_process_tree_rss_bytes_sampled": peak_tree_kb * 1024,
            "peak_single_process_rss_bytes_sampled": peak_single_kb * 1024,
            "processes_at_peak": peak_processes,
        }
        json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        log_file.write(f"\nend_utc={end_utc}\n")
        log_file.write(f"measured_wall_seconds={wall_seconds:.6f}\n")
        log_file.write(f"return_code={return_code}\n")
        log_file.write(f"timed_out={str(timed_out).lower()}\n")
        log_file.write(f"peak_process_tree_rss_bytes_sampled={peak_tree_kb * 1024}\n")
        log_file.flush()

    if timed_out:
        return 124
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
PY
chmod 755 "$WORK/run_and_measure.py"

cat > "$WORK/make_manifest.py" <<'PY'
#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def manifest_for(path: Path):
    lines = []
    files = 0
    dirs = 0
    symlinks = 0
    total_bytes = 0

    if path.is_symlink():
        target = os.readlink(path)
        digest = hashlib.sha256(os.fsencode(target)).hexdigest()
        lines.append(f"L\t0\t{digest}\t{json.dumps('.')}\t{json.dumps(target)}")
        symlinks = 1
    elif path.is_file():
        size = path.stat().st_size
        digest = file_sha256(path)
        lines.append(f"F\t{size}\t{digest}\t{json.dumps('.')}")
        files = 1
        total_bytes = size
    elif path.is_dir():
        root = path
        dirs = 1
        lines.append(f"D\t0\t-\t{json.dumps('.')}")
        for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
            dirnames.sort(key=os.fsencode)
            filenames.sort(key=os.fsencode)
            current_path = Path(current)

            retained_dirs = []
            for dirname in dirnames:
                child = current_path / dirname
                rel = child.relative_to(root).as_posix()
                if child.is_symlink():
                    target = os.readlink(child)
                    digest = hashlib.sha256(os.fsencode(target)).hexdigest()
                    lines.append(f"L\t0\t{digest}\t{json.dumps(rel)}\t{json.dumps(target)}")
                    symlinks += 1
                else:
                    lines.append(f"D\t0\t-\t{json.dumps(rel)}")
                    dirs += 1
                    retained_dirs.append(dirname)
            dirnames[:] = retained_dirs

            for filename in filenames:
                child = current_path / filename
                rel = child.relative_to(root).as_posix()
                try:
                    mode = child.lstat().st_mode
                except FileNotFoundError:
                    raise SystemExit(f"Input changed during hashing: {child}")
                if stat.S_ISLNK(mode):
                    target = os.readlink(child)
                    digest = hashlib.sha256(os.fsencode(target)).hexdigest()
                    lines.append(f"L\t0\t{digest}\t{json.dumps(rel)}\t{json.dumps(target)}")
                    symlinks += 1
                elif stat.S_ISREG(mode):
                    size = child.stat().st_size
                    digest = file_sha256(child)
                    lines.append(f"F\t{size}\t{digest}\t{json.dumps(rel)}")
                    files += 1
                    total_bytes += size
                else:
                    lines.append(f"O\t0\t-\t{json.dumps(rel)}")
    else:
        raise SystemExit(f"Unsupported input type: {path}")

    encoded = ("\n".join(lines) + "\n").encode("utf-8")
    tree_sha = hashlib.sha256(encoded).hexdigest()
    return encoded, {
        "path_basename": path.name,
        "kind": "folder" if path.is_dir() else "file",
        "regular_files": files,
        "directories": dirs,
        "symlinks": symlinks,
        "logical_file_bytes": total_bytes,
        "content_structure_sha256": tree_sha,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--json", required=True)
    args = parser.parse_args()

    path = Path(args.path).resolve()
    encoded, summary = manifest_for(path)
    Path(args.manifest).write_bytes(encoded)
    Path(args.json).write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
PY
chmod 755 "$WORK/make_manifest.py"

cat > "$WORK/append_result.py" <<'PY'
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
for name in (
    "name", "kind", "source_json", "restored_json", "compress_measure",
    "restore_measure", "archive_sha256", "archive_bytes", "encoder_input_bytes",
    "core_compress_seconds", "core_restore_seconds", "bundle_seconds",
    "unbundle_seconds", "exact_restore", "mode", "app_version",
    "encoder_input_sha256"
):
    parser.add_argument(f"--{name.replace('_', '-')}", required=True)
parser.add_argument("--out", required=True)
args = parser.parse_args()

def load(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))

source = load(args.source_json)
restored = load(args.restored_json)
compress_measure = load(args.compress_measure)
restore_measure = load(args.restore_measure)

row = {
    "name": args.name,
    "kind": args.kind,
    "mode": args.mode,
    "app_version": args.app_version,
    "regular_files": source["regular_files"],
    "source_logical_bytes": source["logical_file_bytes"],
    "encoder_input_bytes": int(args.encoder_input_bytes),
    "archive_bytes": int(args.archive_bytes),
    "archive_sha256": args.archive_sha256,
    "encoder_input_sha256": args.encoder_input_sha256,
    "source_content_structure_sha256": source["content_structure_sha256"],
    "restored_content_structure_sha256": restored["content_structure_sha256"],
    "exact_restore": args.exact_restore.lower() == "yes",
    "core_compress_seconds": float(args.core_compress_seconds),
    "compression_end_to_end_seconds": compress_measure["wall_seconds"],
    "compression_peak_process_tree_rss_bytes_sampled": compress_measure["peak_process_tree_rss_bytes_sampled"],
    "core_restore_seconds": float(args.core_restore_seconds),
    "restore_end_to_end_seconds": restore_measure["wall_seconds"],
    "restore_peak_process_tree_rss_bytes_sampled": restore_measure["peak_process_tree_rss_bytes_sampled"],
    "folder_bundle_seconds": float(args.bundle_seconds),
    "folder_unbundle_seconds": float(args.unbundle_seconds),
}
row["archive_ratio_percent"] = (row["archive_bytes"] / row["encoder_input_bytes"] * 100.0) if row["encoder_input_bytes"] else 0.0
row["smaller_percent"] = 100.0 - row["archive_ratio_percent"]
row["compression_mib_per_second"] = (row["encoder_input_bytes"] / 1048576.0 / row["core_compress_seconds"]) if row["core_compress_seconds"] else 0.0
row["restore_mib_per_second"] = (row["encoder_input_bytes"] / 1048576.0 / row["core_restore_seconds"]) if row["core_restore_seconds"] else 0.0

with Path(args.out).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(row, sort_keys=True) + "\n")
PY
chmod 755 "$WORK/append_result.py"

cat > "$WORK/render_results.py" <<'PY'
#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--jsonl", required=True)
parser.add_argument("--csv", required=True)
parser.add_argument("--markdown", required=True)
parser.add_argument("--environment", required=True)
parser.add_argument("--script-sha", required=True)
parser.add_argument("--run-id", required=True)
parser.add_argument("--mem-budget-gb", required=True)
args = parser.parse_args()

rows = [json.loads(line) for line in Path(args.jsonl).read_text(encoding="utf-8").splitlines() if line.strip()]

fields = [
    "name", "kind", "mode", "app_version", "regular_files",
    "source_logical_bytes", "encoder_input_bytes", "archive_bytes",
    "archive_ratio_percent", "smaller_percent", "core_compress_seconds",
    "compression_mib_per_second", "compression_peak_process_tree_rss_bytes_sampled",
    "core_restore_seconds", "restore_mib_per_second",
    "restore_peak_process_tree_rss_bytes_sampled", "exact_restore",
    "archive_sha256", "encoder_input_sha256", "source_content_structure_sha256",
]
with Path(args.csv).open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(rows)


def commas(value):
    return f"{int(value):,}"


def gib(value):
    return f"{value / (1024**3):.2f} GiB"

lines = []
lines.append("# MDLBSG v0.1 Reproducible Benchmark Results")
lines.append("")
lines.append(f"Run ID: `{args.run_id}`  ")
lines.append(f"Benchmark script SHA-256: `{args.script_sha}`  ")
lines.append(f"Configured compressor memory budget: `{args.mem_budget_gb} GiB`")
lines.append("")
lines.append("> Peak RAM below is the highest sampled total RSS of the benchmark command and its descendant processes. It is measured every 0.10 seconds; it is not a kernel-enforced hard limit.")
lines.append("")
lines.append("| Corpus | Type | Files | Encoder input | Archive | Smaller | Core time | Speed | Sampled peak RAM | Exact restore |")
lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|")
for row in rows:
    lines.append(
        "| {name} | {kind} | {files:,} | {input_bytes:,} B | {archive_bytes:,} B | {smaller:.2f}% | {seconds:.3f} s | {speed:.2f} MiB/s | {ram} | {exact} |".format(
            name=row["name"],
            kind=row["kind"],
            files=row["regular_files"],
            input_bytes=row["encoder_input_bytes"],
            archive_bytes=row["archive_bytes"],
            smaller=row["smaller_percent"],
            seconds=row["core_compress_seconds"],
            speed=row["compression_mib_per_second"],
            ram=gib(row["compression_peak_process_tree_rss_bytes_sampled"]),
            exact="YES" if row["exact_restore"] else "NO",
        )
    )
lines.append("")
lines.append("## Notes")
lines.append("")
lines.append("- Turbo mode is used for every compression run.")
lines.append("- Cache is disabled during compression and restoration so restoration exercises the decoder.")
lines.append("- For folders, `Encoder input` is the tar bundle actually passed into the compressor. Source logical bytes and deterministic tree hashes are retained in `results.jsonl` and `RESULTS.csv`.")
lines.append("- Exact restoration means the deterministic content-and-path manifest SHA-256 matched before and after restoration.")
lines.append("- Timing can vary across nominally identical Macs because of temperature, power state, background work, and storage performance.")
lines.append("")
lines.append("## Recorded Environment")
lines.append("")
lines.append("```text")
lines.extend(Path(args.environment).read_text(encoding="utf-8").rstrip().splitlines())
lines.append("```")
lines.append("")

Path(args.markdown).write_text("\n".join(lines), encoding="utf-8")
PY
chmod 755 "$WORK/render_results.py"

/usr/bin/python3 -m py_compile \
  "$WORK/run_and_measure.py" \
  "$WORK/make_manifest.py" \
  "$WORK/append_result.py" \
  "$WORK/render_results.py"

APP=""
if [[ -d "/Applications/MDLBSG Compressor.app" ]]; then
  APP="/Applications/MDLBSG Compressor.app"
elif [[ -d "$HOME/Applications/MDLBSG Compressor.app" ]]; then
  APP="$HOME/Applications/MDLBSG Compressor.app"
else
  fail "Installed MDLBSG Compressor.app was not found."
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$APP_VERSION" ]] || fail "Could not read the installed app version."
[[ "$APP_VERSION" == "$EXPECTED_APP_VERSION" ]] \
  || fail "Installed app version is $APP_VERSION; expected $EXPECTED_APP_VERSION for this v0.1 benchmark."

if [[ -f "$CACHE_ENABLE_FILE" ]]; then
  CACHE_WAS_ON=1
fi
"$CLI" cache off >/dev/null

PHYSICAL_BYTES="$(sysctl -n hw.memsize | tr -d '[:space:]')"
MEM_BUDGET_GB=$(( PHYSICAL_BYTES / 1073741824 / 2 ))
[[ "$MEM_BUDGET_GB" -ge 2 ]] || MEM_BUDGET_GB=2

VERSION_OUTPUT="$("$CLI" version)"
WRAPPER_BUDGET="$(printf '%s\n' "$VERSION_OUTPUT" | /usr/bin/grep -Eo 'mem_budget=[0-9]+GB' | tail -1 | /usr/bin/grep -Eo '[0-9]+' || true)"
[[ "$WRAPPER_BUDGET" == "$MEM_BUDGET_GB" ]] \
  || fail "Wrapper reports ${WRAPPER_BUDGET:-unknown} GB but calculated budget is $MEM_BUDGET_GB GB."

{
  echo "run_id: $RUN_NAME"
  echo "run_started_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "benchmark_script_sha256: $SCRIPT_SHA"
  echo "installed_app_version: $APP_VERSION"
  echo "benchmark_mode: $MODE"
  echo "configured_memory_budget_gb: $MEM_BUDGET_GB"
  echo "memory_budget_rule: half of physical RAM, minimum 2 GiB"
  echo "memory_limit_kind: compressor budget/guard, not an operating-system hard cap"
  echo "memory_measurement: sampled process-tree RSS every ${SAMPLE_INTERVAL_SECONDS}s"
  echo "cache_during_run: off"
  echo "cache_state_before_run: $([[ "$CACHE_WAS_ON" == "1" ]] && echo on || echo off)"
  echo
  echo "macOS_product_name: $(sw_vers -productName)"
  echo "macOS_product_version: $(sw_vers -productVersion)"
  echo "macOS_build_version: $(sw_vers -buildVersion)"
  echo "kernel_release: $(uname -r)"
  echo "architecture: $(uname -m)"
  echo "hardware_model: $(sysctl -n hw.model 2>/dev/null || echo unknown)"
  echo "cpu_brand: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo Apple Silicon)"
  echo "physical_memory_bytes: $PHYSICAL_BYTES"
  echo "logical_cpu_count: $(sysctl -n hw.logicalcpu 2>/dev/null || echo unknown)"
  echo "performance_core_logical_count: $(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo unknown)"
  echo "performance_core_physical_count: $(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo unknown)"
  echo "low_power_mode: $(pmset -g 2>/dev/null | awk '/lowpowermode/{print $2; exit}' || echo unknown)"
  echo "power_source: $(pmset -g batt 2>/dev/null | head -1 | sed 's/^Now drawing from //')"
  echo "source_volume_free_space: $(df -h "$SOURCE_DIR" | tail -1 | awk '{print $4}')"
  echo
  echo "mdlbsg_version_output:"
  printf '%s\n' "$VERSION_OUTPUT" | sed 's/^/  /'
} > "$EVIDENCE/ENVIRONMENT.txt"

{
  echo "$SCRIPT_SHA  RUN_MDLBSG_V0_1_REPRODUCIBLE_BENCHMARK.command"
  for path in \
    "$HOME/.mdlbsg/bin/mdlbsg" \
    "$HOME/.mdlbsg/bin/mdlbsg_core" \
    "$HOME/.mdlbsg/bin/mdlbsg_turbo" \
    "$HOME/.mdlbsg/bin/mdlbsg_turbo_v1" \
    "$HOME/.mdlbsg/bin/mdlbsg_droplet_handler.sh" \
    "$HOME/.mdlbsg/bin/mdlbsg_extract_handler.sh" \
    "$HOME/.mdlbsg/bin/BUILD_INFO" \
    "$APP/Contents/Info.plist" \
    "$APP/Contents/Resources/Scripts/main.scpt"
  do
    if [[ -f "$path" ]]; then
      hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
      display="${path/#$HOME/~}"
      echo "$hash  $display"
    fi
  done
} > "$EVIDENCE/SOFTWARE_SHA256.txt"

if [[ -f "$BUILD_INFO" ]]; then
  cp "$BUILD_INFO" "$EVIDENCE/BUILD_INFO.txt"
fi

cat > "$EVIDENCE/README.txt" <<EOF
MDLBSG v0.1 benchmark evidence

This directory records:
- the exact benchmark script and its SHA-256;
- the macOS/M1 environment without hardware serial numbers;
- hashes of the installed MDLBSG wrapper, cores, handlers, app plist, and app script;
- deterministic source and restored manifests;
- raw compression/restoration logs;
- sampled process-tree memory measurements;
- CSV, JSONL, and GitHub-ready Markdown results.

Configured compressor memory budget: ${MEM_BUDGET_GB} GiB.
This is the budget passed to the compressor, not a macOS-enforced hard ceiling.

Original benchmark corpora are never modified.
EOF

parse_last_number() {
  local key="$1"
  local file="$2"
  /usr/bin/grep -Eo "\[(v234|mdlbsg)\] ${key}=[0-9.]+" "$file" \
    | tail -1 \
    | /usr/bin/sed 's/.*=//'
}

measure_command() {
  local label="$1"
  local log="$2"
  local json="$3"
  shift 3
  /usr/bin/python3 "$WORK/run_and_measure.py" \
    --label "$label" \
    --log "$log" \
    --json "$json" \
    --timeout "$MAX_COMMAND_SECONDS" \
    --interval "$SAMPLE_INTERVAL_SECONDS" \
    -- "$@"
}

for name in "${TEST_NAMES[@]}"; do
  CURRENT_TEST="$name"
  SOURCE="$SOURCE_DIR/$name"
  TEST_WORK="$WORK/$name"
  mkdir -p "$TEST_WORK"

  echo
  echo "============================================================"
  echo "BENCHMARKING: $name"
  echo "============================================================"
  echo

  SOURCE_MANIFEST="$MANIFESTS/${name}_source.tsv"
  SOURCE_JSON="$MANIFESTS/${name}_source.json"
  /usr/bin/python3 "$WORK/make_manifest.py" \
    "$SOURCE" \
    --manifest "$SOURCE_MANIFEST" \
    --json "$SOURCE_JSON" \
    > "$RAW/${name}_source_manifest_summary.json"

  if [[ -d "$SOURCE" ]]; then
    KIND="folder"
    INPUT_FOR_CORE="$TEST_WORK/${name}.bundle.tar"
    BUNDLE_LOG="$RAW/${name}_bundle.log"
    BUNDLE_MEASURE="$RAW/${name}_bundle_measure.json"

    echo "[1/4] Creating the same folder bundle used by the application..."
    measure_command \
      "${name}:folder_bundle" \
      "$BUNDLE_LOG" \
      "$BUNDLE_MEASURE" \
      /usr/bin/env COPYFILE_DISABLE=1 /usr/bin/tar -cf "$INPUT_FOR_CORE" -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")"

    [[ -s "$INPUT_FOR_CORE" ]] || fail "$name folder bundle is missing or empty."
    /usr/bin/tar -tf "$INPUT_FOR_CORE" >/dev/null \
      || fail "$name folder bundle failed tar verification."
    SOURCE_REGULAR_FILES="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["regular_files"])' "$SOURCE_JSON")"
    TAR_NONDIR_ENTRIES="$(/usr/bin/tar -tf "$INPUT_FOR_CORE" | /usr/bin/grep -v '/$' | /usr/bin/wc -l | tr -d '[:space:]')"
    [[ "$TAR_NONDIR_ENTRIES" -ge "$SOURCE_REGULAR_FILES" ]] \
      || fail "$name folder bundle contains only $TAR_NONDIR_ENTRIES non-directory entries for $SOURCE_REGULAR_FILES source files."
    BUNDLE_SECONDS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["wall_seconds"])' "$BUNDLE_MEASURE")"
  else
    KIND="file"
    INPUT_FOR_CORE="$SOURCE"
    BUNDLE_SECONDS="0"
  fi

  ENCODER_INPUT_SHA="$(/usr/bin/shasum -a 256 "$INPUT_FOR_CORE" | /usr/bin/awk '{print $1}')"

  ARCHIVE="$TEST_WORK/${name}.mdl"
  COMPRESS_LOG="$RAW/${name}_compress.log"
  COMPRESS_MEASURE="$RAW/${name}_compress_measure.json"

  echo "[2/4] Compressing with the released Turbo wrapper..."
  if [[ "$KIND" == "folder" ]]; then
    measure_command \
      "${name}:compress" \
      "$COMPRESS_LOG" \
      "$COMPRESS_MEASURE" \
      "$CLI" c "$INPUT_FOR_CORE" "$ARCHIVE" -p turbo --content folder
  else
    measure_command \
      "${name}:compress" \
      "$COMPRESS_LOG" \
      "$COMPRESS_MEASURE" \
      "$CLI" c "$INPUT_FOR_CORE" "$ARCHIVE" -p turbo
  fi

  [[ -f "$ARCHIVE" ]] || fail "$name archive was not created."
  ENCODER_INPUT_BYTES="$(parse_last_number input_bytes "$COMPRESS_LOG")"
  REPORTED_ARCHIVE_BYTES="$(parse_last_number archive_bytes "$COMPRESS_LOG")"
  CORE_COMPRESS_SECONDS="$(parse_last_number wall_seconds "$COMPRESS_LOG")"
  [[ -n "$ENCODER_INPUT_BYTES" ]] || fail "$name compression log has no input_bytes result."
  [[ -n "$REPORTED_ARCHIVE_BYTES" ]] || fail "$name compression log has no archive_bytes result."
  [[ -n "$CORE_COMPRESS_SECONDS" ]] || fail "$name compression log has no wall_seconds result."

  ACTUAL_ARCHIVE_BYTES="$(/usr/bin/stat -f%z "$ARCHIVE")"
  [[ "$ACTUAL_ARCHIVE_BYTES" == "$REPORTED_ARCHIVE_BYTES" ]] \
    || fail "$name archive size mismatch: core reported $REPORTED_ARCHIVE_BYTES, file is $ACTUAL_ARCHIVE_BYTES."
  ARCHIVE_SHA="$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')"

  RESTORE_LOG="$RAW/${name}_restore.log"
  RESTORE_MEASURE="$RAW/${name}_restore_measure.json"

  echo "[3/4] Restoring through the released decoder with cache disabled..."
  if [[ "$KIND" == "folder" ]]; then
    RESTORED_TAR="$TEST_WORK/${name}.restored.tar"
    RESTORE_DIR="$TEST_WORK/restored"
    mkdir -p "$RESTORE_DIR"

    measure_command \
      "${name}:restore" \
      "$RESTORE_LOG" \
      "$RESTORE_MEASURE" \
      "$CLI" d "$ARCHIVE" "$RESTORED_TAR"

    [[ -s "$RESTORED_TAR" ]] || fail "$name restored tar is missing or empty."
    UNBUNDLE_LOG="$RAW/${name}_unbundle.log"
    UNBUNDLE_MEASURE="$RAW/${name}_unbundle_measure.json"
    measure_command \
      "${name}:folder_unbundle" \
      "$UNBUNDLE_LOG" \
      "$UNBUNDLE_MEASURE" \
      /usr/bin/tar -xf "$RESTORED_TAR" -C "$RESTORE_DIR"
    RESTORED_PATH="$RESTORE_DIR/$name"
    UNBUNDLE_SECONDS="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["wall_seconds"])' "$UNBUNDLE_MEASURE")"
  else
    RESTORED_PATH="$TEST_WORK/${name}.restored"
    measure_command \
      "${name}:restore" \
      "$RESTORE_LOG" \
      "$RESTORE_MEASURE" \
      "$CLI" d "$ARCHIVE" "$RESTORED_PATH"
    UNBUNDLE_SECONDS="0"
  fi

  CORE_RESTORE_SECONDS="$(parse_last_number wall_seconds "$RESTORE_LOG")"
  [[ -n "$CORE_RESTORE_SECONDS" ]] || fail "$name restoration log has no wall_seconds result."
  /usr/bin/grep -Fq 'integrity=verified' "$RESTORE_LOG" \
    || fail "$name decoder did not report integrity=verified."
  [[ -e "$RESTORED_PATH" ]] || fail "$name restored output was not created."

  RESTORED_MANIFEST="$MANIFESTS/${name}_restored.tsv"
  RESTORED_JSON="$MANIFESTS/${name}_restored.json"
  /usr/bin/python3 "$WORK/make_manifest.py" \
    "$RESTORED_PATH" \
    --manifest "$RESTORED_MANIFEST" \
    --json "$RESTORED_JSON" \
    > "$RAW/${name}_restored_manifest_summary.json"

  SOURCE_TREE_SHA="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content_structure_sha256"])' "$SOURCE_JSON")"
  RESTORED_TREE_SHA="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["content_structure_sha256"])' "$RESTORED_JSON")"

  echo "[4/4] Proving exact restoration..."
  [[ "$SOURCE_TREE_SHA" == "$RESTORED_TREE_SHA" ]] \
    || fail "$name exact restoration FAILED: source and restored manifest hashes differ."

  /usr/bin/python3 "$WORK/append_result.py" \
    --name "$name" \
    --kind "$KIND" \
    --source-json "$SOURCE_JSON" \
    --restored-json "$RESTORED_JSON" \
    --compress-measure "$COMPRESS_MEASURE" \
    --restore-measure "$RESTORE_MEASURE" \
    --archive-sha256 "$ARCHIVE_SHA" \
    --encoder-input-sha256 "$ENCODER_INPUT_SHA" \
    --archive-bytes "$ACTUAL_ARCHIVE_BYTES" \
    --encoder-input-bytes "$ENCODER_INPUT_BYTES" \
    --core-compress-seconds "$CORE_COMPRESS_SECONDS" \
    --core-restore-seconds "$CORE_RESTORE_SECONDS" \
    --bundle-seconds "$BUNDLE_SECONDS" \
    --unbundle-seconds "$UNBUNDLE_SECONDS" \
    --exact-restore yes \
    --mode "$MODE" \
    --app-version "$APP_VERSION" \
    --out "$RESULTS_JSONL"

  echo "      exact restoration: PASS"
  echo "      archive SHA-256: $ARCHIVE_SHA"

  if [[ "$KEEP_ARTIFACTS" != "1" ]]; then
    rm -rf "$TEST_WORK"
  fi
done

RUN_FINISHED_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "run_finished_utc: $RUN_FINISHED_UTC" >> "$EVIDENCE/ENVIRONMENT.txt"

/usr/bin/python3 "$WORK/render_results.py" \
  --jsonl "$RESULTS_JSONL" \
  --csv "$EVIDENCE/RESULTS.csv" \
  --markdown "$EVIDENCE/BENCHMARK_RESULTS.md" \
  --environment "$EVIDENCE/ENVIRONMENT.txt" \
  --script-sha "$SCRIPT_SHA" \
  --run-id "$RUN_NAME" \
  --mem-budget-gb "$MEM_BUDGET_GB"

# Public evidence should not expose the local home-directory path.
/usr/bin/python3 - "$EVIDENCE" "$HOME" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
home = sys.argv[2]
for path in root.rglob("*"):
    if not path.is_file() or path.name == "RUN_MDLBSG_V0_1_REPRODUCIBLE_BENCHMARK.command":
        continue
    if path.suffix.lower() not in {".txt", ".log", ".json", ".jsonl", ".csv", ".md", ".tsv"}:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    path.write_text(text.replace(home, "~"), encoding="utf-8")
PY

/usr/bin/python3 - "$EVIDENCE" <<'PY'
from pathlib import Path
import hashlib
import sys
root = Path(sys.argv[1])
rows = []
for path in sorted((p for p in root.rglob("*") if p.is_file() and p.name != "SHA256SUMS.txt"), key=lambda p: p.relative_to(root).as_posix().encode("utf-8")):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    rows.append(f"{digest.hexdigest()}  {path.relative_to(root).as_posix()}")
(root / "SHA256SUMS.txt").write_text("\n".join(rows) + "\n", encoding="utf-8")
PY

rm -f "$FINAL_ZIP"
COPYFILE_DISABLE=1 /usr/bin/ditto \
  -c \
  -k \
  --keepParent \
  "$EVIDENCE" \
  "$FINAL_ZIP"

/usr/bin/unzip -t "$FINAL_ZIP" >/dev/null \
  || fail "Final evidence ZIP failed integrity testing."

FINAL_ZIP_SHA="$(/usr/bin/shasum -a 256 "$FINAL_ZIP" | /usr/bin/awk '{print $1}')"

restore_cache_state
trap - EXIT

if [[ "$KEEP_ARTIFACTS" != "1" ]]; then
  rm -rf "$WORK"
fi

echo
echo "============================================================"
echo "MDLBSG BENCHMARK EVIDENCE COMPLETE"
echo "============================================================"
echo
echo "GitHub-ready results:"
echo "$EVIDENCE/BENCHMARK_RESULTS.md"
echo
echo "Evidence ZIP:"
echo "$FINAL_ZIP"
echo
echo "Evidence ZIP SHA-256:"
echo "$FINAL_ZIP_SHA"
echo
echo "Benchmark script SHA-256:"
echo "$SCRIPT_SHA"
echo
echo "Cache state restored to: $([[ "$CACHE_WAS_ON" == "1" ]] && echo on || echo off)"
echo
cat "$EVIDENCE/BENCHMARK_RESULTS.md"
echo
/usr/bin/open -R "$FINAL_ZIP" 2>/dev/null || true
