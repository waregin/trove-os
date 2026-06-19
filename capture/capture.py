#!/usr/bin/env python3
"""Trove capture client — offline-first, crash-safe barcode capture loop.

Issue #1 (move-critical). Scan everything in a box while packing; each code lands
on disk instantly. Reconcile into Trove later (export -> importer). This module does
ZERO network at scan time and is stdlib-only on purpose, so it runs today on Zorin
with no install and keeps working in airplane mode.

Usage:
    python3 capture/capture.py [queue_path]      # default: ./queue.jsonl

While running, type (or scan as control barcodes) one per line:
    BOX <label>      set the current box/location for following scans (persisted)
    TYPE <type>      set the current collection_type (default: print_books)
    DONE             exit cleanly (Ctrl-D / EOF does the same)
    HELP / STATUS    show help / current box+type
Anything else is treated as a scanned code and appended to the queue immediately.

queue.jsonl record (one JSON object per line):
    {"code":"9780553213113","code_type":"isbn","collection":"print_books",
     "box":"kitchen-12","scanned_at":"2026-06-18T17:50:00Z","status":"raw",
     "title":null,"author":null,"ddc":null}
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone

# Valid Trove collection_type values (plural — must match items.collection_type so
# export -> import needs no remapping). Keep in sync with trove_schema.sql / README.
VALID_COLLECTIONS = (
    "print_books", "ebooks", "films", "games", "lego", "plushies",
    "nicky_nacks", "home_inventory", "board_games", "puzzles",
)
DEFAULT_COLLECTION = "print_books"

_COMMANDS = ("BOX", "TYPE", "DONE", "HELP", "STATUS")


def classify_code(code: str) -> str:
    """Cheap heuristic: 13 digits starting 978/979, or 10 digits -> isbn; else upc/unknown.

    Refinement can happen later during resolution — never block capture on this.
    """
    digits = code.strip().replace("-", "").replace(" ", "")
    if not digits.isdigit():
        return "unknown"
    if (len(digits) == 13 and digits[:3] in ("978", "979")) or len(digits) == 10:
        return "isbn"
    return "upc"


def parse_line(raw: str):
    """Classify a line of input.

    Returns one of:
        ("blank", None)            — empty/whitespace-only (an extra Enter); ignored
        ("command", NAME, arg)     — NAME in BOX/TYPE/DONE/HELP/STATUS; arg may be ""
        ("code", code)             — anything else; the scanned code (original case)
    """
    stripped = raw.strip()
    if not stripped:
        return ("blank", None)
    parts = stripped.split(None, 1)
    keyword = parts[0].upper()
    if keyword in _COMMANDS:
        arg = parts[1].strip() if len(parts) > 1 else ""
        return ("command", keyword, arg)
    return ("code", stripped)


def make_record(code: str, collection: str, box, when: datetime) -> dict:
    """Build a queue record. `box` may be None (captured anyway — over-capture beats dropping)."""
    return {
        "code": code,
        "code_type": classify_code(code),
        "collection": collection,
        "box": box,
        "scanned_at": when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": "raw",
        "title": None,
        "author": None,
        "ddc": None,
    }


class CaptureSession:
    """Owns the append-only queue and a small sidecar state file.

    Crash-safety: every scan is written + flushed + fsync'd before we return, so a
    kill (Ctrl-C / kill -9) never loses a prior scan. The active box/type is persisted
    atomically so a restart resumes where you left off.
    """

    def __init__(self, queue_path: str):
        self.queue_path = os.path.abspath(queue_path)
        self.state_path = self.queue_path + ".state.json"
        self.box = None
        self.collection = DEFAULT_COLLECTION
        self._load_state()
        # Append mode: never truncates an existing queue from a previous session.
        self._fh = open(self.queue_path, "a", encoding="utf-8")

    # -- state ---------------------------------------------------------------
    def _load_state(self) -> None:
        try:
            with open(self.state_path, encoding="utf-8") as f:
                state = json.load(f)
            self.box = state.get("box")
            self.collection = state.get("collection") or DEFAULT_COLLECTION
        except (FileNotFoundError, ValueError):
            pass  # first run / corrupt state — start fresh, never crash

    def _save_state(self) -> None:
        tmp = self.state_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"box": self.box, "collection": self.collection}, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.state_path)  # atomic

    # -- capture -------------------------------------------------------------
    def record_code(self, code: str) -> dict:
        rec = make_record(code, self.collection, self.box, datetime.now(timezone.utc))
        self._fh.write(json.dumps(rec, separators=(",", ":"), ensure_ascii=False) + "\n")
        self._fh.flush()
        os.fsync(self._fh.fileno())  # durable before we acknowledge the scan
        return rec

    def set_box(self, label: str) -> None:
        self.box = label
        self._save_state()

    def set_collection(self, collection: str) -> None:
        self.collection = collection
        self._save_state()

    def close(self) -> None:
        try:
            self._fh.close()
        except Exception:
            pass


_HELP = (
    "commands: BOX <label> | TYPE <collection> | DONE | HELP | STATUS\n"
    "  collections: " + ", ".join(VALID_COLLECTIONS) + "\n"
    "  anything else is captured as a scanned code."
)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    queue_path = argv[0] if argv else "queue.jsonl"
    session = CaptureSession(queue_path)

    print(f"trove capture — writing to {session.queue_path}")
    print(f"  box={session.box or '(none — set one with: BOX <label>)'}  type={session.collection}")
    print(_HELP)
    if session.box is None:
        print("warning: no BOX set yet — scans are captured as box=null until you set one.")

    try:
        for raw in sys.stdin:
            kind = parse_line(raw)
            if kind[0] == "blank":
                continue
            if kind[0] == "command":
                _, name, arg = kind
                if name == "DONE":
                    break
                if name == "HELP":
                    print(_HELP)
                elif name == "STATUS":
                    print(f"  box={session.box}  type={session.collection}  queue={session.queue_path}")
                elif name == "BOX":
                    if not arg:
                        print("usage: BOX <label>")
                    else:
                        session.set_box(arg)
                        print(f"  box set -> {arg}")
                elif name == "TYPE":
                    if not arg:
                        print("usage: TYPE <collection>")
                    else:
                        # Accept-with-warning: a typo shouldn't stop packing, but flag it
                        # so items aren't silently misfiled.
                        if arg not in VALID_COLLECTIONS:
                            print(f"  warning: '{arg}' is not a known collection_type — capturing anyway.")
                        session.set_collection(arg)
                        print(f"  type set -> {arg}")
                continue
            # kind[0] == "code"
            try:
                rec = session.record_code(kind[1])
                print(f"  [{rec['box'] or '(unboxed)'}/{rec['collection']}] {rec['code']} ({rec['code_type']})")
            except Exception as exc:  # never crash the loop on a single bad write
                print(f"  ERROR writing scan {kind[1]!r}: {exc}", file=sys.stderr)
    except KeyboardInterrupt:
        # Ctrl-C: prior scans are already durable on disk; just exit.
        print()
    finally:
        session.close()

    print("done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
