#!/usr/bin/env python3
"""Download multiple files from a list of URLs.
Example:
  ./scripts/bulk-download.py -f urls.txt -o media/downloads/completed/Movies -j 4
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urlparse
from urllib.request import Request, urlopen

ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_OUT = ROOT_DIR / "media" / "downloads" / "http"
USER_AGENT = "MediaServer-bulk-download/1.0"
CHUNK_SIZE = 1024 * 256

_print_lock = threading.Lock()
_name_lock = threading.Lock()
_reserved: set[Path] = set()


def log(message: str) -> None:
    with _print_lock:
        print(message, flush=True)


def parse_line(line: str) -> tuple[str, str | None] | None:
    text = line.strip()
    if not text or text.startswith("#"):
        return None
    parts = text.split(maxsplit=1)
    url = parts[0]
    name = parts[1].strip() if len(parts) > 1 else None
    if name == "":
        name = None
    return url, name


def load_jobs(url_file: str | None, urls: list[str]) -> list[tuple[str, str | None]]:
    jobs: list[tuple[str, str | None]] = []
    if url_file is not None:
        handle = sys.stdin if url_file == "-" else open(url_file, encoding="utf-8")
        try:
            for line in handle:
                parsed = parse_line(line)
                if parsed is not None:
                    jobs.append(parsed)
        finally:
            if handle is not sys.stdin:
                handle.close()
    for url in urls:
        parsed = parse_line(url)
        if parsed is not None:
            jobs.append(parsed)
    return jobs


def sanitize_name(name: str) -> str:
    name = unquote(name).replace("\\", "/").split("/")[-1].strip()
    name = re.sub(r"[\x00-\x1f]", "", name)
    name = name.replace("..", ".")
    if name in {"", ".", ".."}:
        return ""
    return name[:180]


def name_from_disposition(header: str | None) -> str:
    if not header:
        return ""
    star = re.search(r"filename\*\s*=\s*([^']*)''([^;]+)", header, re.IGNORECASE)
    if star:
        return sanitize_name(star.group(2).strip().strip('"'))
    plain = re.search(r'filename\s*=\s*"([^"]+)"', header, re.IGNORECASE)
    if plain:
        return sanitize_name(plain.group(1))
    plain = re.search(r"filename\s*=\s*([^;]+)", header, re.IGNORECASE)
    if plain:
        return sanitize_name(plain.group(1).strip().strip('"'))
    return ""


def name_from_url(url: str) -> str:
    path = unquote(urlparse(url).path)
    return sanitize_name(Path(path).name)


def fallback_name(url: str) -> str:
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:12]
    return f"download-{digest}"


def part_path_for(final_path: Path) -> Path:
    return Path(str(final_path) + ".part")


def path_taken(final_path: Path) -> bool:
    return final_path.exists() or part_path_for(final_path).exists() or final_path in _reserved


def reserve_path(directory: Path, filename: str) -> Path:
    """Pick a free final path and reserve it for this process. Caller holds _name_lock."""
    candidate = directory / filename
    if not path_taken(candidate):
        _reserved.add(candidate)
        return candidate
    stem = Path(filename).stem
    suffix = Path(filename).suffix
    index = 2
    while True:
        candidate = directory / f"{stem}-{index}{suffix}"
        if not path_taken(candidate):
            _reserved.add(candidate)
            return candidate
        index += 1


def format_bytes(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return f"{int(value)} {unit}"
            return f"{value:.1f} {unit}"
        value /= 1024
    return f"{size} B"


def content_length(headers, status: int) -> int | None:
    if status == 206:
        match = re.search(r"/(\d+)\s*$", headers.get("Content-Range", ""))
        if match:
            return int(match.group(1))
        return None
    raw = headers.get("Content-Length")
    if raw and raw.isdigit():
        return int(raw)
    return None


def choose_destination(
    out_dir: Path,
    filename: str,
    total: int | None,
    skip_existing: bool,
) -> tuple[str, Path]:
    """Return (action, final_path). action is skip, resume, or new."""
    with _name_lock:
        final_path = out_dir / filename
        part_path = part_path_for(final_path)
        if skip_existing and final_path.is_file() and final_path not in _reserved:
            if total is None or final_path.stat().st_size == total:
                return "skip", final_path
        if part_path.is_file() and not final_path.exists() and final_path not in _reserved:
            _reserved.add(final_path)
            return "resume", final_path
        if path_taken(final_path):
            final_path = reserve_path(out_dir, filename)
        else:
            _reserved.add(final_path)
        return "new", final_path


def download_one(
    url: str,
    preferred_name: str | None,
    out_dir: Path,
    timeout: int,
    retries: int,
    skip_existing: bool,
) -> tuple[str, str]:
    """Return (status, detail). status is ok, skipped, or failed."""
    base_headers = {"User-Agent": USER_AGENT}
    hinted_name = sanitize_name(preferred_name or "") or name_from_url(url)
    last_error = "unknown error"
    final_path: Path | None = None

    for attempt in range(1, retries + 1):
        response = None
        try:
            part_path = part_path_for(final_path) if final_path is not None else None
            existing = part_path.stat().st_size if part_path is not None and part_path.is_file() else 0
            headers = dict(base_headers)
            if existing > 0:
                headers["Range"] = f"bytes={existing}-"
            response = urlopen(Request(url, headers=headers), timeout=timeout)
            status = response.getcode() or 200
            total = content_length(response.headers, status)
            remote_name = name_from_disposition(response.headers.get("Content-Disposition"))
            filename = hinted_name or remote_name or fallback_name(url)

            if final_path is None:
                action, final_path = choose_destination(out_dir, filename, total, skip_existing)
                part_path = part_path_for(final_path)
                if action == "skip":
                    return "skipped", f"{final_path.name} đã có"
                if action == "resume" and part_path.is_file():
                    part_size = part_path.stat().st_size
                    if total is not None and part_size == total:
                        response.close()
                        response = None
                        os.replace(part_path, final_path)
                        return "ok", f"{final_path.name} ({format_bytes(part_size)})"
                    if total is not None and part_size > total:
                        existing = 0
                    elif part_size > 0:
                        response.close()
                        response = None
                        ranged = dict(base_headers)
                        ranged["Range"] = f"bytes={part_size}-"
                        response = urlopen(Request(url, headers=ranged), timeout=timeout)
                        status = response.getcode() or 200
                        total = content_length(response.headers, status)
                        existing = part_size

            resume_from = existing if status == 206 else 0
            mode = "ab" if status == 206 else "wb"
            written = resume_from
            assert part_path is not None
            with part_path.open(mode) as handle:
                while True:
                    chunk = response.read(CHUNK_SIZE)
                    if not chunk:
                        break
                    handle.write(chunk)
                    written += len(chunk)

            os.replace(part_path, final_path)
            return "ok", f"{final_path.name} ({format_bytes(written)})"
        except HTTPError as exc:
            last_error = f"HTTP {exc.code} {exc.reason}"
            exc.close()
            if exc.code == 416 and final_path is not None:
                part_path = part_path_for(final_path)
                match = re.search(r"\*/(\d+)", exc.headers.get("Content-Range", ""))
                if (
                    match
                    and part_path.is_file()
                    and part_path.stat().st_size == int(match.group(1))
                ):
                    os.replace(part_path, final_path)
                    return "ok", f"{final_path.name} ({format_bytes(final_path.stat().st_size)})"
            if exc.code in {400, 401, 403, 404, 410}:
                break
        except (URLError, TimeoutError, OSError) as exc:
            reason = exc.reason if isinstance(exc, URLError) and not isinstance(exc, HTTPError) else exc
            last_error = str(getattr(reason, "strerror", None) or reason)
        except Exception as exc:  # noqa: BLE001 — report and retry any transfer error
            last_error = str(exc)
        finally:
            if response is not None:
                response.close()

        if attempt < retries:
            delay = min(30, 2 ** (attempt - 1))
            log(f"thử lại {attempt}/{retries} sau {delay}s: {url} ({last_error})")
            time.sleep(delay)

    return "failed", f"{url} — {last_error}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Download multiple files from URLs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "File URL: each line is a URL. Can add file name after URL.\n"
            "Empty lines and lines starting with # are ignored.\n"
            "Partially downloaded files are saved as <name>.part and resumed on next run."
        ),
    )
    parser.add_argument("urls", nargs="*", help="Direct download URL")
    parser.add_argument(
        "-f",
        "--file",
        dest="url_file",
        help="File containing list of URLs, or '-' to read from stdin",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=DEFAULT_OUT,
        help=f"Directory to save files (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "-j",
        "--jobs",
        type=int,
        default=4,
        help="Number of files to download at once (default: 4)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="Timeout for each read, in seconds (default: 60)",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=3,
        help="Number of retries for each URL (default: 3)",
    )
    parser.add_argument(
        "--no-skip-existing",
        action="store_true",
        help="Download again even if file with same name already exists (save new name)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.jobs < 1:
        print("Number of jobs must be >= 1", file=sys.stderr)
        return 2
    if args.retries < 1:
        print("Number of retries must be >= 1", file=sys.stderr)
        return 2
    if not args.url_file and not args.urls:
        build_parser().print_help()
        return 2

    try:
        jobs = load_jobs(args.url_file, args.urls)
    except OSError as exc:
        print(f"Cannot read list of URLs: {exc}", file=sys.stderr)
        return 2
    if not jobs:
        print("No URLs to download.", file=sys.stderr)
        return 2

    out_dir = args.output.expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    log(f"Download {len(jobs)} files, {args.jobs} threads into {out_dir}")

    ok = skipped = failed = 0
    failures: list[str] = []
    workers = min(args.jobs, len(jobs))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(
                download_one,
                url,
                name,
                out_dir,
                args.timeout,
                args.retries,
                not args.no_skip_existing,
            ): url
            for url, name in jobs
        }
        for future in as_completed(futures):
            status, detail = future.result()
            if status == "ok":
                ok += 1
                log(f"done    {detail}")
            elif status == "skipped":
                skipped += 1
                log(f"skipped {detail}")
            else:
                failed += 1
                failures.append(detail)
                log(f"error   {detail}")

    log(f"Result: {ok} done, {skipped} skipped, {failed} errors, total {len(jobs)}")
    if failures:
        fail_log = out_dir / "bulk-download-failed.txt"
        fail_log.write_text("\n".join(failures) + "\n", encoding="utf-8")
        log(f"Error list: {fail_log}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
