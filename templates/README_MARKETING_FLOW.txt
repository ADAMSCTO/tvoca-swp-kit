Weekly flow (shorts, 9:16 <=60s):
1) Pick emotions + languages  → templates/emotions_week1.txt, languages_week1.txt
2) Export JSON from app       → examples/*.json (one per emotion)
3) Generate SRT (auto-timed)  → scripts step (next mission)
4) TTS per emotion (consistent voice) → voice/lines → voice/build → voice/wavs (final)
5) Render video (bg + captions + verse tag) → out/
6) Generate thumbnail + metadata.csv       → thumbnails/, templates/metadata_template.csv
