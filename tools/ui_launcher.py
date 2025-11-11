#!/usr/bin/env python3
# JirehFaith SWP Kit — Single-Screen Launcher (Brand)
# Flow:
#   UI text/JSON → WAV (piper profile) → SRT →
#   render_swp_unified.sh (ASS normalize/repair + CenterBox → burn)
#
# Modes:
#  A) Autosync mode (default): json_to_srt → unified renderer with AUTOSYNC/TEMPO_MATCH/ONSET on.
#  B) Sentence-locked mode (new): build SRT from input lines via make_sentence_even_srt.sh,
#     then render with AUTOSYNC=0 TEMPO_MATCH=0 AUTO_ONSET_ALIGN=0 APPLY_SHIFT_TO_AUDIO=0.
#
# Poster button uses Open-Title + Font size + Output Size + Emotion BG.
# IMPORTANT: For video renders we FORCE TOP_BANNER='' (no title over captions).

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
from pathlib import Path
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

APP_ROOT = Path(__file__).resolve().parent.parent
TOOLS_DIR = APP_ROOT / "tools"
ASSETS_BG_DIR = APP_ROOT / "assets" / "bg"        # 1080x1920 (vertical)
ASSETS_BG_H_DIR = APP_ROOT / "assets" / "bg_h"    # 1920x1080 (horizontal)
ASSETS_BRAND_DIR = APP_ROOT / "assets" / "brand"
OUT_DEFAULT = APP_ROOT / "out"
VOICE_BUILD_DIR = APP_ROOT / "voice" / "build"
VOICE_WAVS_DIR = APP_ROOT / "voice" / "wavs"
VOICE_PROFILES_DIR = APP_ROOT / "voice" / "profiles"
VOICE_SCRIPT_DIR = APP_ROOT / "voice" / "script"   # for sentence-locked input lines

PIPER_EXE = APP_ROOT / "piper" / "piper.exe"
MAKE_POSTER = TOOLS_DIR / "make_title_poster.sh"
RENDER_UNIFIED = TOOLS_DIR / "render_swp_unified.sh"
MAKE_SENTENCE_EVEN = TOOLS_DIR / "make_sentence_even_srt.sh"

def _resolve_json_to_srt() -> Path:
    candidates = [
        APP_ROOT / "tools" / "json_to_srt.py",    # preferred
        APP_ROOT / "scripts" / "json_to_srt.py",  # legacy
    ]
    for c in candidates:
        if c.exists():
            return c
    return APP_ROOT / "scripts" / "json_to_srt.py"

JSON_TO_SRT = _resolve_json_to_srt()

# Brand accents
JF_PURPLE = "#6C3BAA"
JF_GOLD   = "#e6b800"
JF_BG     = "#f8f7fb"
JF_TEXT   = "#1a1a1a"

# Emotions (ensure PNGs exist in assets/bg/*.png and assets/bg_h/*.png)
EMOTIONS = [
    "ANGER", "ANXIETY", "DESPAIR", "FEAR", "FINANCIAL_TRIALS",
    "GRIEF", "HOPE", "ILLNESS", "JOY", "LOVE",
    "PERSEVERANCE", "RELATIONSHIP_TRIALS", "PEACE", "SUCCESS", "PROTECTION"
]

# Voices (anchored trio)
VOICE_LABELS = ["AMY", "BRYCE", "RYAN"]
LANGS = ["EN", "ES", "FR", "PT"]

PROFILE_MAP = {
    "AMY":   VOICE_PROFILES_DIR / "female-default.env",
    "BRYCE": VOICE_PROFILES_DIR / "male-default.env",
    "RYAN":  VOICE_PROFILES_DIR / "male-ryan.env",
}

def _detect_git_bash_path() -> str:
    p = os.environ.get("GIT_BASH")
    if p and os.path.isfile(p):
        return p
    for c in [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        r"C:\Program Files\Git\usr\bin\bash.exe",
        r"C:\Program Files (x86)\Git\usr\bin\bash.exe",
    ]:
        if os.path.isfile(c):
            return c
    try:
        out = subprocess.check_output(["where", "bash"], text=True, stderr=subprocess.DEVNULL)
        for ln in [x.strip() for x in out.splitlines() if x.strip()]:
            if ln.lower().endswith("bash.exe") and os.path.isfile(ln):
                return ln
    except Exception:
        pass
    return "bash"

def norm_path_for_bash(p: Path) -> str:
    s = str(p)
    if os.name == "nt":
        drive, tail = os.path.splitdrive(s)
        if drive:
            drive_letter = drive[0].lower()
            tail = tail.replace("\\", "/").lstrip("\\/")
            return f"/{drive_letter}/{tail}"
        return s.replace("\\", "/")
    return s

def msys_to_win(path_str: str) -> str:
    """Convert /c/... to C:\\...; leave Win paths unchanged."""
    if not path_str:
        return path_str
    s = path_str.strip()
    if len(s) > 2 and s[1] == ':' and (s[2] == '\\' or s[2] == '/'):
        return s.replace('/', '\\')
    if s.startswith('/'):
        parts = s.split('/', 3)
        if len(parts) >= 3 and len(parts[1]) == 1:
            drive = parts[1].upper()
            tail = parts[2] if len(parts) == 3 else parts[2] + ('/' + parts[3] if len(parts) > 3 else '')
            return f"{drive}:\\" + tail.replace('/', '\\')
    return s.replace('/', '\\')

def ensure_dirs():
    OUT_DEFAULT.mkdir(parents=True, exist_ok=True)
    VOICE_BUILD_DIR.mkdir(parents=True, exist_ok=True)
    VOICE_WAVS_DIR.mkdir(parents=True, exist_ok=True)
    VOICE_SCRIPT_DIR.mkdir(parents=True, exist_ok=True)

def load_profile_env(path: Path) -> dict:
    needed = {"MODEL_PATH", "CONFIG_PATH", "LENGTH_SCALE", "NOISE_SCALE", "NOISE_W"}
    env = {}
    for ln in path.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#") or "=" not in ln:
            continue
        k, v = ln.split("=", 1)
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k in needed:
            env[k] = v
    missing = [k for k in needed if k not in env]
    if missing:
        raise RuntimeError(f"Profile {path} missing keys: {', '.join(missing)}")
    env["MODEL_PATH"] = msys_to_win(env["MODEL_PATH"])
    env["CONFIG_PATH"] = msys_to_win(env["CONFIG_PATH"])
    return env

def build_text_from_json(json_path: Path) -> str:
    d = json.loads(json_path.read_text(encoding="utf-8"))
    lines = d.get("lines", [])
    if isinstance(lines, str):
        lines = [ln.strip() for ln in lines.splitlines() if ln.strip()]
    return " ".join(lines)

def write_tmp_json_from_text(emotion: str, lang: str, voice: str, text: str, base: str) -> Path:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    if not lines:
        raise ValueError("Prayer text is empty. Provide JSON or enter lines in the text box.")
    data = {
        "emotion": emotion.lower(),
        "language": lang,
        "verse_tag": "",
        "voice": voice.lower(),
        "lines": lines
    }
    tmp_json = VOICE_BUILD_DIR / f"{base}.ui_tmp.json"
    tmp_json.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return tmp_json

# -------- UI --------
class Launcher(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("JirehFaith SWP Kit — Launcher")
        self.geometry("1120x980")
        self.minsize(1020, 820)
        self.configure(bg=JF_BG)

        ensure_dirs()

        # State
        self.var_voice = tk.StringVar(value=VOICE_LABELS[0])
        self.var_emotion = tk.StringVar(value=EMOTIONS[0])
        self.var_lang = tk.StringVar(value=LANGS[0])
        self.var_size = tk.StringVar(value="1080x1920")   # Default = Shorts (vertical)
        self.var_font_size = tk.IntVar(value=120)         # caption/poster font size
        self.var_caption_shift = tk.IntVar(value=-500)    # captions lead audio (ms); negative = earlier
        self.var_verse = tk.StringVar(value="")
        self.var_json_path = tk.StringVar(value="")
        self.var_out_dir = tk.StringVar(value=str(OUT_DEFAULT))
        self.var_title = tk.StringVar(value="anxiety_en_amy")
        self.var_auto_title = tk.BooleanVar(value=True)
        self.var_open_title = tk.StringVar(value="")      # Poster only
        # New: Sentence-locked mode + pacing controls
        self.var_sentence_locked = tk.BooleanVar(value=False)
        self.var_gap_ms = tk.IntVar(value=180)            # GAP_MS for sentence SRT builder
        self.var_min_ms = tk.IntVar(value=1000)           # MIN_MS for sentence SRT builder

        for v in (self.var_voice, self.var_emotion, self.var_lang):
            v.trace_add("write", lambda *_: self._maybe_auto_title())

        self._build_ui()

        self.proc = None
        self.log_queue = queue.Queue()
        self.log_thread = None
        self._stop_reader = threading.Event()

        self._maybe_auto_title(force=True)

    def _build_ui(self):
        pad = 10

        # Header
        header = tk.Frame(self, bg=JF_PURPLE); header.pack(fill="x", side="top")
        banner_path = ASSETS_BRAND_DIR / "top-T.png"
        self._banner_img = None
        try:
            if banner_path.exists():
                self._banner_img = tk.PhotoImage(file=str(banner_path))
                tk.Label(header, image=self._banner_img, bg=JF_PURPLE).pack(side="top", pady=0)
            else:
                self._brand_bar(header)
        finally:
            tk.Frame(header, bg=JF_GOLD, height=3).pack(fill="x", side="bottom")

        # Card
        card = tk.Frame(self, bg="white", bd=0, highlightthickness=1, highlightbackground="#e7e2f3")
        card.pack(fill="both", expand=True, padx=pad, pady=(6, pad))

        frm = tk.Frame(card, bg="white"); frm.pack(fill="x", padx=pad, pady=pad)

        # Row 1
        row1 = tk.Frame(frm, bg="white"); row1.pack(fill="x", pady=(0, 6))
        self._lbl(row1, "Voice:").pack(side="left")
        self._combo(row1, self.var_voice, VOICE_LABELS, 10).pack(side="left", padx=(6, 20))

        self._lbl(row1, "Emotion:").pack(side="left")
        self._combo(row1, self.var_emotion, EMOTIONS, 24).pack(side="left", padx=(6, 20))

        self._lbl(row1, "Language:").pack(side="left")
        self._combo(row1, self.var_lang, LANGS, 6).pack(side="left", padx=(6, 20))

        # Output Size
        self._lbl(row1, "Output Size:").pack(side="left")
        self._combo(row1, self.var_size, ["1080x1920", "1920x1080"], 12).pack(side="left", padx=(6, 10))

        # Font size controls
        self._lbl(row1, "Font:").pack(side="left", padx=(6,0))
        tk.Button(row1, text="A-", command=lambda: self._font_bump(-6), width=3, bg="#ffffff").pack(side="left", padx=(4,0))
        self._entry(row1, self.var_font_size, 4).pack(side="left", padx=(4,0))
        tk.Button(row1, text="A+", command=lambda: self._font_bump(+6), width=3, bg="#ffffff").pack(side="left", padx=(4,0))

        # Caption lead (ms) + nudge buttons
        self._lbl(row1, "Lead(ms):").pack(side="left", padx=(10,0))
        tk.Button(row1, text="–50", command=lambda: self._lead_bump(-50), width=4, bg="#ffffff").pack(side="left", padx=(4,0))
        self._entry(row1, self.var_caption_shift, 6).pack(side="left", padx=(4,0))
        tk.Button(row1, text="+50", command=lambda: self._lead_bump(+50), width=4, bg="#ffffff").pack(side="left", padx=(4,10))

        # Row 2
        row2 = tk.Frame(frm, bg="white"); row2.pack(fill="x", pady=(2, 6))
        self._lbl(row2, "Verse tag (optional):").pack(side="left")
        self._entry(row2, self.var_verse, 24).pack(side="left", padx=(6, 20))

        self._lbl(row2, "JSON file (optional):").pack(side="left")
        self._entry(row2, self.var_json_path, 44).pack(side="left", padx=6)
        self._btn(row2, "Browse…", self.pick_json).pack(side="left", padx=(6, 20))

        self._lbl(row2, "Output dir:").pack(side="left")
        self._entry(row2, self.var_out_dir, 28).pack(side="left", padx=6)
        self._btn(row2, "Choose…", self.pick_out_dir).pack(side="left", padx=(6, 18))

        tk.Checkbutton(
            row2, text="Auto title", variable=self.var_auto_title,
            bg="white", fg=JF_TEXT, activebackground="white", selectcolor=JF_BG,
            command=self._maybe_auto_title
        ).pack(side="left")

        # Row 3
        row3 = tk.Frame(frm, bg="white"); row3.pack(fill="x", pady=(2, 6))
        self._lbl(row3, "Output base name:").pack(side="left")
        self._entry(row3, self.var_title, 40).pack(side="left", padx=(6, 20))

        # Row 4 — Open-Title (POSTER ONLY)
        row4 = tk.Frame(frm, bg="white"); row4.pack(fill="x", pady=(2, 6))
        self._lbl(row4, "Open-title (for Poster only):").pack(side="left")
        self._entry(row4, self.var_open_title, 46).pack(side="left", padx=(6, 20))

        # Row 5 — Sentence-locked controls
        row5 = tk.Frame(frm, bg="white"); row5.pack(fill="x", pady=(2, 6))
        tk.Checkbutton(
            row5, text="Sentence-locked (use input lines as cues — disables autosync)",
            variable=self.var_sentence_locked, bg="white", fg=JF_TEXT,
            activebackground="white", selectcolor=JF_BG
        ).pack(side="left")
        self._lbl(row5, "Gap(ms):").pack(side="left", padx=(18,0))
        self._entry(row5, self.var_gap_ms, 6).pack(side="left", padx=(6,12))
        self._lbl(row5, "Min(ms):").pack(side="left", padx=(0,0))
        self._entry(row5, self.var_min_ms, 6).pack(side="left", padx=(6,0))

        # Middle — Text area
        mid = tk.LabelFrame(card, text="Prayer text (one line per caption; used if no JSON is selected)", bg="white", fg=JF_TEXT, labelanchor="nw")
        mid.configure(highlightbackground="#efeaf7", highlightthickness=1)
        mid.pack(fill="both", expand=True, padx=pad, pady=(0, pad))

        actions = tk.Frame(mid, bg="white"); actions.pack(fill="x", padx=6, pady=(6,0))
        self._btn(actions, "Paste", self.paste_from_clipboard).pack(side="left")
        self._btn(actions, "Copy Input", self.copy_input_to_clipboard).pack(side="left", padx=(6,0))
        self._btn(actions, "Clear", self.clear_input).pack(side="left", padx=(6,0))

        self.txt = tk.Text(mid, height=12, wrap="word", bg="#ffffff", fg=JF_TEXT, insertbackground=JF_PURPLE)
        self.txt.pack(fill="both", expand=True, padx=6, pady=6)
        self.txt.insert("1.0",
            "Father, I cast my cares on You, knowing You care for me.\n"
            "Steady my thoughts and quiet my heart in Your presence.\n"
            "Teach me to trust Your timing and Your faithful love.\n"
            "Anchor me in Your peace as I wait on You."
        )

        # Bottom controls
        bot = tk.Frame(card, bg="white"); bot.pack(fill="x", padx=pad, pady=(0, pad))
        self.btn_start = self._btn(bot, "Start", self.on_start, primary=True); self.btn_start.pack(side="left")
        self._btn(bot, "Open Output Folder", self.open_out_dir).pack(side="left", padx=6)
        self._btn(bot, "Stop", self.on_stop, danger=True).pack(side="left", padx=6)
        # Poster generator
        self._btn(bot, "Make Poster (from Open-Title)", self.on_make_poster).pack(side="left", padx=12)

        # Logs
        log_frame = tk.LabelFrame(card, text="Build logs (streamed)", bg="white", fg=JF_TEXT, labelanchor="nw")
        log_frame.configure(highlightbackground="#efeaf7", highlightthickness=1)
        log_frame.pack(fill="both", expand=True, padx=pad, pady=(0, pad))

        tools_line = tk.Frame(log_frame, bg="white"); tools_line.pack(fill="x", padx=6, pady=(8,0))
        self._btn(tools_line, "Copy Logs", self.copy_logs).pack(side="left")
        self._btn(tools_line, "Clear Logs", self.clear_logs).pack(side="left", padx=(6,0))

        self.log = tk.Text(log_frame, height=14, wrap="none", state="disabled", bg="#0f0f12", fg="#e6e6e6", insertbackground="#e6e6e6")
        self.log.pack(fill="both", expand=True, padx=6, pady=6)
        self.after(100, self._drain_log_queue)

    # --- brand ---
    def _brand_bar(self, parent):
        bar = tk.Frame(parent, bg=JF_PURPLE, height=56); bar.pack(fill="x", side="top")
        tk.Label(bar, text="JirehFaith — Scripture-Woven Prayer (SWP) Kit",
                 bg=JF_PURPLE, fg=JF_GOLD, font=("Segoe UI", 14, "bold")
        ).pack(side="left", padx=14, pady=10)

    # --- tiny UI helpers ---
    def _lbl(self, parent, text): return tk.Label(parent, text=text, bg="white", fg=JF_TEXT, font=("Segoe UI", 10))
    def _entry(self, parent, var, width): return tk.Entry(parent, textvariable=var, width=width, bg="#ffffff", fg=JF_TEXT, insertbackground=JF_PURPLE, relief="solid", bd=1, highlightthickness=0)
    def _combo(self, parent, var, values, width): return ttk.Combobox(parent, textvariable=var, values=values, state="readonly", width=width)
    def _btn(self, parent, text, cmd, primary=False, danger=False):
        bg, fg, abg = "#ffffff", JF_TEXT, "#f2f2f7"
        if primary: bg, fg, abg = JF_PURPLE, JF_GOLD, "#5a3090"
        elif danger: bg, fg, abg = "#7a1022", "#ffffff", "#5c0c1a"
        return tk.Button(parent, text=text, command=cmd, bg=bg, fg=fg, activebackground=abg, activeforeground=fg, relief="raised", bd=1)

    def _font_bump(self, delta: int):
        try:
            v = int(self.var_font_size.get())
        except Exception:
            v = 120
        v = max(40, min(240, v + delta))
        self.var_font_size.set(v)

    def _lead_bump(self, delta: int):
        try:
            v = int(self.var_caption_shift.get())
        except Exception:
            v = -500
        v = max(-5000, min(5000, v + delta))
        self.var_caption_shift.set(v)

    # --- clipboard ---
    def clear_input(self):
        self.txt.delete("1.0", "end")

    def paste_from_clipboard(self):
        try:
            data = self.clipboard_get()
        except Exception:
            data = ""
        if data:
            self.txt.delete("1.0", "end"); self.txt.insert("1.0", data)
        else:
            messagebox.showinfo("Clipboard empty", "Nothing to paste from the clipboard.")

    def copy_input_to_clipboard(self):
        text = self.txt.get("1.0", "end").strip()
        if not text:
            messagebox.showinfo("No text", "The prayer input box is empty."); return
        self.clipboard_clear(); self.clipboard_append(text)
        self._log("[info] Copied prayer input to clipboard.\n")

    def copy_logs(self):
        self.log.configure(state="normal")
        text = self.log.get("1.0", "end-1c")
        self.log.configure(state="disabled")
        if not text.strip():
            messagebox.showinfo("No logs", "There are no logs to copy yet."); return
        self.clipboard_clear(); self.clipboard_append(text)
        self._log("[info] Copied logs to clipboard.\n")

    def clear_logs(self):
        self.log.configure(state="normal"); self.log.delete("1.0", "end"); self.log.configure(state="disabled")

    # --- pickers ---
    def pick_json(self):
        p = filedialog.askopenfilename(title="Choose JSON file", filetypes=[("JSON", "*.json"), ("All files", "*.*")])
        if p: self.var_json_path.set(p)

    def pick_out_dir(self):
        d = filedialog.askdirectory(title="Choose output directory", initialdir=self.var_out_dir.get() or str(OUT_DEFAULT))
        if d: self.var_out_dir.set(d)

    def open_out_dir(self):
        path = Path(self.var_out_dir.get() or OUT_DEFAULT)
        try:
            if os.name == "nt":
                os.startfile(str(path))  # type: ignore[attr-defined]
            elif sys.platform == "darwin":
                subprocess.run(["open", str(path)], check=False)
            else:
                subprocess.run(["xdg-open", str(path)], check=False)
        except Exception as e:
            messagebox.showerror("Error", f"Could not open folder:\n{e}")

    # --- auto title ---
    def _maybe_auto_title(self, force: bool=False):
        if not self.var_auto_title.get() and not force: return
        voice = (self.var_voice.get() or "").lower()
        emotion = (self.var_emotion.get() or "").lower()
        lang = (self.var_lang.get() or "").lower()
        if not (voice and emotion and lang): return
        self.var_title.set(f"{emotion}_{lang}_{voice}")

    # --- pipeline ---
    def on_start(self):
        if self.proc and self.proc.poll() is None:
            messagebox.showwarning("Busy", "A build is already running. Stop it first or wait for it to finish.")
            return

        # Preflight (local binaries/scripts)
        missing = []
        for p in [PIPER_EXE, JSON_TO_SRT, RENDER_UNIFIED]:
            if not p.exists():
                missing.append(str(p))
        if self.var_sentence_locked.get() and not MAKE_SENTENCE_EVEN.exists():
            missing.append(str(MAKE_SENTENCE_EVEN))
        if missing:
            messagebox.showerror("Missing files", "These required files were not found:\n- " + "\n- ".join(missing))
            return

        size_sel = (self.var_size.get() or "1080x1920").strip()
        if size_sel not in ("1080x1920", "1920x1080"):
            messagebox.showerror("Size error", f"Unsupported size selection: {size_sel}")
            return

        # JSON (or build temporary JSON from textarea)
        json_src = self.var_json_path.get().strip()
        if json_src:
            json_path = Path(json_src)
            if not json_path.exists():
                messagebox.showerror("Missing JSON", f"Selected JSON file does not exist:\n{json_path}")
                return
        else:
            try:
                json_path = write_tmp_json_from_text(
                    self.var_emotion.get(), self.var_lang.get(), self.var_voice.get(),
                    self.txt.get("1.0", "end").strip(),
                    self.var_title.get().strip() or "prayer_ui"
                )
                self._log(f"[info] Wrote JSON: {json_path}\n")
            except Exception as e:
                messagebox.showerror("JSON error", f"Could not build temporary JSON:\n{e}")
                return

        # OUT base/paths
        out_dir = Path(self.var_out_dir.get().strip() or OUT_DEFAULT); out_dir.mkdir(parents=True, exist_ok=True)
        base = self.var_title.get().strip() or f"{self.var_emotion.get().lower()}_{self.var_lang.get().lower()}_{self.var_voice.get().lower()}"
        self.var_title.set(base)

        wav_path = VOICE_WAVS_DIR / f"{base}.wav"
        srt_path = VOICE_BUILD_DIR / f"{base}.srt"  # default path; may be overwritten by sentence-locked builder

        # Output file name depends on size
        out_mp4 = out_dir / (f"{base}_VERTICAL_BOXED.mp4" if size_sel == "1080x1920" else f"{base}_HORIZONTAL_1080p.mp4")

        # Background selection (format-aware, with fallback)
        emotion_key = (self.var_emotion.get() or "").strip()
        emotion_up = emotion_key.upper().replace(" ", "_")
        emotion_lc = emotion_key.lower().replace(" ", "_")

        bg_dir = ASSETS_BG_DIR if size_sel == "1080x1920" else ASSETS_BG_H_DIR
        candidates = [
            bg_dir / f"{emotion_up}.png",
            bg_dir / f"{emotion_lc}.png",
        ]
        if size_sel != "1080x1920":  # horizontal: fallback to vertical if missing
            candidates += [
                ASSETS_BG_DIR / f"{emotion_up}.png",
                ASSETS_BG_DIR / f"{emotion_lc}.png",
            ]
        bg_png = next((p for p in candidates if p.exists()), candidates[0])
        if not bg_png.exists():
            self._log(f"[warn] Background image not found: tried {', '.join(str(p) for p in candidates)}\n"
                      "Continuing anyway (ffmpeg will fail if truly missing)…\n")
        else:
            self._log(f"[bg] Using background: {bg_png}\n")

        # Voice profile
        voice_label = self.var_voice.get().strip().upper()
        profile_path = PROFILE_MAP.get(voice_label)
        if not profile_path or not profile_path.exists():
            messagebox.showerror("Profile missing", f"Profile file not found for voice {voice_label}:\n{profile_path}")
            return
        try:
            prof = load_profile_env(profile_path)
        except Exception as e:
            messagebox.showerror("Profile error", str(e)); return

        # 1) WAV via Piper (from JSON)
        try:
            text_for_tts = build_text_from_json(json_path)
        except Exception as e:
            messagebox.showerror("JSON parse error", f"Could not read lines from JSON:\n{e}")
            return

        self._log(f"[tts] {voice_label} → {wav_path}\n")
        try:
            create_flags = 0
            if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW"):
                create_flags = subprocess.CREATE_NO_WINDOW
            p = subprocess.run(
                [
                    str(PIPER_EXE),
                    "--model", prof["MODEL_PATH"],
                    "--config", prof["CONFIG_PATH"],
                    "--length_scale", prof["LENGTH_SCALE"],
                    "--noise_scale", prof["NOISE_SCALE"],
                    "--noise_w", prof["NOISE_W"],
                    "--output_file", str(wav_path),
                ],
                input=text_for_tts,
                text=True,
                cwd=str(APP_ROOT),
                capture_output=True,
                creationflags=create_flags,
            )
            self._log(p.stdout or "")
            if p.returncode != 0:
                self._log(p.stderr or "")
                messagebox.showerror("Piper error", f"Piper failed (rc={p.returncode}). See logs.")
                return
        except Exception as e:
            messagebox.showerror("Piper launch error", str(e)); return

        # 2) Build SRT
        sentence_locked = self.var_sentence_locked.get()
        bash_path = _detect_git_bash_path()

        if sentence_locked:
            # Save textarea lines to voice/script/<base>.txt and call make_sentence_even_srt.sh
            lines_text = self.txt.get("1.0", "end").strip()
            if not lines_text:
                messagebox.showerror("No lines", "Sentence-locked mode requires lines in the Prayer text box.")
                return
            script_txt = VOICE_SCRIPT_DIR / f"{base}.txt"
            script_txt.write_text(lines_text + "\n", encoding="utf-8")
            self._log(f"[script] Wrote lines: {script_txt}\n")

            try:
                gap = int(self.var_gap_ms.get())
            except Exception:
                gap = 180
            try:
                min_ms = int(self.var_min_ms.get())
            except Exception:
                min_ms = 1000

            # Output SRT path (fixed)
            srt_path = VOICE_BUILD_DIR / f"{base}.sentences.srt"

            env2 = os.environ.copy()
            env2["GAP_MS"] = str(gap)
            env2["MIN_MS"] = str(min_ms)

            b_wav  = norm_path_for_bash(wav_path)
            b_txt  = norm_path_for_bash(script_txt)
            b_srt  = norm_path_for_bash(srt_path)

            cmd_s = f'"{norm_path_for_bash(MAKE_SENTENCE_EVEN)}" "{b_wav}" "{b_txt}" "{b_srt}"'
            self._log(f"[srt-sentences] GAP_MS={gap} MIN_MS={min_ms} → {srt_path}\n")
            try:
                p2 = subprocess.run([bash_path, "-lc", cmd_s], cwd=str(APP_ROOT), env=env2, capture_output=True, text=True)
                self._log(p2.stdout or "")
                if p2.returncode != 0:
                    self._log(p2.stderr or "")
                    messagebox.showerror("Sentence SRT error", f"make_sentence_even_srt.sh failed (rc={p2.returncode}). See logs.")
                    return
            except Exception as e:
                messagebox.showerror("Sentence SRT launch error", str(e)); return
        else:
            # json_to_srt (UI-safe)
            srt_path = VOICE_BUILD_DIR / f"{base}.srt"
            self._log(f"[srt] {JSON_TO_SRT} → {srt_path}\n")
            try:
                py = sys.executable.replace("pythonw.exe", "python.exe")
                p2 = subprocess.run(
                    [py, str(JSON_TO_SRT), "--input", str(json_path), "--out", str(srt_path)],
                    cwd=str(APP_ROOT),
                    capture_output=True,
                    text=True
                )
                self._log(p2.stdout or "")
                if p2.returncode != 0:
                    self._log(p2.stderr or "")
                    messagebox.showerror("SRT error", f"json_to_srt failed (rc={p2.returncode}). See logs.")
                    return
            except Exception as e:
                messagebox.showerror("SRT step error", str(e)); return

            # Normalize SRT newlines so libass sees cues
            try:
                raw = Path(srt_path).read_text(encoding="utf-8")
                fixed = raw.replace("\r\n", "\n").replace("\\n", "\n")
                Path(srt_path).write_text(fixed, encoding="utf-8", newline="\n")
                self._log(f"[normalize] fixed newlines {srt_path}\n")
            except Exception as e:
                self._log(f"[warn] normalize failed: {e}\n")

        # 3) Render MP4 with unified renderer
        # Paths → bash form
        b_bg   = norm_path_for_bash(bg_png)
        b_wav  = norm_path_for_bash(wav_path)
        b_srt  = norm_path_for_bash(srt_path)
        b_out  = norm_path_for_bash(out_mp4)

        # Font size
        try:
            fs = int(self.var_font_size.get() or 120)
        except Exception:
            fs = 120

        # Caption lead (maps to CAPTION_SHIFT_MS; still honored in sentence-locked)
        try:
            lead = int(self.var_caption_shift.get())
        except Exception:
            lead = -500

        env = os.environ.copy()
        env["FONT_SIZE"] = str(fs)
        env["CAPTION_SHIFT_MS"] = str(lead)
        env["TOP_BANNER"] = ""  # ensure no in-video title

        if sentence_locked:
            # Hard-off all autosync/tempo/onset adjustments
            env["AUTOSYNC"] = "0"
            env["TEMPO_MATCH"] = "0"
            env["AUTO_ONSET_ALIGN"] = "0"
            env["APPLY_SHIFT_TO_AUDIO"] = "0"
        else:
            # Standard smart pipeline defaults
            env["AUTOSYNC"] = "1"
            env["TEMPO_MATCH"] = "1"
            env["AUTO_ONSET_ALIGN"] = "1"
            env["APPLY_SHIFT_TO_AUDIO"] = "1"

        size_arg = f"--size={size_sel}"
        cmd = f'"{norm_path_for_bash(RENDER_UNIFIED)}" {size_arg} "{b_bg}" "{b_wav}" "{b_srt}" "{b_out}"'
        self._log(f"[render] {cmd}\n")

        try:
            self._stop_reader.clear()
            self.proc = subprocess.Popen(
                [_detect_git_bash_path(), "-lc", cmd],
                cwd=str(APP_ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                bufsize=1,
                env=env
            )
        except Exception as e:
            messagebox.showerror("Render launch error", str(e))
            return

        self.log_thread = threading.Thread(target=self._reader_thread_with_done, args=(out_mp4,), daemon=True)
        self.log_thread.start()

    # --- Poster generator (Open-Title + Font size + Output Size + Emotion BG) ---
    def on_make_poster(self):
        title = (self.var_open_title.get() or "").strip()
        if not title:
            messagebox.showwarning("Open-Title required", "Enter a title in the “Open-title (for Poster only)” field first.")
            return

        size_sel = (self.var_size.get() or "1080x1920").strip()
        out_dir = Path(self.var_out_dir.get().strip() or OUT_DEFAULT); out_dir.mkdir(parents=True, exist_ok=True)
        base = self.var_title.get().strip() or "poster"

        if size_sel == "1080x1920":
            w, h = 1080, 1920
            poster_path = out_dir / f"{base}_VERTICAL_POSTER.png"
            bg_dir = ASSETS_BG_DIR
        else:
            w, h = 1920, 1080
            poster_path = out_dir / f"{base}_HORIZONTAL_POSTER.png"
            bg_dir = ASSETS_BG_H_DIR

        # Resolve emotion background (with fallback across cases and, for H, fallback to V set)
        emotion_key = (self.var_emotion.get() or "").strip()
        emotion_up = emotion_key.upper().replace(" ", "_")
        emotion_lc = emotion_key.lower().replace(" ", "_")

        candidates = [
            bg_dir / f"{emotion_up}.png",
            bg_dir / f"{emotion_lc}.png",
        ]
        if size_sel != "1080x1920":
            candidates += [
                ASSETS_BG_DIR / f"{emotion_up}.png",
                ASSETS_BG_DIR / f"{emotion_lc}.png",
            ]
        bg_png = next((p for p in candidates if p.exists()), None)
        if bg_png and bg_png.exists():
            self._log(f"[poster-bg] Using background: {bg_png}\n")
        else:
            self._log("[poster-bg] No matching background found; falling back to solid color.\n")
            bg_png = None

        # Use UI font size; clamp
        try:
            fs = int(self.var_font_size.get() or 120)
        except Exception:
            fs = 120
        fs = max(40, min(260, fs))

        bash_exe = _detect_git_bash_path()
        if not MAKE_POSTER.exists():
            messagebox.showerror("Missing script", f"make_title_poster.sh not found:\n{MAKE_POSTER}")
            return

        env = os.environ.copy()
        env["TOP_BANNER"] = title          # poster SHOULD show the title
        env["FONT_SIZE"] = str(fs)
        env["MARGIN_L"] = "160"
        env["MARGIN_R"] = "160"
        env["MARGIN_V"] = "0"
        if bg_png:
            env["BG_PNG"] = str(bg_png)    # script composites over this background

        size_arg = f"--size={w}x{h}"
        cmd = [bash_exe, str(MAKE_POSTER), size_arg, str(poster_path)]

        self._log(f"[poster] {' '.join(cmd)}\n")
        try:
            create_flags = 0
            if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW"):
                create_flags = subprocess.CREATE_NO_WINDOW
            p = subprocess.run(cmd, cwd=str(APP_ROOT), env=env, capture_output=True, text=True, creationflags=create_flags)
            self._log(p.stdout or "")
            if p.returncode != 0:
                self._log(p.stderr or "")
                messagebox.showerror("Poster error", f"Poster script failed (rc={p.returncode}). See logs.")
                return
        except Exception as e:
            messagebox.showerror("Poster error", str(e)); return

        self._log(f"[OK] Poster written: {poster_path}\n")
        try:
            if os.name == "nt":
                os.startfile(str(poster_path))  # type: ignore[attr-defined]
        except Exception:
            pass

    def on_stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate(); self._log("[info] Sent terminate signal.\n")
            except Exception as e:
                self._log(f"[err] Could not terminate: {e}\n")
        else:
            self._log("[info] No running process to stop.\n")

    def _reader_thread_with_done(self, out_mp4: Path):
        if not self.proc or not self.proc.stdout: return
        for line in self.proc.stdout:
            self.log_queue.put(line)
            if self._stop_reader.is_set(): break
        rc = self.proc.wait()
        self.log_queue.put(f"\n[done] Render exited with code {rc}\n")
        if rc == 0:
            self.log_queue.put(f"[OK] Rendered: {out_mp4}\n")

    def _drain_log_queue(self):
        try:
            while True:
                line = self.log_queue.get_nowait(); self._log(line)
        except queue.Empty:
            pass
        self.after(80, self._drain_log_queue)

    def _log(self, text: str):
        self.log.configure(state="normal"); self.log.insert("end", text); self.log.see("end"); self.log.configure(state="disabled")

def main():
    # Minimal preflight for local binaries/scripts
    missing = []
    for p in [PIPER_EXE, JSON_TO_SRT, RENDER_UNIFIED]:
        if not p.exists():
            missing.append(str(p))
    if missing:
        messagebox.showerror("Preflight error", "Missing required files:\n- " + "\n- ".join(missing))
        sys.exit(2)
    app = Launcher()
    app.mainloop()

if __name__ == "__main__":
    main()
