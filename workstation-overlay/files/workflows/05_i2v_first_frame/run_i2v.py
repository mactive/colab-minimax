#!/usr/bin/env python3
"""Native MiniMax-H3 (fl2va) First-Frame + Prompt (I2V) Batch Runner for Colab G4 (96GB Blackwell).

Features:
1. Native Full-Step Quality (NO 8-Step Turbo LoRA and NO Realism LoRAs by default):
   - Uses `minimax_h3_fl2va_pruned_fp8_scaled.safetensors` (`--profile scheme_b`) directly
     with `MiniMaxH3SigmaShift (12.0 / 3.0)` and `BasicGuider` (25 steps default).
   - Preserves 2D hand-drawn ink lines, watercolor/gouache grain, and strict first-frame fidelity.
2. Live ComfyUI `/object_info` Auto-Adaptation:
   - Automatically detects whether `MiniMaxH3ImageToVideo` expects `first_frame` or `start_image`,
     whether it accepts `audio_vae`, and whether `LTXVSeparateAVLatent` is registered.
3. Multi-Shot Config & History-Safe Drive Archiving:
   - Processes each shot independently from `i2v_config.json` (filterable via `--shots 1,2`),
     saves individual `<output_name>` (e.g. `001.mp4`, `002.mp4`) to Google Drive with automatic
     `_hist_NNN` archiving, and optionally stitches a preview compilation.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional

if os.path.isdir("/content/drive/My Drive") and not os.path.exists("/content/drive/MyDrive"):
    os.symlink("/content/drive/My Drive", "/content/drive/MyDrive")

DRIVE_WORKSTATION = Path("/content/drive/MyDrive/AI_Workstation")
DRIVE_COMFY = DRIVE_WORKSTATION / "ComfyUI"
LOCAL_COMFY = Path("/content/ComfyUI")
API_URL = "http://127.0.0.1:8188"


def is_comfy_up() -> bool:
    try:
        urllib.request.urlopen(f"{API_URL}/system_stats", timeout=3)
        return True
    except Exception:
        return False


def ensure_comfy_running(profile: str = "scheme_b") -> None:
    if is_comfy_up():
        print("⚡ ComfyUI 已在 127.0.0.1:8188 运行中！", flush=True)
        return
    launcher = Path("/tmp/launch_g4_comfyui_fast.py")
    if not launcher.exists():
        launcher = DRIVE_WORKSTATION / "scripts/launch_g4_comfyui_fast.py"
    print(f"🚀 正在启动 launch_g4_comfyui_fast.py (--profile {profile})...", flush=True)
    subprocess.run([sys.executable, "-u", str(launcher), "--profile", profile], check=True)
    for _ in range(60):
        if is_comfy_up():
            return
        time.sleep(2)
    raise RuntimeError("❌ ComfyUI 启动超时，请检查 /tmp/comfyui.log")


def find_image_file(fname: str, workflow_dir: Path) -> Optional[Path]:
    p = Path(fname)
    if p.is_absolute() and p.exists():
        return p
    candidates = [
        workflow_dir / "inputs" / fname,
        workflow_dir / fname,
        Path.cwd() / "inputs" / fname,
        Path.cwd() / fname,
        Path("/tmp") / fname,
        LOCAL_COMFY / "input" / fname,
        DRIVE_COMFY / "input" / fname,
    ]
    return next((c for c in candidates if c.exists()), None)


def stage_image(fname: str, workflow_dir: Path) -> str:
    found = find_image_file(fname, workflow_dir)
    if not found:
        raise FileNotFoundError(
            f"❌ 找不到首帧图片: {fname}\n"
            f"   已搜索: {workflow_dir / 'inputs'}, {LOCAL_COMFY / 'input'}, {DRIVE_COMFY / 'input'}"
        )
    base_name = found.name
    dst_local = LOCAL_COMFY / "input" / base_name
    dst_local.parent.mkdir(parents=True, exist_ok=True)
    if found.resolve() != dst_local.resolve():
        shutil.copy2(found, dst_local)
    dst_drive = DRIVE_COMFY / "input" / base_name
    if (DRIVE_COMFY / "input").exists() and found.resolve() != dst_drive.resolve():
        shutil.copy2(found, dst_drive)
    print(f"✅ 首帧图已就位本地 SSD: {base_name} ({dst_local.stat().st_size / 1024:.1f} KB)", flush=True)
    return base_name


def snap_h3_length(length: int) -> int:
    """Snap frame count to nearest valid MiniMax-H3 17k + 5 grid point."""
    k = max(1, round((length - 5) / 17))
    return 17 * k + 5


def build_shot_workflow(
    base_wf: dict,
    cfg: dict,
    shot: dict,
    obj_info: dict,
    image_name: str,
    prompt_lang: str,
    steps_override: Optional[int],
) -> tuple[dict, str]:
    wf = copy.deepcopy(base_wf)

    prefix = cfg.get("project_prefix", "SpaceMining_H3_Native")
    shot_id = int(shot["shot_id"])
    save_prefix = f"{prefix}_{shot_id:03d}"

    # 1. Core model & VAE loaders
    wf["1"]["inputs"]["unet_name"] = cfg.get("unet_name", "minimax_h3_fl2va_pruned_fp8_scaled.safetensors")
    wf["6"]["inputs"]["clip_name"] = cfg.get("clip_name", "qwen3vl_32b_heretic_minimax_h3_nvfp4.safetensors")
    wf["7"]["inputs"]["vae_name"] = cfg.get("video_vae_name", "minimax_h3_video_vae_fp16.safetensors")
    wf["8"]["inputs"]["vae_name"] = cfg.get("audio_vae_name", "minimax_h3_audio_vae_fp32.safetensors")

    # Optional Turbo LoRA (disabled by default for native MiniMax-H3)
    use_turbo = bool(cfg.get("use_turbo_lora", False))
    if use_turbo:
        wf["4"] = {
            "class_type": "LoraLoaderModelOnly",
            "inputs": {
                "model": ["1", 0],
                "lora_name": cfg.get("turbo_lora_name", "minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors"),
                "strength_model": float(cfg.get("turbo_lora_strength", 0.85)),
            },
        }
        wf["5"]["inputs"]["model"] = ["4", 0]
    else:
        wf.pop("4", None)
        wf["5"]["inputs"]["model"] = ["1", 0]

    # Sigma shift
    wf["5"]["inputs"]["shift_video"] = float(shot.get("shift_video", cfg.get("shift_video", 12.0)))
    wf["5"]["inputs"]["shift_audio"] = float(shot.get("shift_audio", cfg.get("shift_audio", 3.0)))

    # 2. Image & Prompt
    wf["10"]["inputs"]["image"] = image_name
    prompt = shot.get(f"prompt_{prompt_lang}") or shot.get("prompt_en") or shot.get("prompt_zh") or shot.get("prompt")
    if not prompt:
        raise ValueError(f"❌ 镜头 {shot_id} 缺少提示词 (prompt_en / prompt_zh / prompt)")

    raw_len = int(shot.get("length", cfg.get("default_length", 243)))
    length = snap_h3_length(raw_len)
    if length != raw_len:
        print(f"ℹ️ 镜头 {shot_id} 帧数 {raw_len} 自动对齐至 MiniMax-H3 合法网格 {length} (17k+5)", flush=True)

    width = int(shot.get("width", cfg.get("width", 1344)))
    height = int(shot.get("height", cfg.get("height", 768)))
    fps = float(shot.get("fps", cfg.get("fps", 24.0)))
    steps = int(steps_override if steps_override is not None else shot.get("steps", cfg.get("steps", 25)))
    seed = int(shot.get("seed", 2026112500 + shot_id))

    # 3. Live /object_info auto-adaptation for MiniMaxH3ImageToVideo
    i2v_info = obj_info.get("MiniMaxH3ImageToVideo", {})
    i2v_input_spec = i2v_info.get("input", {})
    all_i2v_keys = set(i2v_input_spec.get("required", {}).keys()) | set(i2v_input_spec.get("optional", {}).keys())

    i2v_inputs: Dict[str, object] = {
        "clip": ["6", 0],
        "vae": ["7", 0],
        "prompt": prompt,
        "width": width,
        "height": height,
        "length": length,
    }
    if "audio_vae" in all_i2v_keys:
        i2v_inputs["audio_vae"] = ["8", 0]

    if "first_frame" in all_i2v_keys or not all_i2v_keys:
        i2v_inputs["first_frame"] = ["10", 0]
    elif "start_image" in all_i2v_keys:
        i2v_inputs["start_image"] = ["10", 0]
    elif "image" in all_i2v_keys:
        i2v_inputs["image"] = ["10", 0]
    else:
        i2v_inputs["first_frame"] = ["10", 0]

    # Optional last_frame support
    if shot.get("last_frame_staged"):
        wf["11"] = {"class_type": "LoadImage", "inputs": {"image": shot["last_frame_staged"]}}
        if "last_frame" in all_i2v_keys or not all_i2v_keys:
            i2v_inputs["last_frame"] = ["11", 0]
        elif "end_image" in all_i2v_keys:
            i2v_inputs["end_image"] = ["11", 0]

    wf["20"]["inputs"] = i2v_inputs

    # 4. Sampling params
    wf["22"]["inputs"]["steps"] = steps
    wf["22"]["inputs"]["scheduler"] = shot.get("scheduler", cfg.get("scheduler", "simple"))
    wf["24"]["inputs"]["sampler_name"] = shot.get("sampler_name", cfg.get("sampler_name", "res_multistep"))
    wf["25"]["inputs"]["noise_seed"] = seed

    # 5. Live /object_info check for LTXVSeparateAVLatent
    if "LTXVSeparateAVLatent" not in obj_info:
        print("ℹ️ 未检测到 LTXVSeparateAVLatent，改为将采样潜变量直连 VAEDecode / VAEDecodeAudio", flush=True)
        wf.pop("30", None)
        wf["31"]["inputs"]["samples"] = ["27", 0]
        wf["32"]["inputs"]["samples"] = ["27", 0]

    # 6. Output video settings
    wf["34"]["inputs"]["fps"] = fps
    wf["35"]["inputs"]["filename_prefix"] = save_prefix

    return wf, save_prefix


def submit_and_wait(workflow: dict, label: str) -> dict:
    payload = json.dumps({"prompt": workflow}).encode("utf-8")
    req = urllib.request.Request(
        f"{API_URL}/prompt",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        resp = json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="ignore")
        raise RuntimeError(f"❌ 提交工作流失败 ({label}): HTTP {e.code} -> {err_body}") from e

    if resp.get("node_errors"):
        raise RuntimeError(f"❌ 节点参数校验失败 ({label}): {json.dumps(resp['node_errors'], ensure_ascii=False)}")

    prompt_id = resp["prompt_id"]
    print(f"🎬 [{label}] 已提交队列 | prompt_id={prompt_id}", flush=True)
    t0 = time.time()
    last_log_len = 0

    while True:
        time.sleep(4)
        log_p = Path("/tmp/comfyui.log")
        if log_p.exists():
            log_txt = log_p.read_text(errors="ignore")
            if len(log_txt) > last_log_len:
                new_lines = [
                    l.strip()
                    for l in log_txt[last_log_len:].splitlines()
                    if any(k in l for k in ["%", "it/s", "s/it", "Prompt executed", "Error", "Exception", "MiniMax"])
                ]
                if new_lines:
                    print(f"  [{time.time()-t0:.0f}s] " + " | ".join(new_lines[-2:]), flush=True)
                last_log_len = len(log_txt)

        hist_raw = urllib.request.urlopen(f"{API_URL}/history/{prompt_id}", timeout=10).read().decode()
        hist = json.loads(hist_raw)
        if prompt_id in hist:
            entry = hist[prompt_id]
            status = entry.get("status", {})
            if status.get("status_str") == "error":
                raise RuntimeError(f"❌ 执行报错 ({label}): {json.dumps(status, ensure_ascii=False)}")
            print(f"✅ [{label}] 渲染完成！耗时: {time.time() - t0:.1f}s", flush=True)
            return entry


def safe_copy_to_drive_with_history(src: Path, dst_drv: Path) -> None:
    dst_drv.parent.mkdir(parents=True, exist_ok=True)
    if dst_drv.exists() and src.resolve() != dst_drv.resolve():
        idx = 1
        while True:
            hist_p = dst_drv.with_name(f"{dst_drv.stem}_hist_{idx:03d}{dst_drv.suffix}")
            if not hist_p.exists():
                shutil.copy2(dst_drv, hist_p)
                print(f"📦 已自动归档云端历史版本: {hist_p.name}", flush=True)
                break
            idx += 1
    if src.resolve() != dst_drv.resolve():
        shutil.copy2(src, dst_drv)


def find_rendered_mp4(save_prefix: str) -> Path:
    out_dirs = [LOCAL_COMFY / "output", DRIVE_COMFY / "output"]
    candidates: List[Path] = []
    for od in out_dirs:
        if od.exists():
            candidates.extend([p for p in od.glob(f"{save_prefix}*.mp4") if "_hist_" not in p.name])
    candidates.sort(key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise FileNotFoundError(f"❌ 未在 ComfyUI/output 找到渲染结果: {save_prefix}*.mp4")
    return candidates[-1]


def stitch_preview(mp4_files: List[Path], out_path: Path) -> None:
    concat_list = Path("/tmp/concat_i2v_preview.txt")
    concat_list.write_text("".join(f"file '{p}'\n" for p in mp4_files), encoding="utf-8")
    tmp_out = Path(f"/tmp/{out_path.name}")
    subprocess.run(
        [
            "ffmpeg", "-y",
            "-f", "concat", "-safe", "0",
            "-i", str(concat_list),
            "-c:v", "libx264", "-crf", "15", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k",
            str(tmp_out),
        ],
        check=True,
    )
    safe_copy_to_drive_with_history(tmp_out, out_path)
    print(f"🎬 预览拼片已同步至 Google Drive: {out_path} ({tmp_out.stat().st_size / (1024**2):.2f} MB)", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Native MiniMax-H3 First-Frame + Prompt (I2V) Batch Runner")
    parser.add_argument("--config", default="i2v_config.json", help="Path to i2v_config.json")
    parser.add_argument("--workflow", default="workflow_i2v_native.json", help="Path to workflow_i2v_native.json")
    parser.add_argument("--shots", default=None, help="Comma-separated shot IDs to render, e.g. '1,2' or '2'")
    parser.add_argument("--lang", choices=["en", "zh"], default=None, help="Override prompt language (en or zh)")
    parser.add_argument("--steps", type=int, default=None, help="Override sampling steps (default from config, e.g. 25)")
    parser.add_argument("--no-stitch", action="store_true", help="Do not stitch preview compilation MP4")
    args = parser.parse_args()

    t_start = time.time()
    cfg_path = Path(args.config).resolve()
    wf_path = Path(args.workflow).resolve()
    workflow_dir = cfg_path.parent

    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    base_wf = json.loads(wf_path.read_text(encoding="utf-8"))

    profile = cfg.get("profile", "scheme_b")
    ensure_comfy_running(profile=profile)

    obj_info = json.loads(urllib.request.urlopen(f"{API_URL}/object_info", timeout=15).read().decode())
    if "MiniMaxH3ImageToVideo" not in obj_info:
        raise RuntimeError("❌ 当前 ComfyUI 未注册 MiniMaxH3ImageToVideo 节点，请检查 ComfyUI 版本。")

    selected_ids = {int(x.strip()) for x in args.shots.split(",") if x.strip()} if args.shots else None
    shots = [s for s in cfg.get("shots", []) if selected_ids is None or int(s["shot_id"]) in selected_ids]
    if not shots:
        raise ValueError("❌ 未匹配到任何待渲染镜头，请检查 i2v_config.json 或 --shots 参数。")

    prompt_lang = args.lang or cfg.get("prompt_lang", "en")
    out_subdir = cfg.get("output_subdir") or cfg.get("project_prefix", "H3_I2V_Output")
    drv_out_dir = DRIVE_COMFY / "output" / out_subdir
    drv_out_dir.mkdir(parents=True, exist_ok=True)

    rendered_locals: List[Path] = []
    for shot in shots:
        shot_id = int(shot["shot_id"])
        title = shot.get("title", f"Shot{shot_id:03d}")
        out_name = shot.get("output_name") or f"{shot_id:03d}.mp4"
        print(f"\n==================== 镜头 {shot_id:03d}: {title} ====================", flush=True)

        img_name = stage_image(shot["first_frame"], workflow_dir)
        shot_copy = copy.deepcopy(shot)
        if shot.get("last_frame"):
            shot_copy["last_frame_staged"] = stage_image(shot["last_frame"], workflow_dir)

        wf, save_prefix = build_shot_workflow(
            base_wf=base_wf,
            cfg=cfg,
            shot=shot_copy,
            obj_info=obj_info,
            image_name=img_name,
            prompt_lang=prompt_lang,
            steps_override=args.steps,
        )

        steps_used = wf["22"]["inputs"]["steps"]
        turbo_state = "OFF (原生满血)" if not cfg.get("use_turbo_lora", False) else "ON"
        print(
            f"⚙️ 模型={wf['1']['inputs']['unet_name']} | Turbo={turbo_state} | "
            f"Steps={steps_used} | {wf['20']['inputs']['width']}x{wf['20']['inputs']['height']} | "
            f"Length={wf['20']['inputs']['length']}f | Lang={prompt_lang}",
            flush=True,
        )

        submit_and_wait(wf, f"Shot {shot_id:03d} ({title})")
        mp4_src = find_rendered_mp4(save_prefix)
        local_copy = Path(f"/tmp/{out_name}")
        shutil.copy2(mp4_src, local_copy)
        drv_dst = drv_out_dir / out_name
        safe_copy_to_drive_with_history(local_copy, drv_dst)
        print(f"☁️ 独立分镜已落盘 Google Drive: {drv_dst} ({local_copy.stat().st_size / (1024**2):.2f} MB)", flush=True)
        rendered_locals.append(local_copy)

    if not args.no_stitch and cfg.get("stitch_preview", True) and len(rendered_locals) > 1:
        preview_name = cfg.get("preview_mp4") or f"{cfg.get('project_prefix', 'H3_I2V')}_Preview.mp4"
        stitch_preview(rendered_locals, drv_out_dir / preview_name)

    print(f"\n🎉 ALL_I2V_DONE (共完成 {len(rendered_locals)} 个镜头，总耗时 {time.time() - t_start:.1f}s)", flush=True)


if __name__ == "__main__":
    main()
