---
created: 2026-11-27
updated: 2026-11-27
---

# Fun Female Character & Girl-Voice Demos Spec (`Option 2`)

**Scope:** Bounded (reuses existing `01_host_character.json`, `01B_qwen21_pose_edit.json`, `02_host_voice.json`, and `04_director_multiref_r2v.json` workflows on RTX 4090 / `31.95 GiB` RAM; zero core ComfyUI code edits).

---

## 1. Grounded Source Assets (`E:\ComfyUI\output\refs\`)

- **`a.png` (`1698x926`) — Girl A ("Sunny"):** High brown ponytail, iridescent aviator sunglasses on head, white ribbed crop tank, cuffed denim shorts, striped crew socks, cream sneakers (`5`-view turnaround + detail callouts). *Note: `input/char_a_front.png` retains bottom-left color swatches; re-crop clean.*
- **`b.png` (`1690x931`) — Girl B ("Blitz"):** Dark twin braids, white zip crop tee with black harness straps & sleeve stripes, bright red-orange shorts, chunky white sneakers (`5`-view turnaround + detail callouts).
- **`DevXai/` — Fox-Girl VTuber ("DevXai"):**
  - `FINAL Fox VTuber Character Reference Sheet.png` (`1536x1024`): navy hair with hot-pink left streak, fox ears (navy/white/cyan), heterochromia (red right eye / blue left eye), orange hair clip, yellow honeycomb romper, asymmetric puff sleeves (cyan right / pink left), giant navy-to-magenta fox tail, `15` face expressions, `11` dynamic poses, chibi.
  - `Ai earrings.png` (`354x247`): close-up of butterfly glow earring (right) + crescent moon/star crystal earring (left).
  - `happy3 - eyes open mouth closed.png` (`2000x2000`): chibi/sketch bust.

---

## 2. Approaches Considered & Decision

| Approach | Summary | Tradeoff | Decision |
|---|---|---|---|
| **1. VTuber Studio Raid** | `A` + `B` film chill vlog; `DevXai` photobombs out of monitor | Mixing 2D anime and 3D semi-real in one H3 video frame risks style bleed | Rejected |
| **2. Two Style-Pure Mini-Demos** | **Demo 1:** `A` + `B` arcade comedy (`2` shots). **Demo 2:** `DevXai` VTuber intro (`2` shots). | Preserves each character sheet's native art style cleanly | **Selected** |
| **3. Unified Squad Crossover** | Restyle `DevXai` to 3D (or `A+B` to 2D) via `01B` | Extra restyle pass; loses original character-sheet faithfulness | Rejected |

---

## 3. Locked Design Decisions

1. **Single-Speaker-Per-Shot (`Demo 1`):** `MiniMaxH3AddGuide` accepts one `audio` track (`frame_idx=0`). Lock **Shot 1 = Sunny speaks / Blitz smirks silently**, **Shot 2 = Blitz MCU speaks / Sunny laughs silently** to prevent dual-mouth lip-sync bleed.
2. **Asymmetric Anime Lock (`Demo 2`):** Stage `DevXai` keyframes with **`01_host_character.json`** (`MiniMax-H3-Image` multi-ref `<Picture 1..3>` + `h3_image_character_swap_v1.safetensors`) first to preserve left/right eye, sleeve, and `Ai earrings.png` asymmetry; fall back to `01B_qwen21_pose_edit.json` (`Qwen-2.1 INT8` + `Fun-ControlNet-Union INT8`) only if pose drifts.
3. **Girl Voices (`02_host_voice.json`, `VoxCPM2` `48 kHz`):** Generate `3` zero-shot `voice_design` master clips (Sunny, Blitz, DevXai — no external female audio needed), then lock every dialogue beat (`<=100` words, `~4.5–4.8 s`) via `VoxCPM_VoiceCloning` (`prompt_audio` + exact `prompt_text`, continuation mode, `inflect`+`wetext` normalization active).
4. **Render Tier & Isolation:** Store clean borderless crops + beat `.flac` files in `input/girls_demo/`; render `1344x768 @ 24 fps` via **6-step `HyperFlow ref2va` (`minimax_h3_ref2va_hyperflow_flash_14b-int8_convrot.safetensors`) + `minimax_h3_video_vae_fp16.safetensors`** into `E:\ComfyUI\output\girls_demo\`. Call `POST http://127.0.0.1:8188/free` (`{"unload_models": true, "free_memory": true}`) between `02`, `01`/`01B`, and `04`.

```text
[1. Clean Crops -> input/girls_demo/]
    |--> [2. 02_host_voice.json: 3 girl masters -> 4 beat FLACs]
    |--> [3. 01 / 01B: 4 keyframes (1344x768)]
            |
            v
    [4. 04_director_multiref_r2v.json (6-step HyperFlow + fp16 VAE)]
            |
            v
    [5. ffmpeg concat + ffprobe + frame check -> E:\ComfyUI\output\girls_demo\]
```

---

## 4. Step-by-Step Implementation Plan

1. **Crop clean references (`input/girls_demo/`):** Extract borderless, swatch-free PNGs (`>=768 px` height): `a_front.png`, `a_3q.png`, `b_front.png`, `b_3q.png`, `devxai_front.png`, `devxai_earrings.png`, `devxai_teasing.png`, `devxai_peace.png`.
2. **Synthesize 3 girl voice masters + 4 dialogue beats (`02_host_voice.json`):**
   - **Sunny (`a.png`, upbeat California bestie):** *"Wait, did you seriously just bribe the claw machine with your lucky hair tie?!"*
   - **Blitz (`b.png`, dry sporty sarcasm):** *"Hey, it worked, didn't it? Look—five bucks says the plushie drops on three. Ready?"*
   - **DevXai Shot 1 (hyper-cute anime VTuber):** *"Hii chat! Welcome back! Don't look at my tail—okay, fine, look at the shiny moon earrings first!"*
   - **DevXai Shot 2 (teasing gremlin):** *"Wait, did you think I'd lose a boss fight in heels? Cute. Watch this!"*
   - Measure durations via `ffprobe`, compute `length = ceil(dur * 24) + 8`, copy beat `.flac` files to `input/girls_demo/`, then call `POST /free`.
3. **Stage 4 keyframes (`01_host_character.json`, fallback `01B`):**
   - `demo1_shot1_kf.png`: Neon arcade beside pastel claw machine; Sunny (`a.png`) wide-eyed pointing at glass; Blitz (`b.png`) smirking holding hair tie.
   - `demo1_shot2_kf.png`: Arcade MCU reverse angle; Blitz grinning at joystick; Sunny leaning in laughing.
   - `demo2_shot1_kf.png`: Cozy RGB gaming room desk mic; DevXai winking + peace sign (`Peace Sign` ref), red/blue eyes, crescent/butterfly earrings (`Ai earrings.png`), fluffy tail.
   - `demo2_shot2_kf.png`: Close-up teasing smirk (`Teasing` ref), finger tapping cheek, sparkling asymmetric earrings.
   - Save keyframes to `input/girls_demo/`, then call `POST /free`.
4. **Animate 4 shots (`04_director_multiref_r2v.json`):** Wire each shot's `first_frame`, clean `ref_images`, and matching beat `.flac` via `MiniMaxH3AddGuide` (`frame_idx=0`), `6`-step `HyperFlow ref2va`, and `minimax_h3_video_vae_fp16.safetensors` (`~160 s/shot`).
5. **Concatenate & verify (`E:\ComfyUI\output\girls_demo\`):** Join shots with `ffmpeg` into `demo1_arcade_besties.mp4` and `demo2_devxai_vtuber.mp4`; verify `1344x768 @ 24 fps` + `48000 Hz` AAC via `ffprobe` and inspect `3` extracted frames per shot.
