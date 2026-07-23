#!/usr/bin/env bash
set -euo pipefail
umask 077

echo "============================================================"
echo "MDLBSG — BUILD LICENSE-PRESERVING HUGGING FACE CORPORA V1"
echo "============================================================"
echo

DOWNLOADS="$HOME/Downloads"
ENWIK9="$DOWNLOADS/enwik9"
OUT="$DOWNLOADS/MDLBSG_HF_LICENSED_CORPORA_V1"
VENV="$OUT/.builder_venv"
CACHE="$OUT/.hf_cache"
BUILD_LOG="$OUT/BUILD_LOG.txt"

fail() {
  echo
  echo "CORPUS BUILD FAILED: $*" >&2
  exit 1
}

for tool in python3 shasum unzip; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "Required tool is missing: $tool"
done

[[ -f "$ENWIK9" ]] \
  || fail "enwik9 was not found: $ENWIK9"

ENWIK9_BYTES="$(/usr/bin/stat -f%z "$ENWIK9")"
[[ "$ENWIK9_BYTES" == "1000000000" ]] \
  || fail "enwik9 is $ENWIK9_BYTES bytes; expected exactly 1,000,000,000."

ENWIK9_MD5="$(/sbin/md5 -q "$ENWIK9")"
ENWIK9_SHA1="$(/usr/bin/shasum -a 1 "$ENWIK9" | /usr/bin/awk '{print $1}')"

[[ "$ENWIK9_MD5" == "e206c3450ac99950df65bf70ef61a12d" ]] \
  || fail "enwik9 MD5 does not match the published benchmark file."

[[ "$ENWIK9_SHA1" == "2996e86fb978f93cca8f566cc56998923e7fe581" ]] \
  || fail "enwik9 SHA-1 does not match the published benchmark file."

[[ ! -e "$OUT" ]] \
  || fail "Output already exists: $OUT"

mkdir -p "$OUT"
exec > >(tee "$BUILD_LOG") 2>&1

echo "[1/6] Creating isolated Python environment..."

python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip wheel
"$VENV/bin/python" -m pip install \
  "datasets>=3.0,<5" \
  "huggingface_hub>=0.26,<2" \
  "pyarrow>=15,<25"

echo "      environment: PASS"

echo
echo "[2/6] Building pinned, license-preserving corpora..."

export HF_HOME="$CACHE"
export HF_DATASETS_CACHE="$CACHE/datasets"
export HUGGINGFACE_HUB_CACHE="$CACHE/hub"
export TOKENIZERS_PARALLELISM=false
export MDLBSG_HF_OUT="$OUT"
export MDLBSG_ENWIK9="$ENWIK9"

"$VENV/bin/python" <<'PY'
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import platform
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path
from typing import Any, Iterable

from datasets import load_dataset
from huggingface_hub import HfApi, hf_hub_download
import datasets
import huggingface_hub
import pyarrow

OUT = Path(os.environ["MDLBSG_HF_OUT"])
ENWIK9 = Path(os.environ["MDLBSG_ENWIK9"])
CORPORA = OUT / "corpora"
RELEASES = OUT / "release_assets"
CORPORA.mkdir()
RELEASES.mkdir()

BUILD_UTC = dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")
api = HfApi()

LICENSE_URLS = {
    "CC-BY-SA-3.0": "https://creativecommons.org/licenses/by-sa/3.0/legalcode.txt",
    "CC-BY-SA-4.0": "https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt",
    "GFDL-1.3": "https://www.gnu.org/licenses/fdl-1.3.txt",
    "MIT": "https://raw.githubusercontent.com/spdx/license-list-data/main/text/MIT.txt",
    "CC0-1.0": "https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt",
}

SPECS = [
    {
        "name": "corpus_hf_wikitext",
        "repo": "Salesforce/wikitext",
        "config": "wikitext-103-raw-v1",
        "splits": ["train", "validation", "test"],
        "declared_licenses": ["CC-BY-SA-3.0", "CC-BY-SA-4.0", "GFDL-1.3"],
        "target_bytes": 192 * 1024 * 1024,
        "kind": "wikitext",
        "policy": (
            "Read pinned splits in train/validation/test order and write non-empty "
            "raw text records until the UTF-8 data file reaches at least 192 MiB."
        ),
    },
    {
        "name": "corpus_hf_gsm8k",
        "repo": "openai/gsm8k",
        "config": "main",
        "splits": ["train", "test"],
        "declared_licenses": ["MIT"],
        "target_bytes": None,
        "kind": "jsonl_full",
        "policy": "Write every row from the pinned train and test splits as canonical JSONL.",
    },
    {
        "name": "corpus_hf_dolly",
        "repo": "databricks/databricks-dolly-15k",
        "config": None,
        "splits": ["train"],
        "declared_licenses": ["CC-BY-SA-3.0"],
        "target_bytes": None,
        "kind": "jsonl_full",
        "policy": "Write every row from the pinned train split as canonical JSONL.",
    },
    {
        "name": "corpus_hf_code_cc0",
        "repo": "KoalaAI/GitHub-CC0",
        "config": None,
        "splits": ["train"],
        "declared_licenses": ["CC0-1.0"],
        "target_bytes": 128 * 1024 * 1024,
        "max_record_bytes": 2 * 1024 * 1024,
        "kind": "jsonl_target",
        "policy": (
            "Read the pinned train split in Hub order. Canonicalize each row to "
            "JSONL, skip rows larger than 2 MiB, and stop after at least 128 MiB "
            "of accepted JSONL has been written."
        ),
    },
]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def fetch_url(url: str) -> bytes:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "MDLBSG licensed corpus builder/1.0"},
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def canonical_json_line(row: dict[str, Any], split: str, index: int) -> bytes:
    body = {
        "_mdlbsg_source_split": split,
        "_mdlbsg_source_index": index,
        "record": row,
    }
    return (
        json.dumps(
            body,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            default=str,
        )
        + "\n"
    ).encode("utf-8")


def clean_tree(root: Path) -> None:
    for path in sorted(root.rglob("*"), reverse=True):
        if (
            path.name == ".DS_Store"
            or path.name.startswith("._")
            or "__MACOSX" in path.parts
            or "__pycache__" in path.parts
            or path.suffix == ".pyc"
        ):
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path, ignore_errors=True)
            else:
                path.unlink(missing_ok=True)


def write_manifest(root: Path) -> dict[str, Any]:
    rows = []
    total_bytes = 0
    regular_files = 0
    for path in sorted(
        (p for p in root.rglob("*") if p.is_file()),
        key=lambda p: p.relative_to(root).as_posix().encode("utf-8"),
    ):
        rel = path.relative_to(root).as_posix()
        digest = sha256_file(path)
        size = path.stat().st_size
        rows.append(f"{digest}  {rel}")
        regular_files += 1
        total_bytes += size
    (root / "SHA256SUMS.txt").write_text(
        "\n".join(rows) + "\n", encoding="utf-8"
    )
    tree_sha = hashlib.sha256(
        ("\n".join(rows) + "\n").encode("utf-8")
    ).hexdigest()
    return {
        "regular_files": regular_files,
        "logical_file_bytes_before_manifest": total_bytes,
        "manifest_sha256": tree_sha,
    }


def deterministic_zip(source: Path, destination: Path) -> None:
    with zipfile.ZipFile(
        destination,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
        allowZip64=True,
    ) as zf:
        for path in sorted(
            source.rglob("*"),
            key=lambda p: p.relative_to(source.parent).as_posix().encode("utf-8"),
        ):
            arc = path.relative_to(source.parent).as_posix()
            if path.is_dir():
                info = zipfile.ZipInfo(arc.rstrip("/") + "/", (1980, 1, 1, 0, 0, 0))
                info.external_attr = 0o40755 << 16
                zf.writestr(info, b"")
                continue
            info = zipfile.ZipInfo(arc, (1980, 1, 1, 0, 0, 0))
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            with path.open("rb") as source_handle, zf.open(info, "w") as zip_handle:
                shutil.copyfileobj(source_handle, zip_handle, length=1024 * 1024)


def copy_dataset_card(repo: str, revision: str, destination: Path) -> str:
    source = Path(
        hf_hub_download(
            repo_id=repo,
            filename="README.md",
            repo_type="dataset",
            revision=revision,
        )
    )
    shutil.copy2(source, destination)
    return sha256_file(destination)


def write_licenses(corpus: Path, license_names: list[str]) -> list[dict[str, Any]]:
    license_dir = corpus / "LICENSES"
    license_dir.mkdir()
    results = []
    for name in license_names:
        url = LICENSE_URLS[name]
        data = fetch_url(url)
        path = license_dir / f"{name}.txt"
        path.write_bytes(data)
        results.append(
            {
                "name": name,
                "official_text_url": url,
                "sha256": sha256_file(path),
            }
        )
    return results


def load_stream(spec: dict[str, Any], revision: str, split: str):
    kwargs = {
        "path": spec["repo"],
        "split": split,
        "revision": revision,
        "streaming": True,
    }
    if spec["config"] is not None:
        kwargs["name"] = spec["config"]
    return load_dataset(**kwargs)


suite_rows = []

for spec in SPECS:
    print(f"Building {spec['name']} from {spec['repo']}...")
    info = api.dataset_info(spec["repo"])
    revision = info.sha
    corpus = CORPORA / spec["name"]
    data_dir = corpus / "data"
    data_dir.mkdir(parents=True)

    card_sha = copy_dataset_card(
        spec["repo"], revision, corpus / "DATASET_CARD.md"
    )
    licenses = write_licenses(corpus, spec["declared_licenses"])

    accepted_rows = 0
    skipped_oversize = 0
    data_bytes = 0
    split_counts = {}

    if spec["kind"] == "wikitext":
        output = data_dir / "wikitext_103_raw.txt"
        with output.open("wb") as handle:
            reached = False
            for split in spec["splits"]:
                count = 0
                for row in load_stream(spec, revision, split):
                    text = str(row.get("text", ""))
                    if not text.strip():
                        continue
                    payload = text.encode("utf-8") + b"\n"
                    handle.write(payload)
                    data_bytes += len(payload)
                    count += 1
                    accepted_rows += 1
                    if data_bytes >= spec["target_bytes"]:
                        reached = True
                        break
                split_counts[split] = count
                if reached:
                    break
    else:
        output = data_dir / "records.jsonl"
        with output.open("wb") as handle:
            stop = False
            for split in spec["splits"]:
                count = 0
                for index, row in enumerate(load_stream(spec, revision, split)):
                    payload = canonical_json_line(dict(row), split, index)
                    max_record = spec.get("max_record_bytes")
                    if max_record is not None and len(payload) > max_record:
                        skipped_oversize += 1
                        continue
                    handle.write(payload)
                    data_bytes += len(payload)
                    count += 1
                    accepted_rows += 1
                    target = spec.get("target_bytes")
                    if target is not None and data_bytes >= target:
                        stop = True
                        break
                split_counts[split] = count
                if stop:
                    break

    source = {
        "corpus_name": spec["name"],
        "built_utc": BUILD_UTC,
        "source_platform": "Hugging Face Hub",
        "dataset_repo": spec["repo"],
        "dataset_url": f"https://huggingface.co/datasets/{spec['repo']}",
        "resolved_revision": revision,
        "configuration": spec["config"],
        "requested_splits": spec["splits"],
        "accepted_rows": accepted_rows,
        "accepted_data_bytes": data_bytes,
        "skipped_oversize_rows": skipped_oversize,
        "accepted_rows_by_split": split_counts,
        "selection_policy": spec["policy"],
        "declared_licenses": spec["declared_licenses"],
        "license_files": licenses,
        "dataset_card_sha256": card_sha,
        "datasets_library_version": datasets.__version__,
        "huggingface_hub_version": huggingface_hub.__version__,
        "pyarrow_version": pyarrow.__version__,
        "normalization": (
            "UTF-8. JSON corpora use sorted keys, compact separators, one record "
            "per line, and add source split/index fields. WikiText preserves raw "
            "text records separated by LF."
        ),
    }
    write_json(corpus / "SOURCE.json", source)

    readme = f"""# {spec['name']}

This corpus was built for reproducible MDLBSG compression testing.

## Source

- Hugging Face dataset: `{spec['repo']}`
- Pinned revision: `{revision}`
- Configuration: `{spec['config']}`
- Accepted records: `{accepted_rows:,}`
- Data bytes before documentation: `{data_bytes:,}`

## Selection

{spec['policy']}

## Licensing

The exact Hugging Face dataset card is preserved as `DATASET_CARD.md`.
Official license text files are preserved in `LICENSES/`.
See `SOURCE.json` for the declared licenses, source revision, selection policy,
library versions, and license-file hashes.

This derived corpus must be redistributed under all applicable source terms.
"""
    (corpus / "README.md").write_text(readme, encoding="utf-8")

    clean_tree(corpus)
    manifest_summary = write_manifest(corpus)
    zip_path = RELEASES / f"{spec['name']}.zip"
    deterministic_zip(corpus, zip_path)

    suite_rows.append(
        {
            **source,
            **manifest_summary,
            "corpus_zip": zip_path.name,
            "corpus_zip_bytes": zip_path.stat().st_size,
            "corpus_zip_sha256": sha256_file(zip_path),
        }
    )


# Package enwik9 with its source and license documentation.
enwik_dir = OUT / "enwik9_release"
enwik_dir.mkdir()
shutil.copy2(ENWIK9, enwik_dir / "enwik9")

enwik_license_rows = []
for name in ("CC-BY-SA-3.0", "GFDL-1.3"):
    url = LICENSE_URLS[name]
    data = fetch_url(url)
    path = enwik_dir / f"LICENSE_{name}.txt"
    path.write_bytes(data)
    enwik_license_rows.append(
        {"name": name, "url": url, "sha256": sha256_file(path)}
    )

def multi_hash_file(path: Path) -> dict[str, str]:
    hashes = {
        "md5": hashlib.md5(),
        "sha1": hashlib.sha1(),
        "sha256": hashlib.sha256(),
    }
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            for digest in hashes.values():
                digest.update(chunk)
    return {name: digest.hexdigest() for name, digest in hashes.items()}


enwik_hashes = multi_hash_file(ENWIK9)
enwik_source = {
    "name": "enwik9",
    "bytes": ENWIK9.stat().st_size,
    "md5": enwik_hashes["md5"],
    "sha1": enwik_hashes["sha1"],
    "sha256": enwik_hashes["sha256"],
    "benchmark_description_url": "https://www.mattmahoney.net/dc/textdata.html",
    "hutter_prize_url": "https://prize.hutter1.net/",
    "source_description": (
        "The first 1,000,000,000 bytes of the English Wikipedia "
        "2006-03-03 pages/articles XML dump, as defined by the Large Text "
        "Compression Benchmark."
    ),
    "license_context_url": "https://dumps.wikimedia.org/legal.html",
    "included_license_files": enwik_license_rows,
}
write_json(enwik_dir / "SOURCE.json", enwik_source)
(enwik_dir / "README.md").write_text(
    """# enwik9

This package contains the exact 1,000,000,000-byte `enwik9` benchmark file.

It is the first one billion bytes of the English Wikipedia
2006-03-03 pages/articles XML dump, distributed for compression benchmarking.

The package preserves:

- the published MD5 and SHA-1 identifiers;
- a SHA-256 identifier;
- links to the benchmark definition and Hutter Prize;
- Wikimedia licensing context;
- CC BY-SA 3.0 and GNU FDL 1.3 license texts.

Users redistributing or adapting the content must follow the applicable
Wikipedia/Wikimedia attribution and share-alike requirements.
""",
    encoding="utf-8",
)
write_manifest(enwik_dir)
enwik_zip = RELEASES / "enwik9_with_source_and_licenses.zip"
deterministic_zip(enwik_dir, enwik_zip)

suite = {
    "suite_name": "MDLBSG_HF_LICENSED_CORPORA_V1",
    "built_utc": BUILD_UTC,
    "python_version": platform.python_version(),
    "corpora": suite_rows,
    "enwik9_release": {
        **enwik_source,
        "zip": enwik_zip.name,
        "zip_bytes": enwik_zip.stat().st_size,
        "zip_sha256": sha256_file(enwik_zip),
    },
}
write_json(OUT / "BUILD_MANIFEST.json", suite)

table = []
for row in suite_rows:
    table.append(
        "| `{}` | `{}` | {:,} | {:,} | `{}` |".format(
            row["corpus_name"],
            row["dataset_repo"],
            row["accepted_rows"],
            row["logical_file_bytes_before_manifest"],
            ", ".join(row["declared_licenses"]),
        )
    )

(OUT / "README.md").write_text(
    """# MDLBSG License-Preserving Hugging Face Corpus Suite V1

This suite was built for reproducible lossless-compression benchmarking.

| Corpus | Hugging Face source | Accepted rows | Corpus bytes | Declared licenses |
|---|---|---:|---:|---|
"""
    + "\n".join(table)
    + """

Each corpus directory includes its exact dataset card, pinned source revision,
license text/reference files, build policy, source metadata, and SHA-256
manifest. The documentation files remain inside the folder that MDLBSG
compresses.

`release_assets/` contains deterministic ZIPs suitable for publication.
`enwik9_with_source_and_licenses.zip` packages the standard enwik9 file with
source and licensing documentation.

The source dataset card remains authoritative when its wording differs from
short license labels in Hub metadata.
""",
    encoding="utf-8",
)

# Preserve the exact installed builder script if it is available at the expected path.
candidate = Path.home() / "Downloads" / "BUILD_MDLBSG_HF_LICENSED_CORPORA_V1.command"
if candidate.is_file():
    shutil.copy2(candidate, OUT / candidate.name)

# Top-level manifest excludes the environment/cache directories.
clean_tree(OUT)
top_rows = []
for path in sorted(
    (
        p for p in OUT.rglob("*")
        if p.is_file()
        and ".builder_venv" not in p.parts
        and ".hf_cache" not in p.parts
        and p.name not in {"SHA256SUMS.txt", "BUILD_LOG.txt"}
    ),
    key=lambda p: p.relative_to(OUT).as_posix().encode("utf-8"),
):
    top_rows.append(f"{sha256_file(path)}  {path.relative_to(OUT).as_posix()}")
(OUT / "SHA256SUMS.txt").write_text("\n".join(top_rows) + "\n", encoding="utf-8")

print()
print("CORPUS BUILD PASS")
for row in suite_rows:
    print(
        f"{row['corpus_name']}: revision={row['resolved_revision']} "
        f"rows={row['accepted_rows']} data_bytes={row['accepted_data_bytes']} "
        f"zip={row['corpus_zip']} zip_sha256={row['corpus_zip_sha256']}"
    )
print(
    f"enwik9: zip={enwik_zip.name} "
    f"zip_sha256={sha256_file(enwik_zip)}"
)
PY

echo
echo "[3/6] Removing only builder caches from the publishable suite..."

rm -rf "$VENV" "$CACHE"

echo "      caches removed: PASS"

echo
echo "[4/6] Verifying top-level checksums..."

(
  cd "$OUT"
  /usr/bin/shasum -a 256 -c SHA256SUMS.txt >/dev/null
)

echo "      checksum manifest: PASS"

echo
echo "[5/6] Verifying release ZIPs..."

for zip in "$OUT"/release_assets/*.zip; do
  /usr/bin/unzip -t "$zip" >/dev/null \
    || fail "ZIP integrity failed: $zip"
  echo "      $(basename "$zip"): PASS"
done

echo
echo "[6/6] Final result..."

echo
echo "============================================================"
echo "LICENSE-PRESERVING CORPUS SUITE COMPLETE"
echo "============================================================"
echo
echo "Corpus folders used by the benchmark:"
echo "$OUT/corpora"
echo
echo "GitHub release assets:"
echo "$OUT/release_assets"
echo
echo "Build manifest:"
echo "$OUT/BUILD_MANIFEST.json"
echo
echo "Next run:"
echo "RUN_MDLBSG_V0_1_HF_LICENSED_CORPORA_BENCHMARK.command"
echo

/usr/bin/open -R "$OUT" 2>/dev/null || true
