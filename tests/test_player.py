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

    def test_edge_groups_four_sentences_per_part(self):
        sentences = [f"Sentence {i}." for i in range(1, 11)]
        chunks = ze.split_chunks(" ".join(sentences), engine="edge")
        self.assertEqual(len(chunks), 3)
        self.assertEqual(chunks[0], "Sentence 1. Sentence 2. Sentence 3. Sentence 4.")
        self.assertEqual(chunks[1], "Sentence 5. Sentence 6. Sentence 7. Sentence 8.")
        self.assertEqual(chunks[2], "Sentence 9. Sentence 10.")

        short = ze.split_chunks("One. Two. Three.", engine="edge")
        self.assertEqual(short, ["One. Two. Three."])

    def test_speech_text_with_origin(self):
        self.assertEqual(ze.speech_text_with_origin("Done.", "Antigravity"), "Antigravity. Done.")
        self.assertEqual(ze.speech_text_with_origin("Done.", "Claude!"), "Claude. Done.")
        self.assertEqual(ze.speech_text_with_origin("Antigravity is ready.", "Antigravity"),
                         "Antigravity is ready.")
        self.assertEqual(ze.speech_text_with_origin("Done.", "Read aloud"), "Done.")
        self.assertEqual(ze.speech_text_with_origin("Done.", "Zero Eyes"), "Done.")
        self.assertEqual(ze.speech_text_with_origin("Done.", ""), "Done.")

    def test_drain_waits_answer_gap_between_separate_answers(self):
        ze.clear_queue()
        with mock.patch.object(ze, "detect_origin", return_value="Antigravity"):
            ze.enqueue("First answer.", "voice")
            ze.enqueue("Second answer.", "voice")
        calls = []
        with mock.patch.object(ze, "ensure_overlay"), \
             mock.patch.object(ze, "play_item", side_effect=lambda item, cfg: calls.append(("play", item["text"]))), \
             mock.patch.object(ze, "wait_answer_gap", side_effect=lambda: calls.append(("gap", ze.ANSWER_GAP))):
            ze.drain()
        self.assertEqual(calls, [
            ("play", "First answer."),
            ("gap", ze.ANSWER_GAP),
            ("play", "Second answer."),
        ])


class EngineTests(unittest.TestCase):
    def test_named_engines_are_kept(self):
        for engine in ("apple", "edge", "say"):
            self.assertEqual(ze.resolve_engine(engine, "darwin"), engine)
        self.assertEqual(ze.resolve_engine(" Edge ", "darwin"), "edge")

    def test_auto_empty_and_unknown_mean_apple(self):
        for value in ("auto", "", None, "bogus", "piper", "espeak"):
            self.assertEqual(ze.resolve_engine(value, "darwin", piper_ready=True), "apple")

    def test_default_engine_is_apple(self):
        with mock.patch.object(ze, "CONFIG_FILE", os.path.join(_STATE, "no-config")), \
             mock.patch.object(ze, "IS_MAC", True), \
             mock.patch.dict(os.environ, {"ZERO_EYES_ENGINE": ""}):
            cfg = ze.load_config()
        self.assertEqual(cfg["ENGINE"], "apple")
        self.assertEqual(cfg["APPLE_VOICE"], "")


class LinuxEngineTests(unittest.TestCase):
    def test_local_engine_is_piper_when_ready(self):
        for value in ("auto", "", None, "apple", "say", "bogus", "piper"):
            self.assertEqual(ze.resolve_engine(value, "linux", piper_ready=True), "piper")

    def test_local_engine_is_espeak_without_piper(self):
        for value in ("auto", "apple", "piper", "espeak"):
            self.assertEqual(ze.resolve_engine(value, "linux", piper_ready=False), "espeak")

    def test_named_engines_are_kept(self):
        self.assertEqual(ze.resolve_engine("Edge", "linux", piper_ready=True), "edge")
        self.assertEqual(ze.resolve_engine("espeak", "linux", piper_ready=True), "espeak")

    def test_default_engine_is_auto(self):
        with mock.patch.object(ze, "CONFIG_FILE", os.path.join(_STATE, "no-config")), \
             mock.patch.object(ze, "IS_MAC", False), \
             mock.patch.dict(os.environ, {"ZERO_EYES_ENGINE": ""}):
            cfg = ze.load_config()
        self.assertEqual(cfg["ENGINE"], "auto")
        self.assertEqual(cfg["PIPER_MODEL"], "")

    def test_piper_ready_needs_binary_and_model(self):
        model = os.path.join(_STATE, "voice.onnx")
        open(model, "w").close()
        self.assertTrue(ze.piper_ready(model, which=lambda n: "/usr/bin/piper"))
        self.assertFalse(ze.piper_ready(model, which=lambda n: None))
        self.assertFalse(ze.piper_ready(model + ".missing", which=lambda n: "/usr/bin/piper"))
        self.assertFalse(ze.piper_ready("", which=lambda n: "/usr/bin/piper"))

    def test_piper_model_survives_save(self):
        path = os.path.join(_STATE, "config-save")
        with open(path, "w") as f:
            f.write('PIPER_MODEL="~/voices/en.onnx"\n')
        with mock.patch.object(ze, "CONFIG_FILE", path):
            ze.save_config({"RATE": "+10%"})
            self.assertEqual(ze.load_config()["PIPER_MODEL"], "~/voices/en.onnx")


class StateDirTests(unittest.TestCase):
    def test_macos(self):
        self.assertEqual(ze.default_state_dir("darwin", {}),
                         os.path.expanduser("~/Library/Application Support/Zero Eyes"))

    def test_linux_xdg(self):
        self.assertEqual(ze.default_state_dir("linux", {"XDG_STATE_HOME": "/x/state"}),
                         "/x/state/zero-eyes")

    def test_linux_default_and_relative_xdg(self):
        expected = os.path.expanduser("~/.local/state/zero-eyes")
        self.assertEqual(ze.default_state_dir("linux", {}), expected)
        self.assertEqual(ze.default_state_dir("linux", {"XDG_STATE_HOME": "rel"}), expected)


class AudioPlayerTests(unittest.TestCase):
    @staticmethod
    def which_of(*names):
        return lambda n: f"/usr/bin/{n}" if n in names else None

    def test_macos_is_afplay(self):
        self.assertEqual(ze.audio_player("m4a", "darwin", self.which_of()), ["/usr/bin/afplay"])

    def test_wav_order(self):
        all_players = ("paplay", "pw-play", "ffplay", "mpv", "aplay")
        self.assertEqual(ze.audio_player("wav", "linux", self.which_of(*all_players)),
                         ["/usr/bin/paplay"])
        self.assertEqual(ze.audio_player("wav", "linux", self.which_of(*all_players[1:])),
                         ["/usr/bin/pw-play"])
        self.assertEqual(ze.audio_player("wav", "linux", self.which_of("ffplay", "aplay")),
                         ["/usr/bin/ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"])
        self.assertEqual(ze.audio_player("wav", "linux", self.which_of("mpv", "aplay")),
                         ["/usr/bin/mpv", "--no-video", "--really-quiet"])
        self.assertEqual(ze.audio_player("wav", "linux", self.which_of("aplay")),
                         ["/usr/bin/aplay", "-q"])
        self.assertIsNone(ze.audio_player("wav", "linux", self.which_of()))

    def test_mp3_needs_ffplay_or_mpv(self):
        self.assertIsNone(ze.audio_player("mp3", "linux",
                                          self.which_of("paplay", "pw-play", "aplay")))
        self.assertEqual(ze.audio_player("mp3", "linux", self.which_of("paplay", "mpv")),
                         ["/usr/bin/mpv", "--no-video", "--really-quiet"])


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

    def test_rate_to_length_scale(self):
        self.assertEqual(ze.rate_to_length_scale("+0%"), 1.0)
        self.assertEqual(ze.rate_to_length_scale("+25%"), 0.8)
        self.assertEqual(ze.rate_to_length_scale("-50%"), 2.0)
        self.assertEqual(ze.rate_to_length_scale("+300%"), 0.4)  # clamped at 2.5x
        self.assertIsNone(ze.rate_to_length_scale("fast"))

    def test_piper_synth_args(self):
        self.assertEqual(ze.piper_synth_args("/m/en.onnx", "+25%", "/tmp/x.wav"),
                         ["piper", "--model", "/m/en.onnx", "--length_scale", "0.8",
                          "--output_file", "/tmp/x.wav"])
        self.assertEqual(ze.piper_synth_args("/m/en.onnx", "odd", "/tmp/x.wav"),
                         ["piper", "--model", "/m/en.onnx", "--output_file", "/tmp/x.wav"])

    def test_espeak_synth_args(self):
        self.assertEqual(ze.espeak_synth_args("/usr/bin/espeak-ng", "", "+20%", "/tmp/x.wav"),
                         ["/usr/bin/espeak-ng", "-s", "210", "-w", "/tmp/x.wav", "--stdin"])
        self.assertEqual(ze.espeak_synth_args("espeak", "hi", "-50%", "/tmp/x.wav"),
                         ["espeak", "-v", "hi", "-s", "90", "-w", "/tmp/x.wav", "--stdin"])

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

    def test_stray_devanagari_punctuation_keeps_english_voice(self):
        self.assertFalse(ze.has_devanagari("Split on regex । and speak 1 2 3."))
        self.assertEqual(ze.select_voice("Split on regex । and speak 1 2 3.", "en-IN-PrabhatNeural"),
                         "en-IN-PrabhatNeural")
        self.assertEqual(ze.select_voice("नमस्ते दुनिया", "en-IN-PrabhatNeural"),
                         "hi-IN-MadhurNeural")


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


class AppVolumeTests(unittest.TestCase):
    def test_percent_parsing_and_clamping(self):
        self.assertEqual(ze.app_volume_percent("100"), 100)
        self.assertEqual(ze.app_volume_percent("65%"), 65)
        self.assertEqual(ze.app_volume_percent("-10"), 0)
        self.assertEqual(ze.app_volume_percent("250"), 100)
        self.assertEqual(ze.app_volume_percent("bogus"), 100)

    def test_scale_curve(self):
        self.assertEqual(ze.app_volume_scale(0), 0.0)
        self.assertEqual(ze.app_volume_scale(50), 0.25)
        self.assertEqual(ze.app_volume_scale(100), 1.0)

    def test_player_with_volume_applies_only_to_player(self):
        self.assertEqual(ze.player_with_volume(["/usr/bin/afplay"], 100), ["/usr/bin/afplay"])
        self.assertEqual(ze.player_with_volume(["/usr/bin/afplay"], 50),
                         ["/usr/bin/afplay", "-v", "0.25"])
        self.assertEqual(ze.player_with_volume(["/usr/bin/afplay"], 0),
                         ["/usr/bin/afplay", "-v", "0"])
        self.assertEqual(ze.player_with_volume(["/usr/bin/mpv", "--no-video"], 40),
                         ["/usr/bin/mpv", "--no-video", "--volume=40"])

    def test_say_args_with_volume(self):
        self.assertEqual(ze.say_args("hi", "+0%", volume=100), ["/usr/bin/say", "-r", "175", "hi"])
        self.assertEqual(ze.say_args("hi", "+0%", volume=50),
                         ["/usr/bin/say", "-r", "175", "[[volm 0.25]] hi"])

    def test_adjust_volume_persists_without_losing_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "config")
            with open(path, "w") as f:
                f.write('RATE="+20%"\nREPLY_SUBMIT="true"\n')
            with mock.patch.object(ze, "CONFIG_FILE", path):
                self.assertEqual(ze.adjust_volume(target=60), "60%")
                self.assertEqual(ze.adjust_volume(delta=-15), "45%")
                self.assertEqual(ze.adjust_volume(delta=-90), "0%")
                self.assertEqual(ze.adjust_volume(delta=150), "100%")
                self.assertEqual(ze.adjust_volume(target=75), "75%")
                cfg = ze.load_config()
        self.assertEqual(cfg["APP_VOLUME"], "75")
        self.assertEqual(cfg["RATE"], "+20%")
        self.assertEqual(cfg["REPLY_SUBMIT"], "true")


if __name__ == "__main__":
    unittest.main()
