---
created: 2026-11-27
updated: 2026-11-27
---

# Design Spec: Modular ComfyUI Multi-Channel Character A-Roll Pipeline

**Scope:** Bounded
**Target Hardware:** NVIDIA RTX 4090 (24 GB VRAM), AMD Ryzen 7 3700X, 31.9 GB RAM, Windows (`D:` NVMe ~205 GB free + `E:` HDD ~1.8 TB free), ComfyUI `0.46.0` (`127.0.0.1:8188`).

---

## 1. Intent, Goals & Non-Goals

- **Intent:** Build a 100% ComfyUI-native, UI-editable, MCP-automatable pipeline to create channel characters, derive distinct character voices from a single family voice recording, and render dynamic human-like half-body A-roll videos on 24 GB VRAM / 31.9 GB RAM.
- **Goals:**
  - All 3 stages run inside ComfyUI (`127.0.0.1:8188`) and persist as clean Web-UI canvas workflows under `user/default/workflows/` (`save_workflow` converts API graphs into `{nodes, links}`).
  - Workflows remain inspectable and editable by hand on the ComfyUI canvas, while MCP (`get_workflow` → `create_workflow(modify)` → `enqueue_workflow` / `batch`) automates episode runs using the exact saved graphs.
  - Derive one locked `10 s` master `.wav` per character from a single real family voice recording (`VoxCPM2` `reference_audio` + `voice_design`), keeping voices distinct across channels and consistent across episodes.
  - Support custom edited voice references (`VoxCPM2` Hi-Fi `prompt_audio` + `prompt_text` alongside `reference_audio` + `voice_design`), preserving verbatim `48 kHz` audio in exported MP4s and joining multi-shot beats via `ffmpeg`.
  - Support 3D camera + 3D dummy positioning/movement (`ComfyUI-Jakkanna` `VNCCS Pose Studio` + `T8 AnyAngle Studio`) feeding multi-ref pose image generation (`H3 Character Swap` + `Qwen-Image-2.1 INT8` + `Fun-ControlNet-Union INT8`) and multi-ref video (`04_director_multiref_r2v.json`).
- **Non-Goals (Deferred):**
  - `igorls/comfyui-h3-editor` sidebar timeline app (hides node wires inside Python `project.py` / `editor_api.py`).
  - `Seed-VC` (`ComfyUI-Timbre-Transfer`) pitch/formant conversion (defer unless A/B listening shows `VoxCPM2` separation is insufficient).
  - `SCAIL-2` (`~20 GB` Wan 2.1 motion transfer — silent, vertical-aspect sensitive, copies dummy face unless masked; defer unless full-body non-talking choreography is needed beyond `H3 Ref2VA`).
  - `IndexTTS-2.5` (`transformers<5` breaks `.venv`'s `transformers==5.22.1`) and `Sulphur-3` FP32 `8 GB` corrector (thrashes `31.95 GiB` RAM).
  - `P-H3-Image` (`~25 GB` free RAM minimum, higher identity drift) and single mega-graph combining image + TTS + video in one JSON.
- **Anti-Goals:**
  - Stiff `512×512` face-crop talking boxes (`SoulX-FlashHead`).
  - Prompt-only single-pass 4-view character sheets (proven to dwarf/crop shins).
  - Leaving duplicate weights on `E:` shadowing `D:` NVMe (`folder_paths.py:460-463`).
  - Running heavy stacked models (`16 MP` H3-Image or Qwen BF16 + Fun-ControlNet) without `/free` on `31.95 GiB` RAM (`~11.8 GiB` free when cached).

---

## 2. Settled Design Decisions & Hardware Context

| Decision | Choice | Verified Basis |
|---|---|---|
| **Workflow Architecture** | 3 modular canvas `.json` workflows (`user/default/workflows/`) | Inspectable/editable in UI, native MCP automation, clean `/free` between heavy stages on 31.9 GB RAM |
| **Character Creation** | `MiniMax-H3-Image` INT8 @ **4 MP** (`~14 s` warm), prompt expander OFF | Reuses `D:` `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` (`15.7 GB`); native `MiniMaxH3ImageConditioning` (`comfy_extras/nodes_minimax_h3.py:740`); avoids `32–58 GB` RAM spike of 16 MP (`lcz.me/topic/2976`) |
| **TTS & Multi-Host Voice** | `ComfyUI-VoxCPM` (`VoxCPM2`, 2B, `48 kHz`, Apache-2.0) | `VoxCPMVoiceCloning.reference_audio` + `VoxCPMNode.voice_design` creates locked `10 s` master `.wav` per character; avoids `qwen-tts 0.1.1` / `transformers 5.x` conflict |
| **Dynamic A-Roll Video** | `HyperFlow H3 Flash` INT8 (`13.7B`, 6 steps, `CFG=1.0`) + `MiniMaxH3AddGuide` | `5–15%` faster than `Q4_K_M` GGUF on 4090 (`~152–180 s` / 5.2 s @ `1344×768`, `21–22 GiB` VRAM); needs no `ComfyUI-GGUF` or `--fast-disk` Windows workaround |
| **Framing & Motion** | Default **waist-up half-body (`MS`)** + **3/4 medium close-up (`MCU`)** cuts (`5–10 s` beats) | Preserves face pixels & identity while showing hands, posture lean, and natural gestures |
| **Long-Form Assembly** | Clean 1-shot `03_aroll_h3_flash.json` + MCP `batch` + `ffmpeg` join | Avoids 24 GB VRAM/RAM multi-hour batch stalls and lets every beat switch framing |
| **Dual-Drive Placement** | Stage downloads on `E:`; move daily `HyperFlow Flash` + `VoxCPM2` (`~37 GB`) to `D:` NVMe; keep `H3-Image` (`22.2 GB`) on `E:` | Leaves `~168 GB` free on `D:` while keeping daily A-roll + TTS on NVMe |

---

## 3. Architecture & Saved Workflows (`user/default/workflows/`)

```text
[Stage 1: Host Visuals]        [Stage 2: Host Voice]             [Stage 3: Dynamic A-Roll Shot]
01_host_character.json         02_host_voice.json                03_aroll_h3_flash.json
----------------------         ------------------                ----------------------
MiniMax-H3-Image (4 MP)        ComfyUI-VoxCPM (VoxCPM2)          HyperFlow H3 Flash INT8 (6 steps)
- Reuses D: qwen3vl            - Family ref WAV + voice_design   - MiniMaxH3ImageToVideo (fl2va)
- Out: host_ms.png (waist-up)    -> locked host_master.wav       - MiniMaxH3AddGuide (beat WAV @ f=0)
       host_mcu.png (3/4 MCU)  - Script beat WAVs from master    - CreateVideo wires LoadAudio WAV
       (via <Picture 1> edit)                                    - Output: shot_01.mp4 (768p, 24fps)
             |                              |                                   |
             +------------------------------+-----------------------------------+
                                            v
                         [Multi-Shot Episode Automation (Later)]
                 MCP batch(03_aroll_h3_flash.json) -> ffmpeg concat/crossfade
```

### Workflow 1: `01_host_character.json`
- **Nodes:** `UNETLoader` (`minimax_h3_image_pruned_int8_convrot.safetensors`) + `CLIPLoader` (`qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`, `type="minimax"`) + `VAELoader` (`minimax_h3_image_vae_fp16.safetensors`) + `MiniMaxH3ImageConditioning` (with optional `LoadImage` `<Picture 1>` for generating matching `MS` waist-up and `MCU` 3/4 angles at **4 MP**, `6` steps, `CFG=1.0`, prompt expander OFF) + `SaveImage`.
- **Optional Variant:** `akatz-ai/MiniMax-H3-Image-Character-Swap-LoRA` for pose/scene swaps at `1 MP`.

### Workflow 2: `02_host_voice.json`
- **Nodes:** `LoadAudio` (`family_raw.wav` `5–15 s` when deriving a new host, OR `host_voice_master.wav` when generating episode beats) → `VoxCPMVoiceCloning` (`reference_audio`) → `VoxCPMNode` (`VoxCPM2`, `voice_design` filled for character shift during master derivation, empty when cloning from locked master) → `SaveAudio`.

### Workflow 3: `03_aroll_h3_flash.json`
- **Nodes:**
  - `HyperFlowLoader` (`minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors`)
  - `CLIPLoader` (`qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors`, `type="minimax"`)
  - `VAELoader` (`minimax_h3_video_vae_int8_convrot.safetensors` or `fp16` + `minimax_h3_audio_vae_fp32.safetensors`)
  - `LoadImage` (`first_frame`, optional `last_frame`) + `LoadAudio` (beat WAV)
  - `MiniMaxH3ImageToVideo` (`1344×768`, `17k+5` length) → `MiniMaxH3AddGuide` (`frame_idx=0`, `audio` from `LoadAudio`, `audio_vae`)
  - `HyperFlowSigmas` (`steps=6`) + `KSamplerSelect` (`euler`) + `BasicGuider` + `SamplerCustomAdvanced`
  - `VAEDecode` → `CreateVideo` (`fps=24`, **`audio` wired directly to `LoadAudio`** rather than `VAEDecodeAudio` to preserve `48 kHz` `VoxCPM2` audio) → `SaveVideo`.

### Multi-Channel Host Asset Convention (`input/hosts/<channel>/`)
- `host_ms.png` — waist-up studio/set anchor (`MS`)
- `host_mcu.png` — 3/4 chest-up angle (`MCU`)
- `host_voice_master.wav` — locked `10 s` derived character voice

---

## 4. Dependencies, Downloads & Licensing

- **Custom Nodes (`custom_nodes/`):**
  - `wildminder/ComfyUI-VoxCPM`
  - `Video-Rebirth/ComfyUI-HyperFlow-Flash`
- **New Model Files (`~60 GB` total, staged to `E:\ComfyUI\models\` first):**
  - `diffusion_models/minimax_h3_image_pruned_int8_convrot.safetensors` (`21.0 GB`)
  - `vae/minimax_h3_image_vae_fp16.safetensors` (`1.2 GB`)
  - `diffusion_models/minimax_h3_fl2va_hyperflow_flash_14b-int8_convrot.safetensors` (`16.0 GB`)
  - `diffusion_models/minimax_h3_ref2va_hyperflow_flash_14b-int8_convrot.safetensors` (`16.4 GB`, B-roll / multi-ref)
  - `models/tts/VoxCPM/` (`~5 GB`, `VoxCPM2`)
- **Reused from `D:`:** `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` (`15.7 GB`), `minimax_h3_video_vae_int8_convrot.safetensors` (`2.8 GB`), `minimax_h3_audio_vae_fp32.safetensors` (`0.6 GB`).
- **License Note:** MiniMax H3 and MiniMax-H3-Image Community Licenses exclude use in the **US, EU, UK, and South Korea** without separate MiniMax authorization (`platform.minimax.io/h3-license`). `ComfyUI-VoxCPM` / `VoxCPM2` are Apache-2.0; `ComfyUI-HyperFlow-Flash` plugin code is GPL-3.0.

---

## 5. Implementation Plan (Execution Session)

1. **Install packs & stage models on `E:`:**
   - Install `ComfyUI-VoxCPM` and `ComfyUI-HyperFlow-Flash` via ComfyUI-Manager / `apply_manifest` and restart ComfyUI (`.\run.ps1`).
   - Download `MiniMax-H3-Image` (`22.2 GB`) + `HyperFlow H3 Flash` INT8 (`32.4 GB`) to `E:\ComfyUI\models\`.
2. **Author & save 3 Web-UI workflows via MCP:**
   - Build + `create_workflow(action="validate")` each graph, persist via `save_workflow(action="save")` into `user/default/workflows/{01_host_character,02_host_voice,03_aroll_h3_flash}.json`, and verify all 3 open cleanly in ComfyUI's Workflows sidebar.
3. **Run end-to-end A-roll demo:**
   - Generate `host_ms.png` + `host_mcu.png` via `01_host_character.json` (`~14 s` warm each), then call `POST /free`.
   - Derive `host_voice_master.wav` from the family voice recording via `02_host_voice.json`, then synthesize two `~5 s` beat WAVs; call `POST /free`.
   - Render Shot 1 (`MS` waist-up + open-hand gesture) and Shot 2 (`MCU` 3/4 subtle push-in) via `03_aroll_h3_flash.json` (`~6 min` total), inspect lip-sync & join via `ffmpeg`.
   - *(Post-listen gate: if derived multi-channel voices remain too close, optionally add `ComfyUI-Timbre-Transfer` / `Seed-VC` pitch/formant shift.)*
4. **Promote daily keepers to `D:` NVMe:**
   - Move (never copy) `HyperFlow Flash` + `VoxCPM2` weights from `E:` → `D:` NVMe, keeping `MiniMax-H3-Image` on `E:` HDD, and verify `/api/models/*`.


---

## 6. Production Upgrade Plan (`Core + Qwen-2.1 ControlNet`, Approved 2026-11-27)

### Approaches Considered & Settled Choice
1. **3D Director + Core H3 Only (`~5.1 GB`):** `ComfyUI-Jakkanna` (`VNCCS Pose Studio`, `0 GB`) + `h3_image_character_swap_v1` (`155 MB`) + `Combined` (`0 GB`) + `minimax_h3_video_vae_fp16` (`~4.9 GB`). Fast, zero extra base image model, but `H3-Image` lacks hard skeleton ControlNet & RGBA cutout.
2. **Core + `Qwen-Image-2.1 INT8` + `Fun-ControlNet-Union INT8` + `T8 AnyAngle Studio` (Chosen, `~26.2 GB`):** Adds `Qwen-Image-2.1 INT8` (`7.26 GB` DiT + `9.35 GB` `Qwen3-VL-8B` INT8 + `0.68 GB` RGBA VAE) + `qwen_image_2.1_fun_controlnet_union_int8_convrot.safetensors` (`3.78 GB`) + `AnyAngle Studio (T8)`. Gives hard DWPose/Depth/Canny skeleton adherence (`QwenImageDiffsynthControlnet`), natural skin texture, pixel-locked edits (`1024×1024` first pass), and RGBA alpha inside `31.95 GiB` RAM. *(License boundary: `Qwen-2.1` is non-commercial research/eval; swap to `Qwen-Image-Edit-2511` Apache-2.0 for commercial client work.)*
3. **Deferred Heavy Video Alternatives (`SCAIL-2` / `Wan 2.2 Animate`):** Kept out of Phase 1 because `H3 Ref2VA` is the only open model uniting 9 image + 3 video + 3 audio refs with native speech/mouth sync.

### Target Production Workflows (`user/default/workflows/`)
```text
[3D Staging in Browser]
  Jakkanna VNCCS Pose Studio (keyframes / Mixamo FBX)  OR  T8 AnyAngle Studio (288 poses / 3D cam)
         |                                                        |
         +--> [01_host_character.json] H3-Image + Character Swap LoRA (155 MB) + optional 5-view sheet
         +--> [01B_qwen21_pose_edit.json] Qwen-2.1 INT8 + Fun-ControlNet-Union INT8 (hard POSE/Depth + RGBA)
         |
         +--> [02_host_voice.json] VoxCPM2 (Hi-Fi prompt_audio+text OR ref+voice_design + inflect/wetext)
         +--> [03_aroll_h3_flash.json] HyperFlow fl2va 6-step (aspect-locked 1344x768 + LoadAudio beat)
         +--> [04_director_multiref_r2v.json] Combined I2V+R2V (HyperFlow ref2va draft / 20-step ref2va hero)
```

### Step-by-Step Implementation Plan (Next Execution Session)
1. **Fix `VoxCPM2` Text Normalization (`user/comfyui_8188.log:62`):**
   - Install `inflect` and `wetext` into `.venv` (`uv pip install inflect wetext`).
   - Upgrade `02_host_voice.json` to expose both `prompt_audio` + `prompt_text` (Hi-Fi cloning for custom `-3 dBFS`, `8–15 s` dry WAVs) and `reference_audio` + `voice_design` + `VoxCPM_AdvancedParams` (`<=100` words/chunk).
2. **Install Pure-Code Director & Multi-Ref Custom Nodes:**
   - `teenu/ComfyUI-Jakkanna` (`VNCCS Pose Studio` 3D dummy + camera + keyframe timeline + Mixamo FBX; skip optional `2.83 GB` SAM3D unless photo-to-pose is wanted).
   - `entropicnoise/MiniMax-H3-Combined-Image-And-Reference-to-Video` (`first/middle/last_frame` + `<=10` ref images + `<=4` ref videos/audios).
   - `T8mars/Comfyui-Qwen-Image-2.1-MultiAngle-T8` cloned into `custom_nodes/ComfyUI-AnyAngle-Studio-T8` (dotless folder name per README; run `install_assets.py --download-lora`, skip `3.78 GB` TripoSplat unless photo-to-3D is wanted).
   - Optional: `T8mars/comfyui-minimax-h3-audio-T8` (`MiniMaxH3FiveViewConditioningEXPT8`) + `matlod/minimax-h3-turnaround` (`63.1 MB` LoRA) if 1-pass 5-view turnarounds are desired.
3. **Download Production Model Weights (Stage on `E:`, Keep Daily on NVMe):**
   - `models/loras/h3_image_character_swap_v1.safetensors` (`155 MB`, `akatz-ai/MiniMax-H3-Image-Character-Swap-LoRA`).
   - `models/vae/minimax_h3_video_vae_fp16.safetensors` (`~4.9 GB`, sharper faces on `04` hero renders).
   - `Qwen-Image-2.1 INT8` + `Fun-ControlNet-Union INT8` (`21.07 GB` total):
     - `models/diffusion_models/qwen_image_2.1_int8_convrot.safetensors` (`7.26 GB`)
     - `models/text_encoders/qwen3vl_8b_int8_convrot.safetensors` (`9.35 GB`)
     - `models/vae/qwen_image_2.1_vae_bf16.safetensors` (`0.68 GB`)
     - `models/model_patches/qwen_image_2.1_fun_controlnet_union_int8_convrot.safetensors` (`3.78 GB`, `Kijai/QwenImage_experimental`)
4. **Author, Validate & Save Upgraded UI Workflows (`user/default/workflows/`):**
   - Update `01_host_character.json` (multi-ref `<Picture 1..N>` + `h3_image_character_swap_v1.safetensors` pose-swap path) + `02_host_voice.json` + `03_aroll_h3_flash.json` (pre-fit aspect-safe `1344×768`).
   - Create `01B_qwen21_pose_edit.json` (`AnyAngle Studio` / `Jakkanna` POSE → `QwenImageDiffsynthControlnet` + `qwen_image_2.1_int8_convrot`, `1024×1024` base pass to prevent pixel drift + RGBA cutout).
   - Create `04_director_multiref_r2v.json` (`Combined` node + `Jakkanna` 3D dummy video/image + `HyperFlow ref2va` 6-step draft / `20-step ref2va_pruned_int8` + `fp16` VAE hero switch + `LoadAudio` beat sync; always flatten `ref_images.ref_image_N` keys in API payloads and call `POST /free` between stages).
5. **Verify End-to-End Across All Stages:**
   - Restart ComfyUI via `.\run.ps1`, confirm `/object_info` exposes `VNCCS_PoseStudio`, `QwenImageDiffsynthControlnet`, `MiniMaxH3CombinedImageAndReferenceToVideo`, and `AnyAngleStudioT8`, and run one character-sheet → posed-keyframe (`01` + `01B`) → custom-voice (`02`) → multi-ref video (`04`) smoke pass while monitoring `system_stats` RAM headroom.
---

## References

- `comfy_extras/nodes_minimax_h3.py` (`MiniMaxH3ImageToVideo`, `MiniMaxH3AddGuide`, `MiniMaxH3ReferenceToVideo`, `MiniMaxH3ImageConditioning`)
- `Video-Rebirth/hyperflow-h3-flash`: https://github.com/Video-Rebirth/hyperflow-h3-flash
- `Video-Rebirth/ComfyUI-HyperFlow-Flash`: https://github.com/Video-Rebirth/ComfyUI-HyperFlow-Flash
- `wildminder/ComfyUI-VoxCPM`: https://github.com/wildminder/ComfyUI-VoxCPM
- `docs.comfy.org` MiniMax-H3-Image guide: https://docs.comfy.org/tutorials/image/minimax/minimax-h3-image
- `lcz.me` H3-Image 16 GB benchmark: https://lcz.me/topic/2976
- `igorls/comfyui-h3-editor` (evaluated & deferred): https://github.com/igorls/comfyui-h3-editor
- `loopforge0/ComfyUI-H3-Continuous`: https://github.com/loopforge0/ComfyUI-H3-Continuous
- `tenitsky/minimax-h3`: https://github.com/tenitsky/minimax-h3
