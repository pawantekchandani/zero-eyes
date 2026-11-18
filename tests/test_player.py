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


class EngineTests(unittest.TestCase):
    def test_named_engines_are_kept(self):
        for engine in ("apple", "edge", "say"):
            self.assertEqual(ze.resolve_engine(engine), engine)
        self.assertEqual(ze.resolve_engine(" Edge "), "edge")

    def test_auto_empty_and_unknown_mean_apple(self):
        for value in ("auto", "", None, "bogus"):
            self.assertEqual(ze.resolve_engine(value), "apple")

    def test_default_engine_is_apple(self):
        with mock.patch.object(ze, "CONFIG_FILE", os.path.join(_STATE, "no-config")), \
             mock.patch.dict(os.environ, {"ZERO_EYES_ENGINE": ""}):
            cfg = ze.load_config()
        self.assertEqual(cfg["ENGINE"], "apple")
        self.assertEqual(cfg["APPLE_VOICE"], "")


class RateTests(unittest.TestCase):
    def test_rate_to_wpm(self):
        self.assertEqual(ze.rate_to_wpm("+0%"), 175)
        self.assertEqual(ze.rate_to_wpm("+20%"), 210)
        self.assertEqual(ze.rate_to_wpm("-50%"), 90)   # clamped
        self.assertEqual(ze.rate_to_wpm("+200%"), 420)  # clamped
        self.assertIsNone(ze.rate_to_wpm("fast"))

    def test_apple_synth_args(self):
        self.assertEqual(
            ze.apple_synth_args("com.apple.voice.compact.en-IN.Rishi", "+20%", "/tmp/x"),
            ["/usr/bin/say", "-v", "com.apple.voice.compact.en-IN.Rishi", "-r", "210",
             "--file-format=m4af", "--data-format=aac", "-o", "/tmp/x"])
        self.assertEqual(ze.apple_synth_args("", "odd", "/tmp/x"),
                         ["/usr/bin/say", "--file-format=m4af", "--data-format=aac", "-o", "/tmp/x"])

    def test_say_args_unchanged(self):
        self.assertEqual(ze.say_args("hi", "+0%"), ["/usr/bin/say", "-r", "175", "hi"])


# Shape of the osascript voice list: identifier, a tab, the locale.
SAMPLE_VOICES = "\n".join([
    "com.apple.speech.synthesis.voice.Albert\ten_US",
    "com.apple.voice.compact.en-IN.Rishi\ten_IN",
    "com.apple.voice.Aman.premium\ten_IN",          # Siri voice: not usable by say
    "com.apple.voice.enhanced.en-GB.Daniel\ten_GB",
    "com.apple.voice.premium.en-US.Zoe\ten_US",
    "com.apple.voice.premium.de-DE.Anna\tde_DE",
    "com.apple.voice.compact.hi-IN.Lekha\thi_IN",
    "",
])


class AppleVoiceTests(unittest.TestCase):
    def setUp(self):
        self.voices = ze.parse_apple_voices(SAMPLE_VOICES)

    def test_parse(self):
        self.assertEqual(len(self.voices), 7)
        self.assertEqual(self.voices[1], ("com.apple.voice.compact.en-IN.Rishi", "en-IN"))

    def test_quality(self):
        self.assertEqual(ze.apple_voice_quality("com.apple.voice.premium.en-US.Zoe"), 3)
        self.assertEqual(ze.apple_voice_quality("com.apple.voice.enhanced.en-GB.Daniel"), 2)
        self.assertEqual(ze.apple_voice_quality("com.apple.voice.Aman.premium"), 1)
        self.assertEqual(ze.apple_voice_quality("com.apple.voice.compact.en-IN.Rishi"), 1)

    def test_premium_english_wins(self):
        self.assertEqual(ze.apple_voice_for("Hello.", "", self.voices),
                         "com.apple.voice.premium.en-US.Zoe")

    def test_enhanced_when_no_premium(self):
        voices = [v for v in self.voices if ".premium." not in v[0]]
        self.assertEqual(ze.apple_voice_for("Hello.", "", voices),
                         "com.apple.voice.enhanced.en-GB.Daniel")

    def test_compact_only_means_system_voice(self):
        voices = [v for v in self.voices if "compact" in v[0] or "Aman" in v[0]]
        self.assertEqual(ze.apple_voice_for("Hello.", "", voices), "")

    def test_configured_voice_wins_for_english(self):
        self.assertEqual(ze.apple_voice_for("Hello.", "Samantha", self.voices), "Samantha")

    def test_devanagari_uses_hindi_voice(self):
        self.assertEqual(ze.apple_voice_for("नमस्ते दुनिया", "Samantha", self.voices),
                         "com.apple.voice.compact.hi-IN.Lekha")

    def test_devanagari_without_hindi_voice_uses_default(self):
        voices = [v for v in self.voices if not v[1].startswith("hi")]
        self.assertEqual(ze.apple_voice_for("नमस्ते", "", voices),
                         "com.apple.voice.premium.en-US.Zoe")


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


class ReplyTests(unittest.TestCase):
    def test_clean_transcript_drops_non_speech_markers(self):
        out = "[BLANK_AUDIO]\n Please run the tests (music) again. *sighs*\n"
        self.assertEqual(ze.clean_transcript(out), "Please run the tests again.")

    def test_clean_transcript_of_only_markers_is_empty(self):
        self.assertEqual(ze.clean_transcript(" [BLANK_AUDIO] \n"), "")

    def test_reply_settings_defaults(self):
        settings = ze.reply_settings({})
        self.assertEqual(settings["model"], os.path.join(ze.MODELS_DIR, ze.WHISPER_MODEL_NAME))
        self.assertTrue(settings["default_model"])
        self.assertEqual(settings["language"], "en")
        self.assertFalse(settings["submit"])
        self.assertEqual(settings["silence"], 2.0)

    def test_reply_settings_from_config(self):
        settings = ze.reply_settings({
            "REPLY_MODEL": "~/models/ggml-small.bin",
            "REPLY_LANGUAGE": "hi",
            "REPLY_SUBMIT": "true",
            "REPLY_SILENCE": "0",
        })
        self.assertEqual(settings["model"], os.path.expanduser("~/models/ggml-small.bin"))
        self.assertFalse(settings["default_model"])
        self.assertEqual(settings["language"], "hi")
        self.assertTrue(settings["submit"])
        self.assertEqual(settings["silence"], 0.0)

    def test_reply_settings_bad_silence_falls_back(self):
        self.assertEqual(ze.reply_settings({"REPLY_SILENCE": "soon"})["silence"], 2.0)
        self.assertEqual(ze.reply_settings({"REPLY_SILENCE": "-3"})["silence"], 0.0)

    def test_whisper_command(self):
        self.assertEqual(
            ze.whisper_command("/bin/whisper-cli", "/m.bin", "/r.wav", "en"),
            ["/bin/whisper-cli", "-m", "/m.bin", "-f", "/r.wav", "-l", "en", "-nt", "-np"],
        )

    def test_save_config_keeps_reply_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config")
            with open(path, "w") as f:
                f.write('MUTED="false"\nREPLY_SUBMIT="true"\nREPLY_LANGUAGE="hi"\n')
            with mock.patch.object(ze, "CONFIG_FILE", path):
                cfg = ze.load_config()
                cfg["MUTED"] = "true"
                ze.save_config(cfg)
                saved = ze.load_config()
        self.assertEqual(saved["MUTED"], "true")
        self.assertEqual(saved["REPLY_SUBMIT"], "true")
        self.assertEqual(saved["REPLY_LANGUAGE"], "hi")


if __name__ == "__main__":
    unittest.main()
