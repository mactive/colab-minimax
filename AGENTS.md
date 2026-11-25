# AGENTS.md

给在这个仓库里工作的 AI 编程助手 / 新协作者的说明。面向用户的完整用法见 `README.md`。

## 项目是什么

在 macOS 上用 **colab-cli** 远程驱动 Google Colab GPU（G4 / A100 / H100），跑 **MiniMax-H3**（ComfyUI）视频生成。分三种用法：

| 入口 | 作用 | 结束时 |
|---|---|---|
| `init_drive_h3_cpu.sh` | 一次性：CPU 实例把 ComfyUI、插件、19 个模型、TTS 下载到 Google Drive `MyDrive/AI_Workstation/` | 等 DriveFS 上传完再关机 |
| `run_h3_i2v.sh` / `run_h3_drama.sh` | 抢 GPU → 挂 Drive → 冷启动 ComfyUI → 后台渲染并轮询 → 存 Drive | **自动关机**，并输出 CCU 对账 |
| `novum_colab_server.sh` | 把一台 GPU 当 Novum Agent 的远程 ComfyUI（SSH 隧道到本机 `127.0.0.1:18188`） | **从不自动关机**；`release` 才释放 |

数据流：HuggingFace →（init，CPU 实例）→ 你的 Google Drive（长期保存，只存一份）→（每次开 GPU）`launch_g4_comfyui_fast.py` 把当前 profile 需要的模型复制到 GPU 本地 NVMe → ComfyUI。

## 目录

```
bootstrap.sh              初始化：依赖检查 + clone upstream + 叠加 overlay；--save-overlay 把改动存回 overlay
proxy_env.sh              所有脚本都会 source：默认走 127.0.0.1:7897，USE_PROXY=0 关闭
colab_meter.sh            CCU 计费打点 / 对账；stop --all 能释放 untracked 会话
init_drive_h3_cpu.sh  run_h3_i2v.sh  run_h3_drama.sh  novum_colab_server.sh
workstation-overlay/      本项目对 upstream 的修改（见下）
colab-ultra-workstation/  upstream clone（.gitignore 里，不提交）
runtime/ logs/            运行时文件、失败时自动下载的云端日志（不提交）
```

### upstream 和 overlay

`colab-ultra-workstation/` 是 `yuanyang749/colab-ultra-workstation` 的 clone，固定在 `workstation-overlay/UPSTREAM` 记录的 commit。本项目的修改分两部分：
- `workstation-overlay/local.patch`：对 upstream 已有文件的修改。目前有两处：`launch_g4_comfyui_fast.py` 按显存选择启动参数（A100-40GB 上不用 `--highvram`）；`setup_minimax_h3_comfyui.py` 按远端字节数校验文件，不完整就重新下载。
- `workstation-overlay/files/`：upstream 里没有的新文件，目前是 `workflows/05_i2v_first_frame/`。其中 `inputs/` 下的首帧图属于个人素材，**不提交**（已写进 .gitignore）。新环境里要自己把图片放进 `colab-ultra-workstation/workflows/05_i2v_first_frame/inputs/`，文件名和 `i2v_config.json` 里的 `first_frame` 对应。

**改了 `colab-ultra-workstation/` 里的文件后，必须运行 `./bootstrap.sh --save-overlay`，再提交 `workstation-overlay/`**，否则这些改动不会进入本仓库。要新增整个目录时，把它加进 `bootstrap.sh` 的 `EXTRA_PATHS`。

## 踩过的坑（改脚本前必读）

1. **macOS 自带 bash 3.2**：在 `set -u` 下展开空数组会报 unbound variable，要写成 `${arr[@]+"${arr[@]}"}`。不要使用 bash 4 才有的特性（关联数组、`${var,,}`、`mapfile` 等）。
2. **colab-cli 0.8.0 的 `colab exec` 没有 `-c`，也不支持 `--`**：代码只能从 stdin 或 `-f 文件` 传进去。脚本里统一用 `cexec '<py>'`；需要超时的地方用 `cexec_alarm 20 '<py>'`，它借助 `perl alarm`，因为 macOS 没有 `timeout` 命令。
3. **pgrep 会匹配到自己**：远端检测进程时，用 `subprocess.run(["pgrep","-f","[h]3_i2v_run.sh"])`，不经过 shell，正则也写成 `[x]` 的形式。另外，日志里出现 `EXIT_CODE=` 就算任务结束，这是第二道判断。
4. **Ctrl+C 会被 `|| true` 吞掉**：轮询写的是 `OUT=$(... || true)`，Ctrl+C 只杀掉了子进程。所以每个脚本都要有 `trap '...; exit 130' INT TERM`，真正的关机清理放在 `trap cleanup EXIT` 里。
5. **Colab 实例会丢失**（被回收或崩溃）：此时 `colab exec` 会输出 `appears to be lost` 或 `Session '<name>' not found`。轮询时要识别出来并退出，不能无限循环。
6. **DriveFS 是异步上传的**：文件写到 `/content/drive/...` 只是进了本地缓存，**关闭后才在后台上传**。在上传完成前关机，文件就丢了。init 关机前会执行 `wait_drive_flush`（检测实例的网络上行流量）。判断文件是否完整，永远以远端字节数为准，不要用"大于多少 KB"这种判断。
7. **`colab new` 返回 503 后，cli 会自己重试，可能在后台已经租到了机器**；之后再执行 `new` 会得到 412。所以抢机前后都要用 `colab sessions` 检查同名会话，已经存在就直接复用（`session_hw`）。
8. **Colab 一台机器同时只允许一条 SSH 连接**（第二条会返回 HTTP 429）。`novum_colab_server.sh` 让隧道和 rsync 共用同一条 ControlMaster 连接（`runtime/ssh-<session>.ctl`）。隧道开着的时候，不要再对这台机器执行 `colab ssh`。
9. **大文件不要用 `colab upload` 走代理传**（2 GB 时出现过 Broken pipe），改用 `rsync -P --partial` 走 SSH。
10. **不要原地编辑正在运行的 bash 脚本**：bash 是边执行边读的。要先写到 `*.new`，再 `mv` 覆盖（替换 inode），正在跑的进程会继续读旧内容。
11. `launch_g4_comfyui_fast.py` 会顺带开一个 cloudflared 公网隧道，**没有任何鉴权**。`novum_colab_server.sh up` 会把它杀掉，新代码不要再依赖它。

## 计费安全

- 测试时尽量用 CPU 实例（约 0.08 CCU/h），A100 约 8.2–8.7 CCU/h。手动执行 `colab new` 测试后**一定要 `colab stop`**，然后用 `colab sessions` 和 `colab usage` 确认 `Active assignments` 为 0。
- 要结束本地轮询脚本、但**保留** GPU 时，用 `kill -9`（不会触发 EXIT trap）。云端的渲染任务是 nohup 启动的，会继续跑完。
- 用 `run_h3_*.sh` 跑任务的机器，跑完会被关掉。不要在 Novum 正在使用的会话（默认 `h3i2v`）上运行它们。

## A100 实测（2026-11）

- A100-SXM4-40GB + `minimax_h3_fl2va_pruned_fp8_scaled`（unet）+ `qwen3vl_32b_heretic_minimax_h3_nvfp4`（文本编码器）能跑。
- 1344×768、243 帧、25 步原生：约 54 秒/步，一个镜头约 23.6 分钟。
- Novum 工作流（Turbo 8 步 768p LoRA + 17 帧去暗帧）：1376×768、3 秒（73 帧）约 190 秒，含冷加载。

## Novum Agent 集成

agent 本身在另一个目录（`~/Documents/Claude/novum-studio/novum-agent`，不属于本仓库），相关文件：`config.colab.json`、`workflows/*.colab.json`（只把 unet 和 clip 换成 Drive 上实际有的模型）、`启动Colab-A100视频Agent.command`、`停止Colab-A100视频Agent.command`、`释放Colab-A100.command`。Turbo 8 步 768p LoRA 在 HuggingFace 官方仓库里没有（官方 `8step` 与它大小相同但哈希不同），来源是本机 `~/Documents/DrawThings/loras/`，`novum_colab_server.sh up` 会上传它并备份到 Drive。

## 验证方式

- 语法检查：`for f in *.sh; do /bin/bash -n "$f"; done`（必须用 `/bin/bash`，也就是 3.2）。
- 逻辑测试：在 `PATH` 前面放一个假的 `colab` 脚本，模拟 503、后台租到、实例丢失等场景（以前就是这样测的），不会碰真实账号。
- 真实验证：开一台 CPU 实例，用 `colab dfs mount` 挂上 Drive 后用 `cexec` 检查文件，用完立即 `colab stop`。
