* \# TVOCA — Text → Voice → Captions → Video
* 
* \*\*TVOCA\*\* is a creator engine that turns written text into fully rendered, captioned videos — ready for TikTok, Reels, YouTube Shorts, and more.
* 
* > \*\*Your words. Made video.\*\*
* 
* ---
* 
* \## 🚀 What TVOCA Does
* 
* TVOCA takes a simple script and transforms it into a complete video:
* 
* 1\. \*\*Text\*\* — You write or paste your script.
* 2\. \*\*Voice\*\* — TTS voices (Piper and others) generate natural audio.
* 3\. \*\*Captions\*\* — Sentences are split and converted into aligned SRT.
* 4\. \*\*CenterBox Rendering\*\* — Captions are burned into video using ASS with a locked, consistent CenterBox style.
* 5\. \*\*Video Output\*\* — Vertical or horizontal MP4, ready to upload to social platforms.
* 
* Under the hood, TVOCA reuses and extends the core rendering pipeline originally built for the JirehFaith Scripture-Woven Prayer Kit.
* 
* ---
* 
* \## 🧠 Core Pipeline
* 
* The unified renderer handles:
* 
* \- SRT ↔ WAV autosync (optional)
* \- Tempo matching (voice to caption timing) (optional)
* \- ASS generation and normalization (PlayRes, styles)
* \- Strict CenterBox enforcement so every caption appears in the same box
* \- Final ffmpeg render with background, audio, and captions burned in
* 
* Key script:
* 
* \- `tools/render\_swp\_unified.sh`
* 
* Key helper:
* 
* \- `tools/ass\_force\_centerbox.sh`  
* &nbsp; Ensures all captions share the same CenterBox geometry and strips misaligned overrides.
* 
* ---
* 
* \## 📂 Project Layout (High Level)
* 
* \- `tools/` — Render scripts, autosync, ASS normalization, UI launcher.
* \- `voice/` — TTS profiles, WAVs, SRT builds.
* \- `assets/bg/` — Vertical backgrounds (1080x1920).
* \- `assets/bg\_h/` — Horizontal backgrounds (1920x1080).
* \- `out/` — Rendered MP4 outputs.
* 
* ---
* 
* \## ⚙️ Local Usage (Developer Mode)
* 
* > \*\*Note:\*\* This repo currently assumes a local environment similar to the original SWP Kit:
* > - Git Bash on Windows
* > - `ffmpeg` available in PATH
* > - Piper TTS models present in `piper/models/`
* 
* Typical render flow (example):
* 
* ```bash
* \# From project root
* cd tools
* 
* \# Example vertical render (1080x1920)
* FONT\_NAME="Arial" FONT\_SIZE=96 BOX\_OPA=96 \\
* ../tools/render\_swp\_unified.sh \\
* &nbsp; --size=1080x1920 \\
* &nbsp; "../assets/bg/FINANCIAL\_TRIALS.png" \\
* &nbsp; "../voice/wavs/financial\_trials\_en\_joe.wav" \\
* &nbsp; "../voice/build/financial\_trials\_en\_joe.sentences.srt" \\
* &nbsp; "../out/financial\_trials\_en\_joe\_VERTICAL\_BOXED.mp4"
* 
