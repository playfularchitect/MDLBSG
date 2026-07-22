#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


HOME = Path.home()
MDL_ROOT = HOME / ".mdlbsg"
BIN = MDL_ROOT / "bin"

DETACHED_LAUNCHER = BIN / "mdlbsg_detached_spawn"
QUEUE_WORKER = BIN / "mdlbsg_queue_worker.py"

QUEUE_ROOT = MDL_ROOT / "queue88"
PENDING_DIR = QUEUE_ROOT / "pending"
PROCESSING_DIR = QUEUE_ROOT / "processing"

ACTIVE_LOCK = QUEUE_ROOT / "active.lock"
GATE_LOCK = QUEUE_ROOT / "submission.gate"
READY_FILE = QUEUE_ROOT / "worker.ready"

LOG_PATH = MDL_ROOT / "launch.log"

RESULTS_PATTERN = (
    r"^/usr/bin/osascript .*[/]results_dialog[.]applescript"
)


def log(message: str) -> None:
    MDL_ROOT.mkdir(parents=True, exist_ok=True)

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(
            f"{timestamp} app88-submit {message}\n"
        )


def ensure_directories() -> None:
    PENDING_DIR.mkdir(parents=True, exist_ok=True)
    PROCESSING_DIR.mkdir(parents=True, exist_ok=True)


def pid_is_alive(pid: int) -> bool:
    if pid <= 1:
        return False

    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

    return True


def read_lock_pid(lock_path: Path) -> int:
    try:
        return int(
            (lock_path / "pid").read_text(
                encoding="utf-8"
            ).strip()
        )
    except (OSError, ValueError):
        return -1


def lock_is_stale(lock_path: Path) -> bool:
    if not lock_path.exists():
        return False

    pid = read_lock_pid(lock_path)

    if pid_is_alive(pid):
        return False

    try:
        age = time.time() - lock_path.stat().st_mtime
    except OSError:
        return True

    return age > 2.0


def acquire_directory_lock(
    lock_path: Path,
    timeout: float,
) -> None:
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        try:
            lock_path.mkdir(parents=False)
            (lock_path / "pid").write_text(
                f"{os.getpid()}\n",
                encoding="utf-8",
            )
            return
        except FileExistsError:
            if lock_is_stale(lock_path):
                shutil.rmtree(
                    lock_path,
                    ignore_errors=True,
                )
                continue

            time.sleep(0.05)

    raise RuntimeError(
        f"Timed out waiting for queue lock: {lock_path}"
    )


def release_directory_lock(lock_path: Path) -> None:
    if read_lock_pid(lock_path) == os.getpid():
        shutil.rmtree(
            lock_path,
            ignore_errors=True,
        )


@contextmanager
def submission_gate() -> Iterator[None]:
    acquire_directory_lock(
        GATE_LOCK,
        timeout=15.0,
    )

    try:
        yield
    finally:
        release_directory_lock(GATE_LOCK)


def close_previous_statistics() -> None:
    subprocess.run(
        [
            "/usr/bin/pkill",
            "-TERM",
            "-f",
            RESULTS_PATTERN,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    time.sleep(0.12)

    subprocess.run(
        [
            "/usr/bin/pkill",
            "-KILL",
            "-f",
            RESULTS_PATTERN,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def write_request(
    destination: Path,
    source: Path,
    sequence: int,
) -> Path:
    submitted_ns = time.time_ns()

    filename = (
        f"{submitted_ns:020d}_"
        f"{os.getpid():08d}_"
        f"{sequence:04d}_"
        f"{uuid.uuid4().hex}.json"
    )

    final_path = PENDING_DIR / filename
    temporary = PENDING_DIR / f".{filename}.tmp"

    payload = {
        "version": 1,
        "submitted_ns": submitted_ns,
        "source": str(source),
        "destination": str(destination),
    }

    temporary.write_text(
        json.dumps(
            payload,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )

    os.replace(temporary, final_path)

    return final_path


def queue_has_work() -> bool:
    return (
        any(PENDING_DIR.glob("*.json"))
        or any(PROCESSING_DIR.glob("*.json"))
    )


def launch_worker() -> None:
    subprocess.run(
        [
            str(DETACHED_LAUNCHER),
            "/usr/bin/python3",
            str(QUEUE_WORKER),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def wait_for_start_acknowledgement() -> None:
    deadline = time.monotonic() + 6.0
    launched_again = False

    while time.monotonic() < deadline:
        if READY_FILE.exists():
            return

        if not queue_has_work():
            # A tiny job may have already completed.
            return

        if (
            not ACTIVE_LOCK.exists()
            and not launched_again
            and time.monotonic() + 4.5 < deadline
        ):
            launch_worker()
            launched_again = True

        time.sleep(0.1)

    if queue_has_work():
        raise RuntimeError(
            "The queue accepted the files, but its worker did not "
            "open. Check ~/.mdlbsg/launch.log."
        )


def verify_runtime() -> None:
    required = [
        DETACHED_LAUNCHER,
        QUEUE_WORKER,
    ]

    missing = [
        str(path)
        for path in required
        if not path.exists()
    ]

    if missing:
        raise RuntimeError(
            "Missing queue runtime:\n"
            + "\n".join(missing)
        )

    for path in required:
        if not os.access(path, os.X_OK):
            raise RuntimeError(
                f"Queue runtime is not executable: {path}"
            )


def submit(
    destination: Path,
    paths: list[Path],
) -> int:
    ensure_directories()
    verify_runtime()

    if not paths:
        raise RuntimeError(
            "No files or folders were submitted."
        )

    with submission_gate():
        close_previous_statistics()

        created = [
            write_request(
                destination=destination,
                source=source,
                sequence=index,
            )
            for index, source in enumerate(paths)
        ]

        launch_worker()

    wait_for_start_acknowledgement()

    log(
        f"queued={len(created)} "
        f"destination={destination}"
    )

    print(
        f"Queued {len(created)} "
        f"item{'s' if len(created) != 1 else ''}."
    )

    return 0


def self_test() -> int:
    ensure_directories()

    print(
        "MDLBSG_APP88_QUEUE_SUBMIT_SELF_TEST_PASS"
    )

    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()

    parser = argparse.ArgumentParser(
        description="Submit items to the MDLBSG queue",
    )

    parser.add_argument(
        "--dest",
        required=True,
        help="Output destination",
    )

    parser.add_argument(
        "paths",
        nargs="+",
        help="Files or folders to enqueue",
    )

    arguments = parser.parse_args()

    return submit(
        destination=Path(
            arguments.dest
        ).expanduser(),
        paths=[
            Path(path).expanduser()
            for path in arguments.paths
        ],
    )


if __name__ == "__main__":
    raise SystemExit(main())
