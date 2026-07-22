#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


HOME = Path.home()
MDL_ROOT = HOME / ".mdlbsg"
BIN = MDL_ROOT / "bin"

HANDLER = BIN / "mdlbsg_droplet_handler.sh"
PROGRESS_HELPER = BIN / "mdlbsg_progress_window"
DETACHED_LAUNCHER = BIN / "mdlbsg_detached_spawn"
RESULTS_DIALOG = MDL_ROOT / "results_dialog.applescript"
LOG_PATH = MDL_ROOT / "launch.log"


def log(message: str) -> None:
    MDL_ROOT.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")

    with LOG_PATH.open("a", encoding="utf-8") as handle:
        handle.write(f"{timestamp} app86-worker {message}\n")


def format_seconds(seconds: float) -> str:
    value = max(0, int(seconds))

    if value < 60:
        return f"{value}s"

    if value < 3600:
        return f"{value // 60}m {value % 60}s"

    hours = value // 3600
    minutes = (value % 3600) // 60
    return f"{hours}h {minutes}m"


def one_decimal(value: float) -> str:
    return f"{value:.1f}"


def atomic_write(path: Path, text: str) -> None:
    temporary = path.with_name(
        f"{path.name}.tmp.{os.getpid()}.{uuid.uuid4().hex}"
    )

    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def write_state(
    state_path: Path,
    percent: float,
    title: str,
    detail: str,
) -> None:
    percent = min(100.0, max(0.0, percent))

    atomic_write(
        state_path,
        f"{percent:.2f}\n{title}\n{detail}\n",
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

        if process is not None and process.poll() is not None:
            return False

        time.sleep(0.05)

    return path.exists()


def read_progress(path: Path) -> tuple[int, int] | None:
    try:
        words = path.read_text(
            encoding="utf-8",
            errors="replace",
        ).split()

        if len(words) < 2:
            return None

        done = int(float(words[0]))
        total = int(float(words[1]))

        if total <= 0:
            return None

        return done, total
    except (OSError, ValueError):
        return None


def stop_process_group(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass

    try:
        process.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


def close_progress_window(
    helper: subprocess.Popen[bytes],
    state_path: Path,
    closed_path: Path,
) -> None:
    try:
        atomic_write(state_path, "CLOSE\n")
    except OSError:
        pass

    acknowledged = wait_for_file(
        closed_path,
        timeout=8.0,
        process=helper,
    )

    if not acknowledged and helper.poll() is None:
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

    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(message)

    subprocess.run(
        [
            str(DETACHED_LAUNCHER),
            "/usr/bin/osascript",
            str(RESULTS_DIALOG),
            str(result_path),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def verify_runtime() -> None:
    required = [
        HANDLER,
        PROGRESS_HELPER,
        DETACHED_LAUNCHER,
        RESULTS_DIALOG,
    ]

    missing = [str(path) for path in required if not path.exists()]

    if missing:
        raise RuntimeError(
            "Missing required MDLBSG components:\n"
            + "\n".join(missing)
        )

    for executable in [
        HANDLER,
        PROGRESS_HELPER,
        DETACHED_LAUNCHER,
    ]:
        if not os.access(executable, os.X_OK):
            raise RuntimeError(
                f"Required component is not executable: {executable}"
            )


def run_job(destination: Path, paths: list[Path]) -> int:
    verify_runtime()

    tag = f"{os.getpid()}_{uuid.uuid4().hex}"

    state_path = Path(tempfile.gettempdir()) / f"mdlbsg_ui_{tag}"
    cancel_path = state_path.with_suffix(".cancel")
    closed_path = state_path.with_suffix(".closed")
    ready_path = state_path.with_suffix(".ready")

    cleanup_paths = [
        state_path,
        cancel_path,
        closed_path,
        ready_path,
    ]

    for path in cleanup_paths:
        path.unlink(missing_ok=True)

    write_state(
        state_path,
        0,
        "Preparing MDLBSG compression",
        "Preparing...",
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

    outputs: list[str] = []
    cancelled = False

    try:
        if not wait_for_file(
            ready_path,
            timeout=8.0,
            process=helper,
        ):
            raise RuntimeError(
                "The fresh progress window did not become ready."
            )

        log(
            f"started items={len(paths)} "
            f"destination={destination}"
        )

        for index, source_path in enumerate(paths, start=1):
            short_name = source_path.name or str(source_path)

            if len(paths) > 1:
                title = (
                    f"Compressing {short_name} "
                    f"({index} of {len(paths)})"
                )
            else:
                title = f"Compressing {short_name}"

            progress_file = (
                Path(tempfile.gettempdir())
                / f"mdlbsg_prog_{tag}_{index}"
            )

            progress_file.unlink(missing_ok=True)

            write_state(
                state_path,
                0,
                title,
                "Preparing...",
            )

            started = time.monotonic()
            encode_started: float | None = None

            process = subprocess.Popen(
                [
                    "/bin/bash",
                    str(HANDLER),
                    str(source_path),
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

            while process.poll() is None:
                if cancel_path.exists():
                    cancelled = True

                    write_state(
                        state_path,
                        0,
                        title,
                        "Stopping...",
                    )

                    stop_process_group(process)
                    break

                elapsed = time.monotonic() - started
                current = read_progress(progress_file)

                if current is None:
                    detail = (
                        f"Preparing... {format_seconds(elapsed)}"
                    )

                    if elapsed > 5:
                        detail += (
                            "   -   Large files/folders 1 GB or more "
                            "may take around 30 seconds or more to "
                            "begin compression!"
                        )

                    write_state(
                        state_path,
                        0,
                        title,
                        detail,
                    )
                else:
                    done_bytes, total_bytes = current

                    if encode_started is None and done_bytes > 0:
                        encode_started = time.monotonic()

                    percent = min(
                        100.0,
                        max(
                            0.0,
                            (done_bytes / total_bytes) * 100.0,
                        ),
                    )

                    done_mb = done_bytes / 1_000_000
                    total_mb = total_bytes / 1_000_000

                    line = (
                        f"{percent:.0f}% complete"
                        f"   -   {one_decimal(done_mb)}"
                        f" of {one_decimal(total_mb)} MB"
                        f"   -   Time passed: "
                        f"{format_seconds(elapsed)}"
                    )

                    if (
                        encode_started is not None
                        and done_bytes > 0
                    ):
                        encode_elapsed = max(
                            0.001,
                            time.monotonic() - encode_started,
                        )

                        speed = done_mb / encode_elapsed

                        line += (
                            f"   -   {one_decimal(speed)} MB/s"
                        )

                        if speed > 0:
                            remaining_mb = max(
                                0.0,
                                total_mb - done_mb,
                            )

                            eta = remaining_mb / speed

                            line += (
                                f"   -   ETA: "
                                f"{format_seconds(eta)}"
                            )
                    else:
                        line += "   -   ETA: estimating..."

                    write_state(
                        state_path,
                        percent,
                        title,
                        line,
                    )

                time.sleep(0.25)

            output, _ = process.communicate()
            progress_file.unlink(missing_ok=True)

            output = output.strip()

            if cancelled:
                outputs.append(f"Cancelled: {short_name}")
                break

            if process.returncode != 0 and not output:
                output = (
                    f"Compression failed for {short_name} "
                    f"with status {process.returncode}."
                )

            if not output:
                output = f"Finished: {short_name}"

            outputs.append(output)

        if cancelled:
            final_message = "\n\n".join(outputs) or "Cancelled."
        else:
            write_state(
                state_path,
                100,
                "MDLBSG Compressor",
                "Compression complete. Closing progress window...",
            )

            final_message = "\n\n".join(outputs) or "Finished."

    except Exception as exc:
        log(f"ERROR {type(exc).__name__}: {exc}")
        final_message = f"Error: {exc}"

    finally:
        close_progress_window(
            helper,
            state_path,
            closed_path,
        )

        for path in cleanup_paths:
            path.unlink(missing_ok=True)

    # This happens only after the progress helper confirmed that
    # its window closed and its process exited.
    launch_statistics(final_message)

    log("completed progress-closed-before-statistics=yes")

    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        print("MDLBSG_APP86_WORKER_SELF_TEST_PASS")
        return 0

    parser = argparse.ArgumentParser(
        description="MDLBSG independent UI worker",
    )

    parser.add_argument(
        "--dest",
        required=True,
        help="Destination folder",
    )

    parser.add_argument(
        "paths",
        nargs="+",
        help="Files or folders to compress",
    )

    arguments = parser.parse_args()

    destination = Path(arguments.dest).expanduser()
    paths = [Path(value).expanduser() for value in arguments.paths]

    return run_job(destination, paths)


if __name__ == "__main__":
    raise SystemExit(main())
