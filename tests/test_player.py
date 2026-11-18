"""Unit tests for the pure parts of the Zero Eyes player (bin/zero-eyes)."""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
_STATE = tempfile.mkdtemp(prefix="zero-eyes-test-")
os.environ["ZERO_EYES_STATE_DIR"] = _STATE

_loader = importlib.machinery.SourceFileLoader("zero_eyes", str(ROOT / "bin" / "zero-eyes"))
_spec = importlib.util.spec_from_loader("zero_eyes", _loader)
ze = importlib.util.module_from_spec(_spec)
_loader.exec_module(ze)


class CleanTextTests(unittest.TestCase):
    def test_strips_markdown(self):
        text = "## Title\n**bold** and `code` and [label](https://x.y)"
        self.assertEqual(ze.clean_text_for_speech(text), "Title bold and code and label")

    def test_code_block_and_url(self):
        text = "See ```\nprint(1)\n``` at https://example.com now"
        self.assertEqual(ze.clean_text_for_speech(text),
                         "See Code block omitted. at link now")

    def test_symbol_only_text(self):
        self.assertEqual(ze.clean_text_for_speech("=="), "equals")
        self.assertEqual(ze.clean_text_for_speech("***"), "")
        self.assertEqual(ze.clean_text_for_speech(""), "")


class TableTests(unittest.TestCase):
    def test_table_is_read_row_by_row(self):
        text = ("Before.\n"
                "| Name | Size |\n"
                "|---|---|\n"
                "| a | 1 |\n"
                "| b | 2 |\n"
                "After.")
        self.assertEqual(ze.clean_text_for_speech(text),
                         "Before. Table. Name: a, Size: 1. Name: b, Size: 2. "
                         "End of table. After.")

    def test_empty_cell_is_skipped(self):
        text = "| Name | Note |\n|:-|-:|\n| a |  |\n"
        self.assertEqual(ze.clean_text_for_speech(text), "Table. Name: a. End of table.")


class SplitChunksTests(unittest.TestCase):
    def test_short_first_part_then_larger_parts(self):
        sentence = "This sentence is exactly forty chars ok."
        chunks = ze.split_chunks(" ".join([sentence] * 20))
        self.assertLessEqual(len(chunks[0]), 160)
        self.assertTrue(all(len(c) <= 250 for c in chunks[1:]))
        self.assertEqual(" ".join(chunks), " ".join([sentence] * 20))


class QueueCapTests(unittest.TestCase):
    def setUp(self):
        ze.clear_queue()

    def test_only_newest_waiting_items_are_kept(self):
        with mock.patch.object(ze, "detect_origin", return_value="test"):
            for i in range(ze.QUEUE_WAITING_MAX + 3):
                ze.enqueue(f"item {i}", "voice")
        self.assertEqual(ze.queue_size(), ze.QUEUE_WAITING_MAX)
        texts = []
        while (item := ze.pop_next()) is not None:
            texts.append(item["text"])
        self.assertEqual(texts, [f"item {i}" for i in range(3, 3 + ze.QUEUE_WAITING_MAX)])


if __name__ == "__main__":
    unittest.main()
