"""Tests for the Antigravity watcher, on a synthetic conversation database."""
import os
import sqlite3
import tempfile
import time
import unittest
import importlib.machinery
import importlib.util

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_loader = importlib.machinery.SourceFileLoader(
    "zero_eyes_antigravity",
    os.path.join(ROOT, "integrations", "antigravity", "zero-eyes-antigravity.py"))
_spec = importlib.util.spec_from_loader("zero_eyes_antigravity", _loader)
ag = importlib.util.module_from_spec(_spec)
_loader.exec_module(ag)


def varint(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        if n:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    return varint(number << 3 | 2) + varint(len(value)) + value


def payload(kind, status, text=None, tool=False):
    reply = b""
    if text is not None:
        reply += field(1, text.encode())
    if tool:
        reply += field(7, field(1, b"run_command"))
    body = field(1, kind) + field(4, status)
    if kind == ag.REPLY:
        body += field(20, reply)
    return body


class AntigravityTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.spoken = []
        self.clock = time.time()

    def db(self, name="c.db"):
        path = os.path.join(self.dir, name)
        db = sqlite3.connect(path)
        db.execute("create table if not exists steps (idx integer primary key,"
                   " step_type integer, status integer, step_payload blob)")
        return path, db

    def add(self, db, idx, kind, status, **kw):
        db.execute("insert or replace into steps values (?,?,?,?)",
                   (idx, kind, status, payload(kind, status, **kw)))
        db.commit()

    def touch(self, path):
        self.clock += 10
        os.utime(path, (self.clock, self.clock))

    def test_final_text(self):
        self.assertEqual(ag.final_text(payload(15, 3, text="Done.")), "Done.")
        self.assertIsNone(ag.final_text(payload(15, 3, text="Next.", tool=True)))
        self.assertIsNone(ag.final_text(payload(15, 3, tool=True)))
        self.assertIsNone(ag.final_text(b"\xff\xff"))

    def test_speaks_only_new_final_answers(self):
        path, db = self.db()
        self.add(db, 0, 14, 3)
        self.add(db, 1, 15, 3, text="Old answer.")
        watcher = ag.Watcher(self.dir, self.spoken.append)

        self.add(db, 2, 14, 3)
        self.add(db, 3, 15, 3, text="Let me check.", tool=True)
        self.add(db, 4, 132, 3)
        self.add(db, 5, 15, 3, text="New answer.")
        self.touch(path)
        watcher.poll()
        self.assertEqual(self.spoken, ["New answer."])

        watcher.poll()
        self.assertEqual(self.spoken, ["New answer."])

    def test_waits_for_reply_in_progress(self):
        path, db = self.db()
        watcher = ag.Watcher(self.dir, self.spoken.append)

        self.add(db, 0, 14, 3)
        self.add(db, 1, 15, 1, text="Half")
        self.touch(path)
        watcher.poll()
        self.assertEqual(self.spoken, [])

        self.add(db, 1, 15, 3, text="Half and whole.")
        self.touch(path)
        watcher.poll()
        self.assertEqual(self.spoken, ["Half and whole."])

    def test_new_conversation_after_start(self):
        watcher = ag.Watcher(self.dir, self.spoken.append)
        path, db = self.db("new.db")
        self.add(db, 0, 14, 3)
        self.add(db, 1, 15, 3, text="First answer.")
        watcher.poll()
        self.assertEqual(self.spoken, ["First answer."])

    def test_closed_wal_file(self):
        """Antigravity leaves WAL-mode files with no -wal or -shm file."""
        watcher = ag.Watcher(self.dir, self.spoken.append)
        path, db = self.db("wal.db")
        db.execute("pragma journal_mode=wal")
        self.add(db, 0, 14, 3)
        self.add(db, 1, 15, 3, text="From a closed file.")
        db.execute("pragma wal_checkpoint(truncate)")
        db.close()
        for side in ("-wal", "-shm"):
            if os.path.exists(path + side):
                os.remove(path + side)
        watcher.poll()
        self.assertEqual(self.spoken, ["From a closed file."])


if __name__ == "__main__":
    unittest.main()
