#!/usr/bin/env bash
set -euo pipefail

# 一键全自动：拉起 96GB G4 -> 静默挂载 Google Drive -> 极速冷启动 MiniMax-H3 ->
# 跑完 4 段式影视短剧 -> 强制销毁实例并双轨对账 CCU（异常中断亦自动触发防幽灵计费停机）。
#
# 用法示例：
#   ./run_h3_drama.sh                 # 默认优先抢 G4，缺货时自动降级到 A100 (8.71 CCU/h)
#   RETRY_MAX=30 RETRY_INTERVAL=120 ./run_h3_drama.sh   # 最多抢 30 轮，每轮间隔 120s（默认无限轮 / 60s）
#   GPU=A100 ./run_h3_drama.sh        # 指定直接开 A100
#   GPU=H100 ./run_h3_drama.sh        # 指定开 H100 (80GB, 18.05 CCU/h)
#   ./run_h3_drama.sh --only-seg 3

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy_env.sh"
export COLAB_DFS_DEFAULT=1

SESSION="${SESSION:-h3work}"
PROFILE="${PROFILE:-scheme_a}"
GPU="${GPU:-auto}"
EXTRA_ARGS="$*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METER="$SCRIPT_DIR/colab_meter.sh"

# colab-cli 0.8.0 的 exec 没有 -c，代码只能从 stdin 或 -f 文件传入。
cexec() { printf '%s\n' "$1" | colab exec -s "$SESSION"; }
# 带超时（秒）的版本，用于轮询，防止 WebSocket 卡死。
cexec_alarm() { printf '%s\n' "$2" | perl -e "alarm $1; exec @ARGV" colab exec -s "$SESSION"; }
# 失败时把云端完整日志下载到本地 logs/，并打印最后 40 行（实例关机后 /tmp 日志就没了）。
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
  echo "🛑 [Step 3] 正在强杀 GPU 实例 ($SESSION) 并输出 CCU 双轨对账单（防后台幽灵计费）..."
  colab stop -s "$SESSION" >/dev/null 2>&1 || true
  "$METER" stop -s "$SESSION" || true
}
trap cleanup EXIT
# Ctrl+C / kill 时强制退出主脚本（否则会被轮询里的 `|| true` 吞掉而继续循环），EXIT trap 负责关机。
trap 'echo "⛔ 收到中断信号，正在退出并关机..."; exit 130' INT TERM

if [[ "$GPU" == "auto" ]]; then
  GPU_LIST=("G4" "A100")
else
  GPU_LIST=("$GPU")
fi

# 抢机重试：RETRY_MAX 轮（0 = 无限），每轮把 GPU_LIST 依次试一遍，失败后等 RETRY_INTERVAL 秒。
RETRY_MAX="${RETRY_MAX:-0}"
RETRY_INTERVAL="${RETRY_INTERVAL:-60}"

EXTRA_NEW_FLAGS=()
if [[ "${HIGH_MEM:-0}" == "1" ]]; then
  EXTRA_NEW_FLAGS+=("--high-mem")
fi

# 返回同名会话的硬件型号（如 A100）；没有则返回空。
# 用于兜底：colab new 报错后，其内部重试可能在后台已经把机器租到了（之前 503 后出现过）。
session_hw() {
  colab sessions 2>/dev/null | grep -F "[$SESSION]" | sed -n 's/.*Hardware: \([^ |]*\).*/\1/p' | head -1 || true
}

ACTUAL_GPU=""
round=0
while [[ -z "$ACTUAL_GPU" ]]; do
  round=$((round + 1))
  for g in "${GPU_LIST[@]}"; do
    hw="$(session_hw)"
    if [[ -n "$hw" && "$hw" != "CPU" ]]; then
      echo "♻️  发现已存在的会话 $SESSION (${hw})，直接复用。"
      ACTUAL_GPU="$hw"
      break
    fi
    echo "🚀 [Step 1] 第 ${round} 轮：尝试拉起 ${g} 实例 ($SESSION)... $(date '+%H:%M:%S')"
    if colab new -s "$SESSION" --gpu "$g" ${EXTRA_NEW_FLAGS[@]+"${EXTRA_NEW_FLAGS[@]}"}; then
      ACTUAL_GPU="$g"
      break
    fi
    hw="$(session_hw)"
    if [[ -n "$hw" && "$hw" != "CPU" ]]; then
      echo "♻️  colab new 报错，但会话 $SESSION 实际已分配到 ${hw}，直接使用。"
      ACTUAL_GPU="$hw"
      break
    fi
    echo "⚠️ ${g} 当前分配失败（可能是该机型暂时无库存或账号/区域限流）。"
  done
  [[ -n "$ACTUAL_GPU" ]] && break
  if [[ "$RETRY_MAX" != "0" && "$round" -ge "$RETRY_MAX" ]]; then
    break
  fi
  echo "⏳ 第 ${round} 轮未抢到 (${GPU_LIST[*]})，${RETRY_INTERVAL}s 后重试（Ctrl+C 退出）..."
  sleep "$RETRY_INTERVAL"
done

if [[ -z "$ACTUAL_GPU" ]]; then
  echo "❌ 所有候选 GPU (${GPU_LIST[*]}) 在 ${round} 轮内均分配失败。"
  echo "💡 排查建议："
  echo "   1) 运行 'colab --logtostderr new -s test --gpu A100' 查看 Google 返回的具体报错原因"
  echo "   2) 运行 'colab sessions' 检查是否已有旧实例占坑（可用 colab stop 清理）"
  echo "   3) 稍后重试，或按需指定机型：GPU=A100 ./run_h3_drama.sh 或 GPU=G4 ./run_h3_drama.sh"
  exit 1
fi

echo "⏱️  已成功分配 ${ACTUAL_GPU}，记录开机 CCU 快照并静默挂载 Google Drive..."
"$METER" start -s "$SESSION" -g "$ACTUAL_GPU"
colab dfs mount -s "$SESSION"

echo "⚡ [Step 2] 90秒极速冷启动 MiniMax-H3 并运行 4 段式影视短剧（nohup 防断连模式）..."
REMOTE_CMD="python3 -u /content/drive/MyDrive/AI_Workstation/scripts/launch_g4_comfyui_fast.py --profile ${PROFILE} && cd /content/drive/MyDrive/AI_Workstation/workflows/01_dialogue_2p_photorealistic && python3 -u run_drama.py --config drama_config.json --workflow workflow_v9_final.json ${EXTRA_ARGS}"

cexec "
import os, subprocess
if os.path.isdir('/content/drive/My Drive') and not os.path.exists('/content/drive/MyDrive'):
    os.symlink('/content/drive/My Drive', '/content/drive/MyDrive')
cmd = '''(${REMOTE_CMD}); echo EXIT_CODE=\$? >> /tmp/h3_drama_run.log'''
with open('/tmp/h3_drama_run.sh', 'w') as f:
    f.write('#!/usr/bin/env bash\nset -o pipefail\n' + cmd + '\n')
os.chmod('/tmp/h3_drama_run.sh', 0o755)
subprocess.Popen('nohup /tmp/h3_drama_run.sh > /tmp/h3_drama_run.log 2>&1 < /dev/null &', shell=True)
print('🚀 云端任务已脱机启动，日志: /tmp/h3_drama_run.log')
"

echo "👀 持续轮询云端执行进度（每 15 秒刷新，自动防 WebSocket 断连）..."
while true; do
  sleep 15
  OUT=$(cexec_alarm 20 '
import subprocess
ps = subprocess.run(["pgrep", "-f", "[h]3_drama_run.sh"], capture_output=True, text=True)
running = bool(ps.stdout.strip())
try:
    lines = open("/tmp/h3_drama_run.log", errors="replace").read().splitlines()[-10:]
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
    echo "💥 云端实例 $SESSION 已丢失（被 Colab 回收或崩溃）。重新运行 ./run_h3_drama.sh"
    exit 1
  fi

  # 日志里出现 EXIT_CODE= 即视为任务结束（双保险，不只依赖 pgrep）
  if echo "$OUT" | grep -q "RUNNING=0\|EXIT_CODE="; then
    if echo "$OUT" | grep -q "EXIT_CODE=0"; then
      echo "🎉 短剧生成全部完成！结果已落盘至 Google Drive。"
      break
    else
      echo "❌ 云端任务异常退出，请查看上方日志。正在自动停机以防继续扣费..."
      save_log /tmp/h3_drama_run.log || true
      exit 1
    fi
  fi
done
