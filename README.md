# colab-minimaxh3

用 **colab-cli** 在 Google Colab 上租 GPU（G4 / A100 / H100），一键跑 **MiniMax-H3**（ComfyUI）视频生成：
自动开机 → 挂载 Google Drive → 同步本地工作流 → 冷启动模型 → 后台渲染 + 轮询进度 → **自动关机并输出 CCU 对账单**。

> 模型权重、ComfyUI、成片都放在 Google Drive 的 `MyDrive/AI_Workstation/`，本地只放脚本和工作流配置。

---

## 目录结构

```
colab-minimaxh3/
├── README.md                  # 本文件
├── proxy_env.sh               # 公共代理配置（所有脚本自动加载）
├── run_h3_i2v.sh              # ★ 首帧图生视频（05_i2v_first_frame）
├── run_h3_drama.sh            # ★ 4 段式双人对话短剧（01_dialogue_2p_photorealistic）
├── init_drive_h3_cpu.sh       # 首次初始化：免费 CPU 实例把 ComfyUI + 模型权重下载到 Drive
├── colab_meter.sh             # CCU 计费工具（开机快照 / 停机对账 / 强制释放所有会话）
└── colab-ultra-workstation/   # 工作流与云端脚本仓库
    ├── scripts/               # launch_g4_comfyui_fast.py、setup_minimax_h3_comfyui.py、colab_meter.py…
    └── workflows/
        ├── 01_dialogue_2p_photorealistic/   # 短剧：drama_config.json + run_drama.py
        └── 05_i2v_first_frame/              # I2V：i2v_config.json + inputs/001.png… + run_i2v.py
```

---

## 一、首次准备

### 1. 安装 colab-cli 并登录

```bash
uv tool install --with socksio google-colab-cli
```

```bash
colab sessions
```

第一次执行会弹浏览器做 Google OAuth 授权。`colab version` 可查看版本，`colab update` 检查更新。

### 2. 代理（默认开启）

所有脚本开头都会 `source proxy_env.sh`，自动设置：

```bash
export https_proxy=http://127.0.0.1:7897 http_proxy=http://127.0.0.1:7897 all_proxy=socks5://127.0.0.1:7897
```

| 需求 | 写法 |
|---|---|
| 默认（走 127.0.0.1:7897） | `./run_h3_i2v.sh` |
| 换端口 / 地址 | `PROXY_PORT=7890 ./run_h3_i2v.sh`、`PROXY_HOST=192.168.1.5 ./run_h3_i2v.sh` |
| 临时直连不走代理 | `USE_PROXY=0 ./run_h3_i2v.sh` |
| 手动敲 `colab ...` 命令前，让当前终端也走代理 | `source ./proxy_env.sh` |

代理端口连不上时脚本会打印 ⚠️ 提示，但不会中断。

### 3. 首次初始化 Drive（只需做一次，免费）

用 0 CCU/h 的 CPU 实例把 ComfyUI、插件、MiniMax-H3 权重下载到 Google Drive（已存在的文件会跳过）：

```bash
./init_drive_h3_cpu.sh
```

本地改了 `colab-ultra-workstation/scripts` 下的脚本，也可以重跑它来同步到 Drive。

---

## 二、日常运行

### 首帧图生视频（I2V）

1. 把首帧图放进 `colab-ultra-workstation/workflows/05_i2v_first_frame/inputs/`（如 `001.png`）
2. 编辑同目录的 `i2v_config.json`：每个 shot 的 `first_frame`、`prompt_en/zh`、`length`、`seed`、`output_name`
3. 运行：

```bash
./run_h3_i2v.sh
```

常用变体：

```bash
GPU=A100 ./run_h3_i2v.sh
```

```bash
GPU=G4 ./run_h3_i2v.sh --shots 1
```

```bash
./run_h3_i2v.sh --shots 1,2 --steps 30 --lang zh
```

```bash
GPU=A100 HIGH_MEM=1 ./run_h3_i2v.sh --no-stitch
```

抢机：默认**无限重试**，每 60 秒一轮，直到抢到为止（Ctrl+C 退出，会自动清理）。可以限制轮数或调整间隔：

```bash
GPU=A100 RETRY_INTERVAL=30 ./run_h3_i2v.sh
```

```bash
RETRY_MAX=30 RETRY_INTERVAL=120 ./run_h3_i2v.sh
```

`run_i2v.py` 参数（直接追加在脚本后面）：

| 参数 | 说明 |
|---|---|
| `--shots 1,2` | 只渲染指定镜头 |
| `--steps 30` | 覆盖采样步数（默认读 config，25） |
| `--lang en\|zh` | 覆盖提示词语言 |
| `--no-stitch` | 不拼接预览合集 MP4 |

成片位置：`MyDrive/AI_Workstation/ComfyUI/output/<output_subdir>/`（`output_subdir` 在 `i2v_config.json` 里设置）。

### 4 段式短剧（Drama）

配置文件：`colab-ultra-workstation/workflows/01_dialogue_2p_photorealistic/drama_config.json`

```bash
./run_h3_drama.sh
```

```bash
GPU=A100 ./run_h3_drama.sh --only-seg 3
```

```bash
./run_h3_drama.sh --start-seg 2 --end-seg 4 --speakers 1,2,1,2
```

`run_drama.py` 常用参数：`--only-seg N`（只重跑第 N 段，约 3 分钟）、`--start-seg / --end-seg`、`--speakers`、`--style-mode photorealistic|stylized|anime|none`、`--role1-img / --role2-img`、`--role1-voice / --role2-voice`、`--tail-lock-seg / --tail-lock-img`、`--prefix`、`--out-mp4`。

### 环境变量速查（两个 run 脚本通用）

| 变量 | 默认 | 说明 |
|---|---|---|
| `GPU` | `auto` | `auto` = 先 G4、失败再 A100；也可写 `G4` / `A100` / `H100` |
| `RETRY_MAX` | `0` | 抢机最多重试几轮，`0` = 无限重试，直到抢到或按 Ctrl+C |
| `RETRY_INTERVAL` | `60` | 每轮失败后等待的秒数 |
| `HIGH_MEM` | `0` | `1` = `colab new` 加 `--high-mem` |
| `SESSION` | `h3i2v` / `h3work` | 会话名，同时跑两个任务时要用不同名字 |
| `PROFILE` | `scheme_b`（i2v） / `scheme_a`（drama） | 模型组合，`launch_g4_comfyui_fast.py --profile` |
| `USE_PROXY` / `PROXY_HOST` / `PROXY_PORT` | `1` / `127.0.0.1` / `7897` | 见上文代理一节 |

### 机型与价格（脚本内标注，以 `colab usage` 实际为准）

| 机型 | 显存 | 约 CCU/h | 备注 |
|---|---|---|---|
| G4 | 96 GB | — | 默认首选，脚本按它调优 |
| A100 | 40/80 GB | ~8.2–8.7 | 显存比 G4 小，大 profile 注意 OOM |
| H100 | 80 GB | ~18.05 | 最贵 |
| CPU | — | 0（免费档） / ~0.08 | 只用于初始化下载 |

### 给 Novum Agent 当远程算力（长期保留 GPU）

`novum_colab_server.sh` 会把一台 Colab GPU 变成 Novum Agent 的远程 ComfyUI，通过 SSH 隧道接到本机 `127.0.0.1:18188`。它**不会自动关机**，抢到一台 A100 后可以一直用。平时用 novum-agent 目录里的 `启动Colab-A100视频Agent.command` 启动就行，下面这些命令是手动操作时用的：

```bash
./novum_colab_server.sh up        # 复用/抢占 h3i2v → Drive → ComfyUI → 去暗帧节点 → 8 步 768p LoRA → 隧道
```

```bash
./novum_colab_server.sh status    # 会话 / 隧道 / ComfyUI 队列
```

```bash
./novum_colab_server.sh down      # 只关隧道，GPU 继续运行（继续计费）
```

```bash
./novum_colab_server.sh release   # 关隧道并释放 GPU（停止计费）
```

> 注意：`run_h3_i2v.sh` / `run_h3_drama.sh` 跑完后会**自动关机**。如果这台机器还要留给 Novum 用，就别用它们跑，或者跑完后再重新抢一台。

---

## 三、脚本执行流程

```
Step 0  打包本地工作流 → /tmp/*.tar.gz
Step 1  colab new 抢 GPU（auto 模式 G4 → A100 依次尝试；都失败就等 RETRY_INTERVAL 秒后再来一轮）
        每次尝试前后都会检查 colab sessions：如果 colab new 虽然报错，但后台已经把同名会话租到了，就直接用这台
        colab_meter.sh start 记录开机 CCU 快照；colab dfs mount 挂载 Drive
Step 2  上传并解压到 MyDrive/AI_Workstation（i2v）
Step 3  云端 nohup 后台：launch_g4_comfyui_fast.py 冷启动 → run_i2v.py / run_drama.py
        本地每 15 秒轮询云端日志（/tmp/h3_*_run.log），看到 EXIT_CODE 就结束
Step 4  trap EXIT：无论成功、失败还是 Ctrl+C，都会 colab stop + 输出 CCU 对账单
```

> 脚本运行中按 **Ctrl+C** 是安全的：会自动关机。但如果直接关掉终端窗口或 `kill -9`，trap 不会执行，**一定要手动 `colab stop`**。

---

## 四、colab-cli 常用命令

```bash
colab sessions                         # 列出所有在线会话（[?] 表示 untracked，不在本地记录里）
```

```bash
colab usage                            # 余额、当前消耗速率、活跃分配数
```

```bash
colab status -s h3i2v                  # 某会话状态
```

```bash
colab stop -s h3i2v                    # 关掉某会话
```

```bash
./colab_meter.sh stop --all            # 强制释放所有会话（含网页上开的 / untracked）
```

```bash
./colab_meter.sh report                # 一行汇总：活跃数 / 速率 / 余额
```

```bash
colab new -s test --gpu G4             # 手动开机（--gpu G4|A100|H100，可加 --high-mem）
```

```bash
echo 'print(1)' | colab exec -s h3i2v  # 在会话里执行 Python（0.8.0 没有 -c，代码走 stdin 或 -f 文件）
```

```bash
colab exec -s h3i2v -f ./debug.py      # 执行本地的 .py / .ipynb 文件
```

```bash
echo 'print(open("/tmp/h3_i2v_run.log").read()[-3000:])' | colab exec -s h3i2v   # 看云端渲染日志
```

```bash
echo '!nvidia-smi' | colab exec -s h3i2v   # 用 IPython 的 ! 执行 shell 命令
```

```bash
colab dfs mount -s h3i2v               # 挂载 Google Drive
```

```bash
colab upload -s h3i2v ./local.png /content/local.png
```

```bash
colab download -s h3i2v /content/drive/MyDrive/AI_Workstation/ComfyUI/output/xxx/001.mp4 ./001.mp4
```

```bash
colab ls -s h3i2v /content/drive/MyDrive/AI_Workstation/ComfyUI/output
```

```bash
colab ssh -s h3i2v                     # SSH 进实例
```

```bash
colab url -s h3i2v                     # 生成浏览器连接该会话的链接
```

```bash
colab --logtostderr new -s test --gpu A100   # 调试：打印 Google 返回的原始 HTTP 响应
```

`colab <命令> --help` 查看各命令的完整参数。

---

## 五、故障排查

### 1. `EXTRA_NEW_FLAGS[@]: unbound variable`

macOS 自带的 bash 3.2 在 `set -u` 下展开空数组会报这个错，导致 `colab new` 根本没执行。已修复（改成 `${arr[@]+"${arr[@]}"}`）。以后在脚本里新增数组展开时也要用这种写法。

### 1b. `colab exec` 报 `No such option: -c`

colab-cli 0.8.0 的 `exec` 只从 **stdin** 或 `-f 文件` 读代码，没有 `-c`（也不支持 `--`）。脚本里已经统一改成两个辅助函数：
`cexec '<python 代码>'`（通过 stdin 传给 `colab exec`），以及 `cexec_alarm 20 '<代码>'`（带 20 秒超时，用于轮询）。新增远程调用时也用这两个函数。

### 2. 租不到 GPU：看 `--logtostderr` 的 HTTP 状态码

```bash
colab --logtostderr new -s test --gpu G4
```

| 现象 | 含义 | 处理 |
|---|---|---|
| `GET /tun/m/assign` 返回 200，`"acc":"a100"` | 账号有权限租这个机型 | 正常 |
| `POST` 卡约 30 秒后返回 **503** | 当前**没有空闲机器** | cli 会每 10 秒自动重试。**注意：重试可能在后台成功**，过一会儿用 `colab sessions` 检查 |
| `POST` 立刻返回 **412 Precondition Failed** | 已有活跃会话占着名额，或临时用量 / 容量限制 | `colab sessions` 查看，`colab stop -s <名字>` 或 `./colab_meter.sh stop --all` 清掉再试 |

> 网页下拉菜单里能选 G4，只代表账号有这个机型的权限，不代表此刻有库存。
> 高峰期换个时间（北京时间深夜和清晨）更容易抢到。

### 3. 测试会话忘了关

用 `colab new -s test ...` 手动测试后，**一定记得 `colab stop -s test`**，A100 空转每小时扣 8 CCU 以上。
排查时先跑一下 `colab sessions` 和 `colab usage`，确认 `Active assignments` 是 0。

### 4. 网页上开的会话（untracked）怎么关

- 命令行：`./colab_meter.sh stop --all`
- 网页：打开任意笔记本 → **运行时 → 管理会话 → 终止**

### 4b. Ctrl+C 停不下来 / 需要手动结束

脚本已加 `trap ... INT TERM`，Ctrl+C 会在当前这次轮询结束后（最多约 20 秒）退出并关机。万一还是停不下来：

```bash
pkill -TERM -f "bash ./run_h3_i2v.sh"
```

```bash
colab stop -s h3i2v
```

```bash
colab sessions
```

最后一条用来确认机器真的关掉了：GPU 会话消失，`colab usage` 的速率降下来。

### 4c. 模型"写入挂载点"了，下次 init 却又重新下载

DriveFS 的工作方式是：文件先写进实例本地的缓存，**文件关闭后才在后台上传到云端**。如果实例在上传完成前被关掉，云端就没有这个文件。现在的处理：
- `init_drive_h3_cpu.sh` 在关机前会执行 `wait_drive_flush`：每隔一段时间采样实例的网络上行，至少等 `FLUSH_MIN_WAIT`（默认 120）秒，且连续 3 次上行 < 1 MB/s 才关机，最多等 `FLUSH_MAX_MIN`（默认 120）分钟。等待时按 Ctrl+C 可以跳过。
- `setup_minimax_h3_comfyui.py` 判断一个文件是否下载完成时，会把它和 HuggingFace 上的真实字节数对比，必须**完全一致**才跳过。不完整的文件会先删掉再重新下载。下载后和写入 Drive 后也各校验一次大小。

### 5. 代理相关

- 提示 `⚠️ 代理 127.0.0.1:7897 连不上`：检查代理软件是否开启，以及端口是不是 7897
- 怀疑是代理导致的问题：`USE_PROXY=0 ./run_h3_i2v.sh` 直连对比一下

### 6. 云端任务失败

脚本会打印云端日志的最后 10 行，然后自动关机。完整日志在实例的 `/tmp/h3_i2v_run.log`（短剧是 `/tmp/h3_drama_run.log`），关机后就没了。想保留现场排查时，在关机前另开一个终端执行：

```bash
colab download -s h3i2v /tmp/h3_i2v_run.log ./h3_i2v_run.log
```

### 7. 修改脚本时的注意事项

bash 是边执行边读脚本的。**脚本正在运行时不要直接原地编辑**，否则正在跑的任务可能执行到错乱的内容。等它跑完再改，或者先写到新文件再 `mv` 覆盖。
