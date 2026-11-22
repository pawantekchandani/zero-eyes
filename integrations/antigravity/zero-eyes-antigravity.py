#!/usr/bin/env python3
"""Antigravity watcher: speak each finished Antigravity answer with Zero Eyes.

Antigravity has no hook or plugin event for a finished answer, so this watcher
reads what Antigravity saves. Each conversation is one SQLite file in
~/.gemini/antigravity/conversations/, with one row per step in the `steps` table.

The step payload is protobuf. Google does not document it; these fields were
read from real conversations:

    1   step type     14 = user message, 15 = model reply, 132 = tool call
    4   status        3 = done
    20  the reply     20.1 = text shown to the user, 20.7 = tool calls

A done model reply with text and no tool call ends the turn. That text is sent
to the player, once. Older answers are never read back: conversations that
exist when the watcher starts are spoken only from their next answer.

Load: every 3 seconds the watcher reads the modification time of each file in
the folder. It opens a conversation only when its file changed, reads only the
new rows, and leaves tool-call payloads unread.

If Antigravity changes this format, the watcher goes quiet. It never writes to
Antigravity's files.

    zero-eyes-antigravity            # run (the LaunchAgent does this)
    zero-eyes-antigravity --once     # one pass, print what would be spoken
"""
import os
import sqlite3
import subprocess
import sys
import time

PLAYER = os.path.expanduser("~/.local/bin/zero-eyes")
CONVERSATIONS = os.path.expanduser("~/.gemini/antigravity/conversations")
ORIGIN = "Antigravity"
INTERVAL = 3.0

REPLY, DONE = 15, 3


def _varint(buf, i):
    value = shift = 0
    while True:
        byte = buf[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return value, i


def fields(buf):
    """Top-level protobuf fields as (number, value). Raises ValueError if malformed."""
    out, i = [], 0
    try:
        while i < len(buf):
            key, i = _varint(buf, i)
            number, wire = key >> 3, key & 7
            if wire == 0:
                value, i = _varint(buf, i)
            elif wire == 1:
                value, i = buf[i:i + 8], i + 8
            elif wire == 5:
                value, i = buf[i:i + 4], i + 4
            elif wire == 2:
                size, i = _varint(buf, i)
                value, i = buf[i:i + size], i + size
            else:
                raise ValueError(f"wire type {wire}")
            if number == 0 or i > len(buf):
                raise ValueError("bad field")
            out.append((number, value))
    except IndexError:
        raise ValueError("truncated") from None
    return out


def final_text(payload):
    """The answer text if this payload is a reply that ends the turn, else None."""
    try:
        reply = next((v for n, v in fields(payload) if n == 20), None)
        if not isinstance(reply, bytes):
            return None
        parts = fields(reply)
    except ValueError:
        return None
    if any(n == 7 for n, _ in parts):
        return None
    text = next((v for n, v in parts if n == 1 and isinstance(v, bytes)), None)
    if not text:
        return None
    try:
        return text.decode("utf-8").strip() or None
    except UnicodeDecodeError:
        return None


def last_idx(path):
    try:
        with _open(path) as db:
            row = db.execute("select max(idx) from steps").fetchone()
    except sqlite3.Error:
        return -1
    return row[0] if row and row[0] is not None else -1


def _open(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)


def new_answers(path, after):
    """(answers, new watermark) for rows after `after`.

    The last row is left for the next pass while it is still being written, so
    a reply is read only once it is done.
    """
    try:
        with _open(path) as db:
            rows = db.execute(
                "select idx, step_type, status,"
                " case when step_type = ? then step_payload end"
                " from steps where idx > ? order by idx",
                (REPLY, after)).fetchall()
    except sqlite3.Error:
        return [], after
    answers = []
    for k, (idx, kind, status, payload) in enumerate(rows):
        is_last = k == len(rows) - 1
        if kind == REPLY and status == DONE:
            text = final_text(payload or b"")
            if text:
                answers.append(text)
        elif is_last and kind == REPLY:
            break
        after = idx
    return answers, after


def speak(text):
    env = dict(os.environ, ZERO_EYES_ORIGIN=ORIGIN)
    try:
        subprocess.run([PLAYER], input=text, text=True, env=env, timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        pass


def changed_files(folder):
    """{conversation path: newest mtime of the .db and its -wal file}."""
    stamps = {}
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return stamps
    for entry in entries:
        name = entry.name
        if name.endswith(".db"):
            path = entry.path
        elif name.endswith(".db-wal"):
            path = entry.path[:-4]
        else:
            continue
        try:
            mtime = entry.stat().st_mtime_ns
        except OSError:
            continue
        stamps[path] = max(stamps.get(path, 0), mtime)
    return stamps


class Watcher:
    def __init__(self, folder, say):
        self.folder = folder
        self.say = say
        self.stamps = changed_files(folder)
        self.marks = {path: last_idx(path) for path in self.stamps}

    def poll(self):
        stamps = changed_files(self.folder)
        for path, mtime in stamps.items():
            if self.stamps.get(path) == mtime:
                continue
            answers, self.marks[path] = new_answers(path, self.marks.get(path, -1))
            for text in answers:
                self.say(text)
        for gone in set(self.marks) - set(stamps):
            del self.marks[gone]
        self.stamps = stamps


def main():
    if "--once" in sys.argv:
        for path in sorted(changed_files(CONVERSATIONS)):
            answers, _ = new_answers(path, -1)
            if answers:
                print(f"{os.path.basename(path)}: {answers[-1][:100]!r}")
        return 0
    watcher = Watcher(CONVERSATIONS, speak)
    while True:
        time.sleep(INTERVAL)
        watcher.poll()


if __name__ == "__main__":
    sys.exit(main())
