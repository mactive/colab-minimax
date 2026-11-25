# 🎬 工作流 05：MiniMax-H3 原生首帧 + 提示词（I2V，无 Turbo LoRA）

专用于 **纯「首帧图 + 提示词」图生视频（I2V）**，默认采用原生满血 **`minimax_h3_fl2va_pruned_fp8_scaled.safetensors`**（`--profile scheme_b`），**不挂载 8-Step Turbo LoRA，也不挂载真人去油 LoRA**，最大程度保留 2D 手绘工业线描、水彩/水粉颗粒与原画构图。

## 📂 目录结构

- `i2v_config.json`：镜头配置文件（已预填 `manifest.csv` 的镜头 001「冰封母港」与镜头 002「黑暗采区」，10 秒 = `243` 帧 @ 24fps）。
- `workflow_i2v_native.json`：原生 `MiniMaxH3ImageToVideo` + `MiniMaxH3SigmaShift (12.0/3.0)` + `BasicGuider`（默认 `25` 步）API 工作流模板。
- `run_i2v.py`：云端 G4 批量执行器（自动适配 ComfyUI `/object_info`、独立输出 `001.mp4` / `002.mp4` 并可选拼接预览视频）。
- `inputs/`：存放首帧原图（已放入 `001.png` 和 `002.png`）。

## 🚀 运行方式

在本地工作区根目录直接运行一键脚本（自动同步最新 `i2v_config.json` 与 `inputs/` 到云盘 → 启动 G4 → 跑完自动强杀并对账 CCU）：

```bash
# 运行全部配置镜头（001 + 002）
./run_h3_i2v.sh

# 只重跑第 2 镜，或自定义步数 / 切换中文提示词
./run_h3_i2v.sh --shots 2
./run_h3_i2v.sh --steps 30 --lang zh
```

## 📤 云盘输出位置

- 独立镜头：`/content/drive/MyDrive/AI_Workstation/ComfyUI/output/SpaceMining_H3_Native/001.mp4`、`002.mp4`
- 预览拼片：`/content/drive/MyDrive/AI_Workstation/ComfyUI/output/SpaceMining_H3_Native/SpaceMining_H3_Native_Shots01_02_Preview.mp4`
