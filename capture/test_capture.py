#!/usr/bin/env python3
"""Tests for the capture loop — proves issue #1 acceptance criteria. Stdlib only.

Run:  python3 -m unittest discover -s capture
"""

import json
import os
import tempfile
import unittest

import capture


class CodeTypeHeuristic(unittest.TestCase):
    def test_isbn13_979_and_978(self):
        self.assertEqual(capture.classify_code("9780553213113"), "isbn")
        self.assertEqual(capture.classify_code("979-8-6024-0153-6"), "isbn")  # hyphens ignored

    def test_isbn10(self):
        self.assertEqual(capture.classify_code("0553213113"), "isbn")

    def test_upc_12_and_ean13_non_isbn(self):
        self.assertEqual(capture.classify_code("036000291452"), "upc")   # 12-digit UPC-A
        self.assertEqual(capture.classify_code("4006381333931"), "upc")  # 13-digit, not 978/979

    def test_unknown(self):
        self.assertEqual(capture.classify_code("LEGO-10290"), "unknown")
        self.assertEqual(capture.classify_code(""), "unknown")


class LineParsing(unittest.TestCase):
    def test_blank_lines_ignored(self):
        self.assertEqual(capture.parse_line("\n")[0], "blank")
        self.assertEqual(capture.parse_line("   \n")[0], "blank")

    def test_commands_case_insensitive_with_args(self):
        self.assertEqual(capture.parse_line("box kitchen-12"), ("command", "BOX", "kitchen-12"))
        self.assertEqual(capture.parse_line("TYPE board_games"), ("command", "TYPE", "board_games"))
        self.assertEqual(capture.parse_line("done"), ("command", "DONE", ""))

    def test_code_preserves_original(self):
        self.assertEqual(capture.parse_line("9780553213113\n"), ("code", "9780553213113"))


def read_queue(path):
    with open(path, encoding="utf-8") as f:
        return [json.loads(line) for line in f if line.strip()]


class SessionDurability(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.queue = os.path.join(self.dir, "queue.jsonl")

    def test_each_scan_is_durable_immediately(self):
        s = capture.CaptureSession(self.queue)
        s.set_box("kitchen-12")
        s.record_code("9780553213113")
        # Read from a *separate* handle to prove the line is flushed, not buffered.
        rows = read_queue(self.queue)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["code"], "9780553213113")
        self.assertEqual(rows[0]["box"], "kitchen-12")
        self.assertEqual(rows[0]["code_type"], "isbn")
        self.assertEqual(rows[0]["status"], "raw")
        self.assertIsNone(rows[0]["title"])
        s.close()

    def test_restart_resumes_box_and_type_and_appends(self):
        s1 = capture.CaptureSession(self.queue)
        s1.set_box("garage-3")
        s1.set_collection("board_games")
        s1.record_code("111")
        s1.close()  # simulate kill; data already on disk

        s2 = capture.CaptureSession(self.queue)  # restart
        self.assertEqual(s2.box, "garage-3")          # resumed
        self.assertEqual(s2.collection, "board_games")  # resumed
        s2.record_code("222")
        s2.close()

        rows = read_queue(self.queue)
        self.assertEqual([r["code"] for r in rows], ["111", "222"])  # append, not truncate
        self.assertTrue(all(r["box"] == "garage-3" for r in rows))

    def test_fifty_rapid_scans_no_drops(self):
        s = capture.CaptureSession(self.queue)
        s.set_box("books-7")
        codes = [str(9780000000000 + i) for i in range(50)]
        for c in codes:
            s.record_code(c)
        s.close()
        rows = read_queue(self.queue)
        self.assertEqual(len(rows), 50)
        self.assertEqual([r["code"] for r in rows], codes)  # order preserved, none merged
        self.assertTrue(all(r["box"] == "books-7" for r in rows))


if __name__ == "__main__":
    unittest.main()
