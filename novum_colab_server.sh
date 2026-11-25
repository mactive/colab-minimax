#!/usr/bin/env bash
set -euo pipefail

# 把 Colab 上的 A100（或其他 GPU）当成 Novum Agent 的远程 ComfyUI 算力：
#   Mac 上的 novum-agent（video_backend=comfyui）→ SSH 隧道 127.0.0.1:18188 → Colab 上的 ComfyUI 127.0.0.1:8188
# 首帧上传、工作流提交、成片下载都由 Mac 上的 agent 通过隧道完成；本脚本只负责"机器 + ComfyUI + 隧道"。
# 本脚本从不自动关机：抢到的 GPU 会一直保留，直到你运行  ./novum_colab_server.sh release
#
# 用法：
#   ./novum_colab_server.sh up        复用/抢占 GPU 会话 → 挂 Drive → 确保 ComfyUI、去暗帧节点、8 步 LoRA → 开隧道
#   ./novum_colab_server.sh tunnel    只（重新）打开 SSH 隧道
#   ./novum_colab_server.sh watch     前台守护：每 30 秒检查隧道，断了自动重连（启动器会在后台跑它）
#   ./novum_colab_server.sh status    会话 / 隧道 / ComfyUI 队列 / 显存
#   ./novum_colab_server.sh down      关隧道和守护进程（不关 GPU，A100 继续计费）
#   ./novum_colab_server.sh release   关隧道 + 释放 GPU 会话（停止计费）
#
# 环境变量：SESSION=h3i2v  GPU=A100  LOCAL_PORT=18188  RETRY_INTERVAL=60  RETRY_MAX=0(无限)
#           NOVUM_AGENT=<novum-agent 目录>  LORA_LOCAL=<本机 8 步 768p LoRA 路径>

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export COLAB_DFS_DEFAULT=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/proxy_env.sh"

SESSION="${SESSION:-h3i2v}"
GPU="${GPU:-A100}"
LOCAL_PORT="${LOCAL_PORT:-18188}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"
RETRY_MAX="${RETRY_MAX:-0}"
NOVUM_AGENT="${NOVUM_AGENT:-$HOME/Documents/Claude/novum-studio/novum-agent}"
LORA_LOCAL="${LORA_LOCAL:-$HOME/Documents/DrawThings/loras/minimax_h3_fl2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors}"
LORA_NAME="$(basename "$LORA_LOCAL")"
NODE_DIR="$NOVUM_AGENT/comfy_nodes/frost_h3_deflicker"
RUNTIME="$SCRIPT_DIR/runtime"
mkdir -p "$RUNTIME"
WATCH_PID_FILE="$RUNTIME/novum_watch_${SESSION}.pid"
LOCAL_URL="http://127.0.0.1:${LOCAL_PORT}"

REMOTE_COMFY=/content/ComfyUI
DRIVE_COMFY=/content/drive/MyDrive/AI_Workstation/ComfyUI

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Colab 每台机器同时只允许一条 SSH 连接（第二条会 HTTP 429），所以隧道、rsync 都复用同一条 ControlMaster 主连接。
CTL="$RUNTIME/ssh-$SESSION.ctl"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o ExitOnForwardFailure=yes
          -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=yes
          -o "ProxyCommand=colab ssh --proxy-mode -s $SESSION")
SSH_HOST="root@colab-$SESSION"
# rsync -e 需要一整条带引号的命令行（ProxyCommand 里有空格）
RSYNC_E="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o 'ControlPath=$CTL' -o ControlPersist=yes -o 'ProxyCommand=colab ssh --proxy-mode -s $SESSION'"

cexec() { printf '%s\n' "$1" | colab exec -s "$SESSION" --timeout "${2:-120}"; }

session_hw() {
  colab sessions 2>/dev/null | grep -F "[$SESSION]" | sed -n 's/.*Hardware: \([^ |]*\).*/\1/p' | head -1 || true
}

local_ok() { curl -s --noproxy '*' --max-time 8 -o /dev/null -w '%{http_code}' "$LOCAL_URL/system_stats" 2>/dev/null | grep -q 200; }

master_ok() { ssh -o "ControlPath=$CTL" -O check "$SSH_HOST" >/dev/null 2>&1; }

master_start() {
  master_ok && return 0
  rm -f "$CTL"
  ssh -f -N "${SSH_OPTS[@]}" -o ControlMaster=yes "$SSH_HOST" </dev/null >>"$RUNTIME/novum_tunnel.log" 2>&1 || true
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do master_ok && return 0; sleep 2; done
  log "❌ SSH 主连接没建立，见 $RUNTIME/novum_tunnel.log（若是 HTTP 429：有别的 colab ssh 连着这台机器，先关掉它）"
  return 1
}

# ───────────────────────── 机器 ─────────────────────────
acquire() {
  local hw round=0
  hw="$(session_hw)"
  if [[ -n "$hw" ]]; then
    log "♻️  复用已有会话 $SESSION ($hw)，不新开机器。"
    return 0
  fi
  while true; do
    round=$((round + 1))
    log "🚀 第 ${round} 轮：尝试拉起 ${GPU} 会话 ($SESSION)..."
    if colab new -s "$SESSION" --gpu "$GPU"; then return 0; fi
    hw="$(session_hw)"
    if [[ -n "$hw" ]]; then log "♻️  colab new 报错，但会话已分配到 $hw，直接使用。"; return 0; fi
    if [[ "$RETRY_MAX" != "0" && "$round" -ge "$RETRY_MAX" ]]; then log "❌ ${round} 轮都没抢到 ${GPU}。"; return 1; fi
    log "⏳ 没抢到，${RETRY_INTERVAL}s 后重试（Ctrl+C 退出）..."
    sleep "$RETRY_INTERVAL"
  done
}

# ───────────────────────── 远端准备 ─────────────────────────
ensure_drive() {
  if cexec 'import os; print("DRIVE_OK" if os.path.isdir("/content/drive/MyDrive") else "DRIVE_NO")' | grep -q DRIVE_OK; then
    return 0
  fi
  log "☁️  挂载 Google Drive..."
  colab dfs mount -s "$SESSION"
}

ensure_comfy_installed() {
  if cexec "import os; print('COMFY_OK' if os.path.isfile('$REMOTE_COMFY/main.py') else 'COMFY_NO')" | grep -q COMFY_OK; then
    return 0
  fi
  log "⚡ 本机还没有 ComfyUI，运行 launch_g4_comfyui_fast.py (scheme_b) 冷启动（约几分钟）..."
  cexec "
import os, subprocess
if os.path.isdir('/content/drive/My Drive') and not os.path.exists('/content/drive/MyDrive'):
    os.symlink('/content/drive/My Drive', '/content/drive/MyDrive')
subprocess.run(['python3', '-u', '/content/drive/MyDrive/AI_Workstation/scripts/launch_g4_comfyui_fast.py', '--profile', 'scheme_b'], check=True)
" 0
}

ensure_node() {
  log "🧩 同步去暗帧节点 frost_h3_deflicker..."
  [[ -f "$NODE_DIR/__init__.py" ]] || { log "❌ 找不到 $NODE_DIR"; return 1; }
  rsync -a -e "$RSYNC_E" --rsync-path="mkdir -p $REMOTE_COMFY/custom_nodes/frost_h3_deflicker && rsync" \
    "$NODE_DIR/__init__.py" "$NODE_DIR/gains.py" "$SSH_HOST:$REMOTE_COMFY/custom_nodes/frost_h3_deflicker/" 2> >(grep -v RuntimeWarning >&2)
}

ensure_lora() {
  local state
  state="$(cexec "
import os, shutil
loc = '$REMOTE_COMFY/models/loras/$LORA_NAME'
drv = '$DRIVE_COMFY/models/loras/$LORA_NAME'
want = $(stat -f %z "$LORA_LOCAL" 2>/dev/null || echo 0)
size = lambda p: os.path.getsize(p) if os.path.exists(p) else -1
if size(loc) != want and size(drv) == want:
    shutil.copy2(drv, loc)
print('LORA', 'LOCAL_OK' if size(loc) == want else 'LOCAL_NO', 'DRIVE_OK' if size(drv) == want else 'DRIVE_NO')
")"
  if echo "$state" | grep -q LOCAL_NO; then
    [[ -f "$LORA_LOCAL" ]] || { log "❌ 远端没有 $LORA_NAME，本机也找不到 $LORA_LOCAL"; return 1; }
    log "⬆️  上传 8 步 768p LoRA 到 ${SESSION}（约 2GB，rsync 可断点续传）..."
    local i
    for i in 1 2 3 4 5 6; do
      if rsync -P --partial --inplace -e "$RSYNC_E" "$LORA_LOCAL" "$SSH_HOST:$REMOTE_COMFY/models/loras/" 2> >(grep -v RuntimeWarning >&2); then
        break
      fi
      log "   rsync 中断，第 $i 次重试..."; sleep 5
    done
  fi
  if ! echo "$state" | grep -q DRIVE_OK; then
    log "☁️  把 LoRA 备份到 Google Drive（后台复制，下次开新机器直接用）..."
    cexec "
import subprocess
subprocess.Popen('mkdir -p \"$DRIVE_COMFY/models/loras\" && cp \"$REMOTE_COMFY/models/loras/$LORA_NAME\" \"$DRIVE_COMFY/models/loras/\"', shell=True)
print('copy started')
" >/dev/null
  fi
  log "✅ LoRA 就绪: $LORA_NAME"
}

# 节点新装后需要重启 ComfyUI 才会加载；只在队列空闲时重启，避免打断正在渲染的镜头。
# 同时关掉 launch 脚本附带的 cloudflared 公网隧道（无鉴权，任何拿到链接的人都能用这台 GPU）。
ensure_comfy_running() {
  local out
  out="$(cexec '
import json, subprocess, urllib.request
def get(p):
    try: return json.load(urllib.request.urlopen("http://127.0.0.1:8188" + p, timeout=15))
    except Exception: return None
subprocess.run("pkill -f \"cloudflared tunnel\"", shell=True)
stats = get("/system_stats")
if stats is None:
    print("STATE=DOWN")
else:
    q = get("/queue") or {}
    busy = len(q.get("queue_running", [])) + len(q.get("queue_pending", []))
    node = "FrostH3PeriodicDeflicker" in (get("/object_info/FrostH3PeriodicDeflicker") or {})
    print("STATE=UP", "BUSY=%d" % busy, "NODE=%d" % node)
')"
  if echo "$out" | grep -q "NODE=1"; then log "✅ ComfyUI 运行中且已加载去暗帧节点。"; return 0; fi
  if echo "$out" | grep -q "STATE=UP" && ! echo "$out" | grep -q "BUSY=0"; then
    log "⏳ ComfyUI 正在渲染别的任务，等它空闲后再重启加载节点（每 30 秒检查一次）..."
    while cexec 'import json,urllib.request; q=json.load(urllib.request.urlopen("http://127.0.0.1:8188/queue",timeout=15)); print("BUSY=%d" % (len(q["queue_running"])+len(q["queue_pending"])))' | grep -q "BUSY=[1-9]"; do
      sleep 30
    done
  fi
  log "🔄 (重新)启动 ComfyUI 以加载去暗帧节点..."
  cexec "
import subprocess, time, urllib.request
subprocess.run(\"pkill -f 'python3 main.py'\", shell=True)
time.sleep(3)
try:
    vram = int(subprocess.run('nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits', shell=True, capture_output=True, text=True).stdout.split()[0])
except Exception:
    vram = 0
flags = ['--highvram', '--disable-mmap', '--fast'] if vram >= 75000 else ['--disable-mmap']
subprocess.Popen(['nohup', 'python3', 'main.py', '--listen', '127.0.0.1', '--port', '8188', *flags],
                 cwd='$REMOTE_COMFY', stdout=open('/tmp/comfyui.log', 'a'), stderr=subprocess.STDOUT, start_new_session=True)
for i in range(120):
    time.sleep(2)
    try:
        urllib.request.urlopen('http://127.0.0.1:8188/system_stats', timeout=5)
        print('COMFY_UP after %ds' % (2 * i + 2)); break
    except Exception:
        pass
else:
    print('COMFY_TIMEOUT'); print(open('/tmp/comfyui.log', errors='replace').read()[-2000:])
" 0
}

# ───────────────────────── 隧道 ─────────────────────────
tunnel_open() {
  if local_ok; then log "✅ 隧道已通: $LOCAL_URL"; return 0; fi
  log "🔌 打开 SSH 隧道 $LOCAL_URL → ${SESSION}:8188 ..."
  master_start || return 1
  ssh -o "ControlPath=$CTL" -O cancel -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:8188" "$SSH_HOST" >/dev/null 2>&1 || true
  ssh -o "ControlPath=$CTL" -O forward -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:8188" "$SSH_HOST" >>"$RUNTIME/novum_tunnel.log" 2>&1 || true
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do
    if local_ok; then log "✅ 隧道已通: $LOCAL_URL"; return 0; fi
    sleep 2
  done
  log "❌ 隧道没有打通（ComfyUI 没在跑？），见 $RUNTIME/novum_tunnel.log"; return 1
}

tunnel_close() {
  ssh -o "ControlPath=$CTL" -O exit "$SSH_HOST" >/dev/null 2>&1 || true
  rm -f "$CTL"
}

watch_loop() {
  echo $$ > "$WATCH_PID_FILE"
  trap 'rm -f "$WATCH_PID_FILE"' EXIT
  log "👀 隧道守护已启动（每 30 秒检查 $LOCAL_URL）"
  local fails=0
  while true; do
    sleep 30
    if local_ok; then fails=0; continue; fi
    fails=$((fails + 1))
    if [[ -z "$(session_hw)" ]]; then
      log "💥 会话 $SESSION 已不在（被 Colab 回收？）。重新运行启动器即可再抢一台。"
      continue
    fi
    log "⚠️  隧道不通（第 ${fails} 次），重连..."
    tunnel_open || true
  done
}

watch_stop() {
  if [[ -f "$WATCH_PID_FILE" ]]; then kill "$(cat "$WATCH_PID_FILE")" 2>/dev/null || true; rm -f "$WATCH_PID_FILE"; fi
}

status() {
  echo "== 会话"; colab sessions 2>&1 | grep -v RuntimeWarning || true
  colab usage 2>&1 | grep -v RuntimeWarning || true
  echo "== 隧道 $LOCAL_URL"
  if local_ok; then
    curl -s --noproxy '*' --max-time 10 "$LOCAL_URL/queue" | python3 -c '
import json, sys
q = json.load(sys.stdin); print("   ComfyUI 正常 | 正在跑 %d | 排队 %d" % (len(q["queue_running"]), len(q["queue_pending"])))'
  else
    echo "   不通"
  fi
  echo "== 守护进程"; [[ -f "$WATCH_PID_FILE" ]] && echo "   运行中 pid $(cat "$WATCH_PID_FILE")" || echo "   未运行"
}

case "${1:-up}" in
  up)
    acquire
    ensure_drive
    ensure_comfy_installed
    ensure_node
    ensure_lora
    ensure_comfy_running
    tunnel_open
    log "🎉 ${SESSION} 已就绪：Novum Agent 用 comfyui.url = $LOCAL_URL"
    log "   GPU 会话不会自动关闭；不用时运行  $0 release  释放并停止计费。"
    ;;
  tunnel)  tunnel_open ;;
  watch)   watch_loop ;;
  status)  status ;;
  down)    watch_stop; tunnel_close; log "隧道已关闭。GPU 会话 $SESSION 仍在运行（继续计费）。" ;;
  release) watch_stop; tunnel_close; colab stop -s "$SESSION" || true; colab sessions || true ;;
  *) echo "用法: $0 {up|tunnel|watch|status|down|release}"; exit 2 ;;
esac
