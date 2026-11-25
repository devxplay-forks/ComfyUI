# ComfyUI Local Server & Video Generation Notes

Maintained working knowledge for this machine (`C:\Users\payne\github\devxplay-forks\ComfyUI` → `D:\workspace\github\devxplay-forks\ComfyUI`).

---

## 1. Machine Profile & Storage Strategy

| Resource | Spec | Notes |
|---|---|---|
| **GPU** | NVIDIA RTX 4090 (24 GB VRAM, SM 8.9, Driver 621.14) | Supports FP16/BF16/FP8/INT8/NVFP4 via `comfy-kitchen` CUDA backend (`sol_attn`). |
| **CPU / RAM** | AMD Ryzen 7 3700X (8C/16T), **31.9 GB RAM** | Main constraint for >25 GB models is system RAM headroom, not GPU compute. |
| **PyTorch / Stack** | Python 3.13 (`mise`), `uv`, PyTorch `2.14.1+cu130`, `comfy-aimdo 0.6.0`, `comfy-kitchen 0.2.42` | `triton`, `sageattention`, `flash_attn`, `xformers` are not installed by default. |
| **`D:` NVMe (954 GB)** | ADATA SX8200PNP (~205 GB free; `models/` is ~60.5 GB) | Holds repo, `.venv`, config, and **active models**. `comfy-aimdo` uses `fast_disk=True` here. |
| **`E:` SATA HDD (3.7 TB)** | TOSHIBA MG04ACA400N (~1.8 TB free) | Best target for `--output-directory` (video renders) and archived/cold models via `extra_model_paths.yaml`. |
| **`M:` SATA SSD (238 GB)** | Plextor PX-256M6Pro (~237 GB free, empty) | Available as overflow SSD storage if `D:` fills up. |

### Windows Network / Proxy Gotcha
- `HKCU\Environment` currently has no `HTTP_PROXY`/`NO_PROXY` set (checked `2026-11-24`). If proxy variables are re-enabled later (`http://100.119.221.61:1055`), include `100.70.219.30` in `NO_PROXY` so local calls to `http://100.70.219.30:8188` bypass the proxy.
- Git Bash / MSYS2 rewrites `https://...` arguments unless escaped or written cleanly (e.g. `notes.md` incident).

---

## 2. Running ComfyUI as a Standard Service (`tmux` + `run.ps1`)

- **Service model:** Foreground `.\run.ps1` inside Windows `tmux` listening on `0.0.0.0:8188` (no `service.ps1` / `nssm.exe`; ComfyUI has no built-in daemon and `tmux` keeps `mise`, `uv`, `HKCU` env vars, and live logs simple).
- **Target `run.ps1` behavior:**
  - **Listen/GPU:** `--listen 0.0.0.0 --port 8188`, `PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"`.
  - **Defaults ON:** `--enable-manager` (`-NoManager` to disable) and `--preview-method auto` (`-NoPreview` to disable).
  - **Storage split:** Keep `models/`, config, and `temp/` on `D:` NVMe; default `-OutputDir "E:\ComfyUI\output"` (`--output-directory`, created if missing).
  - **Fast restarts:** Remove `mise self-update -y`; hash-check `requirements.txt` (+ `manager_requirements.txt`) against `.venv\.req_hash` and skip `uv pip install` when unchanged (`-ForceSync` to override).
- **Disproved tuning (`2026-11-03`):**
  - `--disable-pinned-memory` was A/B tested on 768p×362f and showed **no gain** (`227.4 s/step` vs `~228 s/step` baseline, with `17.5 GB` RAM free). Remove `--disable-pinned-memory` and `-NoMemoryTuning`; leave ComfyUI's default `DynamicVRAM`, `--async-offload`, and `fast_disk` enabled.

---

## 3. Control Model: REST/WebSocket API vs MCP

- **Standard Service first:** Run ComfyUI normally on `0.0.0.0:8188`. Browser (MacMini over Tailscale `http://100.70.219.30:8188`), direct REST/WS scripts, and MCP all talk to the same server.
- **Pi Built-in MCP (`~/dotfiles/pi/agent/mcp.json` → `~/.pi/agent/mcp.json`):**
  - Pi has native built-in MCP (no adapter package needed). Because `~/.pi/agent/settings.json` sets `"defaultTools": ["-codemode"]`, MCP servers in `mcp.json` must use `"exposure": "deferred"` (via `tool_search`) or `"exposure": "direct"`.
  - **Chosen for shared Tailscale config (`artokun/comfyui-mcp` via `npx -y comfyui-mcp`):** Pure REST + WebSocket against `COMFYUI_URL=http://100.70.219.30:8188`. Works identically from MacMini and Windows with one shared `mcp.json` (remote `/object_info`, graph build/validate, `enqueue_workflow`, `clear_vram` `/free`, `diagnose` + logs, `list_outputs`). Note: uses `better-sqlite3` + `sharp`, so invoke via `npx` (Node 26.13), not `bunx`.
  - **Why official `Comfy-Org/comfy-mcp` (`uvx`) was not chosen for shared Tailscale config:** It wraps `comfy-cli` (`comfy --where local`). With `COMFYUI_URL`, only submit/status/upload/fetch hit the remote host; `nodes`, `validate_workflow`, and `get_logs` still resolve local-only (failing on MacMini), and `download_model` refuses remotely.
  - **Optional upgrade:** Running `npx -y comfyui-mcp --http --host 100.70.219.30 --port 9100` on Windows would let MacMini access local Windows `D:\models` / `restart_comfyui` over HTTP if needed later.
- **In-app agent (`--enable-agent`):** Experimental ComfyUI flag mounting `/api/agent` (requires unbundled `comfy-agent` wheel).

---

## 4. REST & WebSocket API Patterns (`http://127.0.0.1:8188`)

- **Core endpoints:**
  - `POST /prompt` — submit **API-format** workflow JSON (`{"prompt": {...}, "client_id": "..."}`).
  - `WS /ws?clientId=...` — live `progress` (`value`/`max`), `execution_start`, `execution_error`, `execution_interrupted` events.
  - `GET /history/{prompt_id}` — poll completion and output filenames/metadata silently (avoid printing every poll tick).
  - `POST /interrupt` + `POST /queue` (`{"clear": true}`) — stop a running job cleanly.
  - `POST /free` (`{"unload_models": true, "free_memory": true}`) — unload models from VRAM/RAM after a batch (e.g. restores ~22.4 GB VRAM free from ~1.2 GB without restarting ComfyUI).
- **Fast A/B benchmarking rule:** Never wait 20–75 min just to test a resolution/sampler/LoRA change. Measure the deltas between steps 1→3 over `/ws`, then `/interrupt` + `/free`.
- **Autogrow V3 socket namespacing:** In API JSON, Autogrow inputs must be namespaced as `"<group>.<socket>"` (e.g., `"ref_images.ref_image_0"`, NOT `"ref_image_0"` which raises `TypeError`).

---

## 5. Model & Video Generation Lessons (24 GB VRAM)

### Quantization & Speedups
- **cu130 + 24 GB VRAM sweet spot (MiniMax H3):** `int8_convrot` (UNet + Video VAE) + `nvfp4_awq` (text encoder).
- **CFG 1.0 short-circuit (`comfy/samplers.py:609-620`):** `cfg = 1.0` drops the unconditional forward pass completely (**~2× per-step speedup**). Only use CFG > 1.0 when the model/LoRA actually requires negative conditioning.
- **Measured MiniMax H3 benchmarks (RTX 4090, 362 frames = 15.1s @ 24fps):**
  - `960×544`, 20 steps, CFG 6.0: **~22–23 min**
  - `1344×768`, 20 steps, CFG 6.0: **76 min** (`227.4 s/step`)
  - `1344×768`, 8 steps, CFG 1.0, `res_multistep` + `fl2v` turbo LoRA: **16.1 min** (`114.4 s/step`, **4.73× total speedup**)
  - `960×544`, 124 frames (5.17s), 20 steps, CFG 1.0, R2V (`ref2va`, no LoRA): **~2.2 min** (`133.5–137.5s`)

### Character Consistency & Continuity (MiniMax H3)
- **Use the right model variant:** `fl2va` (`MiniMaxH3ImageToVideo`) ignores character reference sheets unless wired as `first_frame`; identity preservation requires **`ref2va`** (`MiniMaxH3ReferenceToVideo` with `<Picture 1>`, `<Picture 2>` tags).
- **Match LoRAs to the base model:** `fl2va` uses `minimax_h3_fl2v_turbo_8step_v1.0`; `ref2va` uses `minimax_h3_ref2v_turbo_4step_v0.1`. Turbo LoRAs trade away character likeness—prefer **20–25 steps without LoRA** and **`normal` or `beta` scheduler** when reference fidelity matters.
- **Clean single-subject references:** Crop multi-view character turnaround sheets to a single clean front view before feeding R2V.
- **Watch style keywords:** Words like `"animated"` or `"cinematic"` push R2V toward 3D Pixar/CGI shading; explicit medium words (`"2D hand-drawn anime, cel-shaded flat coloring, clean black line art, not 3D, not CGI"`) keep 2D illustration style intact.
- **Multi-clip continuity:** Chaining `last_frame` → `first_frame` across separate generations produces hard scene cuts; true seamless continuation requires AV latent-tail continuation custom nodes (available via ComfyUI-Manager).

---

## 6. Settled Implementation Plan (2026-11-24)

1. **Cleanup staged files:** `git reset HEAD`; delete `generate_adventure.py`, `notes.md`, `poll_comfyui.py`, `probe_cfg.py`, `probe_step_time.py`, `r2v_generate.py`. Keep `run.ps1` + `docs/NOTE.md`.
2. **Harden `run.ps1`:** Drop `mise self-update -y`, `--disable-pinned-memory`, `-NoMemoryTuning`; default `-OutputDir "E:\ComfyUI\output"`, Manager ON (`-NoManager`), Preview ON (`-NoPreview`), `.venv\.req_hash` gate (`-ForceSync`), keep `PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"`.
3. **Verify service:** Parse-check `run.ps1`, start in Windows `tmux`, verify `:8188/system_stats` locally and from MacMini (`http://100.70.219.30:8188`), verify `E:\ComfyUI\output` created.
4. **Configure shared MCP:** Add `"comfyui"` (`npx -y comfyui-mcp`, `exposure: "deferred"`, `COMFYUI_URL: "http://100.70.219.30:8188"`) to `~/dotfiles/pi/agent/mcp.json`; verify `pi mcp list` on Windows and MacMini. (If `HTTP_PROXY` is ever re-enabled on Windows, add `100.70.219.30` to `NO_PROXY`.)
5. **Commit on `master`:** Stage and commit `run.ps1` and `docs/NOTE.md`.

---

## 7. Log
- **2026-11-24:** Initialized `docs/NOTE.md` from prior session findings (`2026-11-02`, `2026-11-03`, `2026-11-05`); updated with settled `run.ps1` (`tmux`), `E:\ComfyUI\output`, Tailscale `NO_PROXY`, and shared `artokun/comfyui-mcp` (`npx`) MCP plan.
