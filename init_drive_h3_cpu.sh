#!/usr/bin/env bash
set -euo pipefail

# 免费 0.00 CCU/h CPU 实例：将 scripts 与 01_dialogue_2p_photorealistic 同步到 Google Drive，
# 并执行 setup_minimax_h3_comfyui.py 拉取 ComfyUI、插件及 MiniMax-H3 核心权重到云盘。

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy_env.sh"
export COLAB_DFS_DEFAULT=1

SESSION="${SESSION:-h3init}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/colab-ultra-workstation"
METER="$SCRIPT_DIR/colab_meter.sh"

# colab-cli 0.8.0 的 exec 没有 -c，代码只能从 stdin 或 -f 文件传入。
cexec() { printf '%s\n' "$1" | colab exec -s "$SESSION"; }
# 带超时（秒）的版本，用于轮询，防止 WebSocket 卡死。
cexec_alarm() { printf '%s\n' "$2" | perl -e "alarm $1; exec @ARGV" colab exec -s "$SESSION"; }
# 失败时把云端完整日志下载到本地 logs/，并打印最后 40 行（实例关机后 /tmp 日志就没了）。
# DriveFS 是"先写本地缓存、文件关闭后后台上传"。关机前必须等上传跑完，否则刚写好的大文件会丢。
# 判定：至少等 FLUSH_MIN_WAIT 秒，且连续 3 次采样上行 < 1 MB/s；最多等 FLUSH_MAX_MIN 分钟。
wait_drive_flush() {
  local min_wait="${FLUSH_MIN_WAIT:-120}" max_min="${FLUSH_MAX_MIN:-120}"
  local t0=$SECONDS quiet=0 rate out
  echo "☁️  等待 DriveFS 把缓存上传到 Google Drive 云端（最少 ${min_wait}s，最多 ${max_min} 分钟，Ctrl+C 可跳过）..."
  while true; do
    out=$(cexec_alarm 20 '
import time
def tx():
    return sum(int(l.split(":")[1].split()[8]) for l in open("/proc/net/dev") if ":" in l and not l.strip().startswith("lo"))
a = tx(); time.sleep(8); b = tx()
print("UPLOAD_MBPS=%.1f" % ((b - a) / 8 / 1e6))
' 2>&1 || true)
    if echo "$out" | grep -q "appears to be lost\|Session '$SESSION' not found"; then
      echo "💥 实例已丢失，无法确认上传是否完成。"; return 1
    fi
    rate=$(echo "$out" | sed -n 's/^UPLOAD_MBPS=//p' | tail -1)
    echo "   $(date '+%H:%M:%S') 上行 ${rate:-?} MB/s"
    if [[ -n "$rate" ]] && awk "BEGIN{exit !($rate < 1)}"; then quiet=$((quiet + 1)); else quiet=0; fi
    if (( SECONDS - t0 >= min_wait && quiet >= 3 )); then
      echo "✅ 上行已持续空闲，DriveFS 上传应已完成。"; return 0
    fi
    if (( SECONDS - t0 >= max_min * 60 )); then
      echo "⚠️ 等待超过 ${max_min} 分钟仍有上传流量，放弃等待（未传完的文件下次 init 会按大小校验重新下载）。"; return 0
    fi
    sleep 10
  done
}
save_log() {
  mkdir -p "$SCRIPT_DIR/logs"
  local dst="$SCRIPT_DIR/logs/$(basename "$1" .log)_$(date +%Y%m%d_%H%M%S).log"
  if colab download -s "$SESSION" "$1" "$dst" >/dev/null 2>&1; then
    echo "📄 完整云端日志已保存: $dst"
    echo "----- 最后 40 行 -----"
    tail -40 "$dst"
  else
    echo "（下载云端日志 $1 失败）"
  fi
}

cleanup() {
  echo ""
  echo "🛑 正在释放免费 CPU 初始化实例 ($SESSION)..."
  colab stop -s "$SESSION" >/dev/null 2>&1 || true
  "$METER" stop -s "$SESSION" || true
}
trap cleanup EXIT
# Ctrl+C / kill 时强制退出主脚本（否则会被轮询里的 `|| true` 吞掉而继续循环），EXIT trap 负责关机。
trap 'echo "⛔ 收到中断信号，正在退出并关机..."; exit 130' INT TERM

echo "📦 [1/5] 打包本地 scripts 与 workflows (01_dialogue + 05_i2v_first_frame)..."
BUNDLE="/tmp/ai_workstation_sync.tar.gz"
tar -czf "$BUNDLE" -C "$REPO_DIR" scripts workflows/01_dialogue_2p_photorealistic workflows/05_i2v_first_frame

echo "🖥️  [2/5] 启动免费 CPU 实例 ($SESSION, 0.00 CCU/h) 并静默挂载 Google Drive..."
"$METER" start -s "$SESSION" -g CPU || true
colab new -s "$SESSION"
colab dfs mount -s "$SESSION"

echo "⬆️  [3/5] 上传脚本与短剧工作流至 Google Drive (/content/drive/MyDrive/AI_Workstation)..."
colab upload -s "$SESSION" "$BUNDLE" /tmp/ai_workstation_sync.tar.gz
cexec '
import os, subprocess
if os.path.isdir("/content/drive/My Drive") and not os.path.exists("/content/drive/MyDrive"):
    os.symlink("/content/drive/My Drive", "/content/drive/MyDrive")
os.makedirs("/content/drive/MyDrive/AI_Workstation", exist_ok=True)
subprocess.run(["tar", "-xzf", "/tmp/ai_workstation_sync.tar.gz", "-C", "/content/drive/MyDrive/AI_Workstation"], check=True)
print("✅ 脚本与工作流已同步至 /content/drive/MyDrive/AI_Workstation")
'

echo "⬇️  [4/5] 启动 0 CCU 后台任务拉取 ComfyUI + MiniMax-H3 模型权重 (已存在文件自动跳过)..."
cexec '
import subprocess
subprocess.Popen(
    "nohup python3 -u /content/drive/MyDrive/AI_Workstation/scripts/setup_minimax_h3_comfyui.py > /tmp/setup_h3.log 2>&1 < /dev/null &",
    shell=True,
)
print("🚀 已在后台启动 setup_minimax_h3_comfyui.py，日志: /tmp/setup_h3.log")
'

echo "👀 [5/5] 持续轮询云盘下载与落盘进度（采用防断连短轮询）..."
while true; do
  sleep 15
  OUT=$(cexec_alarm 20 '
import subprocess
ps = subprocess.run(["pgrep", "-f", "[s]etup_minimax_h3_comfyui.py"], capture_output=True, text=True)
running = bool(ps.stdout.strip())
try:
    lines = open("/tmp/setup_h3.log", errors="replace").read().splitlines()[-8:]
except FileNotFoundError:
    lines = []
print("RUNNING=" + ("1" if running else "0"))
for l in lines:
    print(l)
' 2>&1 || true)

  echo "---- $(date '+%H:%M:%S') ----"
  echo "$OUT"

  # 云端 VM 被回收/崩溃时 colab exec 会报 lost / not found，不再无限轮询
  if echo "$OUT" | grep -q "appears to be lost\|Session '$SESSION' not found"; then
    echo "💥 云端实例 $SESSION 已丢失（被 Colab 回收或崩溃）。重新运行 ./init_drive_h3_cpu.sh 即可断点续传（已下载的文件会自动跳过）"
    exit 1
  fi

  if echo "$OUT" | grep -q "RUNNING=0"; then
    if echo "$OUT" | grep -q "100% 落盘至"; then
      echo "✅ 免费 CPU 初始化与模型落盘全部完成！"
      wait_drive_flush || true
      break
    else
      echo "⚠️ setup_minimax_h3_comfyui.py 已退出，请检查上方日志。"
      save_log /tmp/setup_h3.log || true
      # 失败前已写入挂载点的文件同样要等它们传完，避免下次重下
      wait_drive_flush || true
      exit 1
    fi
  fi
done
