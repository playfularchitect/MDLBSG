#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator


HOME = Path.home()
MDL_ROOT = HOME / ".mdlbsg"
BIN = MDL_ROOT / "bin"

HANDLER = BIN / "mdlbsg_droplet_handler.sh"
PROGRESS_HELPER = BIN / "mdlbsg_progress_window"
DETACHED_LAUNCHER = BIN / "mdlbsg_detached_spawn"
RESULTS_DIALOG = MDL_ROOT / "results_dialog.applescript"

QUEUE_ROOT = MDL_ROOT / "queue88"
PENDING_DIR = QUEUE_ROOT / "pending"
PROCESSING_DIR = QUEUE_ROOT / "processing"

ACTIVE_LOCK = QUEUE_ROOT / "active.lock"
GATE_LOCK = QUEUE_ROOT / "submission.gate"
READY_FILE = QUEUE_ROOT / "worker.ready"

LOG_PATH = MDL_ROOT / "launch.log"

EMPTY_GRACE_SECONDS = 1.25


def log(message: str) -> None:
    MDL_ROOT.mkdir(parents=True, exist_ok=True)

    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(
            f"{timestamp} app88-worker {message}\n"
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


def try_acquire_active_lock() -> bool:
    ensure_directories()

    for _ in range(3):
        try:
            ACTIVE_LOCK.mkdir(parents=False)
            (ACTIVE_LOCK / "pid").write_text(
                f"{os.getpid()}\n",
                encoding="utf-8",
            )
            return True
        except FileExistsError:
            if lock_is_stale(ACTIVE_LOCK):
                shutil.rmtree(
                    ACTIVE_LOCK,
                    ignore_errors=True,
                )
                continue

            return False

    return False


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


def recover_processing_requests() -> None:
    ensure_directories()

    for path in sorted(
        PROCESSING_DIR.glob("*.json")
    ):
        destination = PENDING_DIR / path.name

        if destination.exists():
            destination = PENDING_DIR / (
                f"{path.stem}_"
                f"{uuid.uuid4().hex}.json"
            )

        os.replace(path, destination)


def pending_files() -> list[Path]:
    return sorted(
        PENDING_DIR.glob("*.json"),
        key=lambda path: path.name,
    )


def pending_count() -> int:
    return len(pending_files())


def claim_next_request() -> Path | None:
    for path in pending_files():
        claimed = PROCESSING_DIR / path.name

        try:
            os.replace(path, claimed)
            return claimed
        except FileNotFoundError:
            continue

    return None


def load_request(path: Path) -> tuple[Path, Path]:
    payload = json.loads(
        path.read_text(
            encoding="utf-8",
            errors="strict",
        )
    )

    source = Path(
        str(payload["source"])
    ).expanduser()

    destination = Path(
        str(payload["destination"])
    ).expanduser()

    return source, destination


def clear_pending_queue() -> None:
    for path in PENDING_DIR.glob("*.json"):
        path.unlink(missing_ok=True)


def format_seconds(seconds: float) -> str:
    value = max(0, int(seconds))

    if value < 60:
        return f"{value}s"

    if value < 3600:
        return (
            f"{value // 60}m "
            f"{value % 60}s"
        )

    hours = value // 3600
    minutes = (value % 3600) // 60

    return f"{hours}h {minutes}m"


def atomic_write(path: Path, text: str) -> None:
    temporary = path.with_name(
        f"{path.name}.tmp."
        f"{os.getpid()}."
        f"{uuid.uuid4().hex}"
    )

    temporary.write_text(
        text,
        encoding="utf-8",
    )

    os.replace(temporary, path)


def write_state(
    state_path: Path,
    percent: float,
    title: str,
    detail: str,
) -> None:
    percent = min(
        100.0,
        max(0.0, percent),
    )

    atomic_write(
        state_path,
        f"{percent:.2f}\n"
        f"{title}\n"
        f"{detail}\n",
    )


def wait_for_file(
    path: Path,
    timeout: float,
    process: subprocess.Popen[bytes] | None = None,
) -> bool:
    deadline = time.monotonic() + timeout

    while time.monotonic() < deadline:
        if path.exists():
            return True

        if (
            process is not None
            and process.poll() is not None
        ):
            return False

        time.sleep(0.05)

    return path.exists()


def read_progress(
    path: Path,
) -> tuple[int, int] | None:
    try:
        values = path.read_text(
            encoding="utf-8",
            errors="replace",
        ).split()

        if len(values) < 2:
            return None

        done = int(float(values[0]))
        total = int(float(values[1]))

        if total <= 0:
            return None

        return done, total
    except (OSError, ValueError):
        return None


def stop_process_group(
    process: subprocess.Popen[str],
) -> None:
    if process.poll() is not None:
        return

    try:
        os.killpg(
            process.pid,
            signal.SIGTERM,
        )
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass

    try:
        os.killpg(
            process.pid,
            signal.SIGKILL,
        )
    except ProcessLookupError:
        pass

    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


def start_progress_window(
    state_path: Path,
    cancel_path: Path,
    closed_path: Path,
    ready_path: Path,
) -> subprocess.Popen[bytes]:
    write_state(
        state_path,
        0,
        "Preparing MDLBSG compression",
        "Preparing queue...",
    )

    helper = subprocess.Popen(
        [
            str(PROGRESS_HELPER),
            "--state",
            str(state_path),
            "--cancel",
            str(cancel_path),
            "--closed",
            str(closed_path),
            "--ready",
            str(ready_path),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    if not wait_for_file(
        ready_path,
        timeout=8.0,
        process=helper,
    ):
        if helper.poll() is None:
            helper.terminate()

        raise RuntimeError(
            "The progress window did not become ready."
        )

    atomic_write(
        READY_FILE,
        f"{os.getpid()}\n",
    )

    return helper


def close_progress_window(
    helper: subprocess.Popen[bytes],
    state_path: Path,
    closed_path: Path,
) -> None:
    try:
        atomic_write(
            state_path,
            "CLOSE\n",
        )
    except OSError:
        pass

    acknowledged = wait_for_file(
        closed_path,
        timeout=8.0,
        process=helper,
    )

    if (
        not acknowledged
        and helper.poll() is None
    ):
        helper.terminate()

    try:
        helper.wait(timeout=3.0)
    except subprocess.TimeoutExpired:
        helper.kill()
        helper.wait(timeout=2.0)


def launch_statistics(message: str) -> None:
    descriptor, result_name = tempfile.mkstemp(
        prefix="mdlbsg_res_",
        dir=tempfile.gettempdir(),
    )

    result_path = Path(result_name)

    with os.fdopen(
        descriptor,
        "w",
        encoding="utf-8",
    ) as handle:
        handle.write(message)

    subprocess.run(
        [
            str(DETACHED_LAUNCHER),
            "/usr/bin/osascript",
            str(RESULTS_DIALOG),
            str(result_path),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )


def verify_runtime() -> None:
    required = [
        HANDLER,
        PROGRESS_HELPER,
        DETACHED_LAUNCHER,
        RESULTS_DIALOG,
    ]

    missing = [
        str(path)
        for path in required
        if not path.exists()
    ]

    if missing:
        raise RuntimeError(
            "Missing MDLBSG runtime:\n"
            + "\n".join(missing)
        )

    for executable in [
        HANDLER,
        PROGRESS_HELPER,
        DETACHED_LAUNCHER,
    ]:
        if not os.access(
            executable,
            os.X_OK,
        ):
            raise RuntimeError(
                "Runtime is not executable: "
                f"{executable}"
            )


def queue_title(
    source_name: str,
    completed: int,
) -> str:
    current_number = completed + 1
    visible_total = (
        current_number
        + pending_count()
    )

    if visible_total <= 1:
        return f"Compressing {source_name}"

    return (
        f"Compressing {source_name} "
        f"({current_number} of {visible_total})"
    )


def run_one_request(
    source: Path,
    destination: Path,
    completed: int,
    state_path: Path,
    cancel_path: Path,
) -> tuple[str, bool]:
    source_name = source.name or str(source)

    progress_file = (
        Path(tempfile.gettempdir())
        / (
            f"mdlbsg_prog_app88_"
            f"{os.getpid()}_"
            f"{uuid.uuid4().hex}"
        )
    )

    progress_file.unlink(missing_ok=True)

    started = time.monotonic()
    encode_started: float | None = None

    process = subprocess.Popen(
        [
            "/bin/bash",
            str(HANDLER),
            str(source),
            str(progress_file),
            str(destination),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        start_new_session=True,
    )

    cancelled = False

    while process.poll() is None:
        title = queue_title(
            source_name,
            completed,
        )

        if cancel_path.exists():
            cancelled = True

            write_state(
                state_path,
                0,
                title,
                "Stopping current item and clearing queue...",
            )

            stop_process_group(process)
            break

        elapsed = time.monotonic() - started
        current = read_progress(progress_file)
        queued = pending_count()

        if current is None:
            detail = (
                f"Preparing... "
                f"{format_seconds(elapsed)}"
            )

            if elapsed > 5:
                detail += (
                    "   -   Large files/folders 1 GB or more "
                    "may take around 30 seconds or more to "
                    "begin compression!"
                )

            if queued > 0:
                detail += (
                    f"   -   {queued} "
                    f"item{'s' if queued != 1 else ''} queued"
                )

            write_state(
                state_path,
                0,
                title,
                detail,
            )
        else:
            done_bytes, total_bytes = current

            if (
                encode_started is None
                and done_bytes > 0
            ):
                encode_started = time.monotonic()

            percent = min(
                100.0,
                max(
                    0.0,
                    (
                        done_bytes
                        / total_bytes
                    )
                    * 100.0,
                ),
            )

            done_mb = done_bytes / 1_000_000
            total_mb = total_bytes / 1_000_000

            detail = (
                f"{percent:.0f}% complete"
                f"   -   {done_mb:.1f}"
                f" of {total_mb:.1f} MB"
                f"   -   Time passed: "
                f"{format_seconds(elapsed)}"
            )

            if (
                encode_started is not None
                and done_bytes > 0
            ):
                encode_elapsed = max(
                    0.001,
                    time.monotonic()
                    - encode_started,
                )

                speed = done_mb / encode_elapsed

                detail += (
                    f"   -   {speed:.1f} MB/s"
                )

                if speed > 0:
                    eta = max(
                        0.0,
                        total_mb - done_mb,
                    ) / speed

                    detail += (
                        f"   -   ETA: "
                        f"{format_seconds(eta)}"
                    )
            else:
                detail += (
                    "   -   ETA: estimating..."
                )

            if queued > 0:
                detail += (
                    f"   -   {queued} queued"
                )

            write_state(
                state_path,
                percent,
                title,
                detail,
            )

        time.sleep(0.25)

    output, _ = process.communicate()
    progress_file.unlink(missing_ok=True)

    output = output.strip()

    if cancelled:
        return (
            f"Cancelled: {source_name}",
            True,
        )

    if process.returncode != 0 and not output:
        output = (
            f"Compression failed for {source_name} "
            f"with status {process.returncode}."
        )

    if not output:
        output = f"Finished: {source_name}"

    return output, False


def launch_recovery_worker() -> None:
    subprocess.run(
        [
            str(DETACHED_LAUNCHER),
            "/usr/bin/python3",
            str(Path(__file__).resolve()),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )


def run_queue() -> int:
    ensure_directories()
    verify_runtime()

    if not try_acquire_active_lock():
        return 0

    helper: subprocess.Popen[bytes] | None = None

    state_path: Path | None = None
    cancel_path: Path | None = None
    closed_path: Path | None = None
    helper_ready_path: Path | None = None

    outputs: list[str] = []
    completed = 0
    cancelled_all = False

    try:
        recover_processing_requests()

        first_deadline = (
            time.monotonic() + 1.0
        )

        while (
            not pending_files()
            and time.monotonic() < first_deadline
        ):
            time.sleep(0.05)

        if not pending_files():
            return 0

        tag = (
            f"{os.getpid()}_"
            f"{uuid.uuid4().hex}"
        )

        state_path = (
            Path(tempfile.gettempdir())
            / f"mdlbsg_ui_app88_{tag}"
        )

        cancel_path = Path(
            f"{state_path}.cancel"
        )
        closed_path = Path(
            f"{state_path}.closed"
        )
        helper_ready_path = Path(
            f"{state_path}.ready"
        )

        for path in [
            state_path,
            cancel_path,
            closed_path,
            helper_ready_path,
        ]:
            path.unlink(missing_ok=True)

        helper = start_progress_window(
            state_path,
            cancel_path,
            closed_path,
            helper_ready_path,
        )

        log(
            f"worker-started "
            f"pending={pending_count()}"
        )

        empty_since: float | None = None

        while True:
            request_path = claim_next_request()

            if request_path is None:
                if cancelled_all:
                    break

                if empty_since is None:
                    empty_since = time.monotonic()

                empty_for = (
                    time.monotonic()
                    - empty_since
                )

                if empty_for < EMPTY_GRACE_SECONDS:
                    write_state(
                        state_path,
                        100,
                        "MDLBSG Compressor",
                        "Finishing queue...",
                    )

                    time.sleep(0.1)
                    continue

                with submission_gate():
                    if pending_files():
                        empty_since = None
                        continue

                    write_state(
                        state_path,
                        100,
                        "MDLBSG Compressor",
                        "Queue complete. Closing progress window...",
                    )

                    close_progress_window(
                        helper,
                        state_path,
                        closed_path,
                    )

                    helper = None
                    READY_FILE.unlink(missing_ok=True)

                    final_message = (
                        "\n\n".join(outputs)
                        if outputs
                        else "Finished."
                    )

                    launch_statistics(
                        final_message
                    )

                break

            empty_since = None

            try:
                source, destination = load_request(
                    request_path
                )

                result, cancelled = run_one_request(
                    source=source,
                    destination=destination,
                    completed=completed,
                    state_path=state_path,
                    cancel_path=cancel_path,
                )

                outputs.append(result)
                completed += 1

                if cancelled:
                    cancelled_all = True

                    with submission_gate():
                        clear_pending_queue()

                    break
            except Exception as exc:
                outputs.append(
                    "Error processing queued item: "
                    f"{type(exc).__name__}: {exc}"
                )

                log(
                    "request-error "
                    f"{type(exc).__name__}: {exc}"
                )

                completed += 1
            finally:
                request_path.unlink(
                    missing_ok=True
                )

        if cancelled_all:
            with submission_gate():
                if helper is not None:
                    write_state(
                        state_path,
                        100,
                        "MDLBSG Compressor",
                        "Queue cancelled. Closing progress window...",
                    )

                    close_progress_window(
                        helper,
                        state_path,
                        closed_path,
                    )

                    helper = None
                    READY_FILE.unlink(
                        missing_ok=True
                    )

                launch_statistics(
                    "\n\n".join(outputs)
                    if outputs
                    else "Cancelled."
                )

        log(
            f"worker-finished "
            f"completed={completed}"
        )

        return 0

    except Exception as exc:
        log(
            "worker-fatal "
            f"{type(exc).__name__}: {exc}"
        )

        READY_FILE.unlink(missing_ok=True)

        if helper is not None:
            try:
                close_progress_window(
                    helper,
                    state_path,
                    closed_path,
                )
            except Exception:
                pass

            helper = None

        try:
            launch_statistics(
                f"Error: {type(exc).__name__}: {exc}"
            )
        except Exception:
            pass

        return 1

    finally:
        READY_FILE.unlink(missing_ok=True)

        if helper is not None:
            try:
                close_progress_window(
                    helper,
                    state_path,
                    closed_path,
                )
            except Exception:
                pass

        for path in [
            state_path,
            cancel_path,
            closed_path,
            helper_ready_path,
        ]:
            if path is not None:
                path.unlink(missing_ok=True)

        release_directory_lock(ACTIVE_LOCK)

        if pending_files():
            launch_recovery_worker()


def self_test() -> int:
    ensure_directories()

    print(
        "MDLBSG_APP88_QUEUE_WORKER_SELF_TEST_PASS"
    )

    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()

    return run_queue()


if __name__ == "__main__":
    raise SystemExit(main())
