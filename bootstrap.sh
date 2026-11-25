#!/usr/bin/env bash
set -euo pipefail

# 初始化 / 维护本项目。
#
#   ./bootstrap.sh                 首次使用：检查依赖 → clone upstream colab-ultra-workstation 到固定 commit → 叠加 overlay
#   ./bootstrap.sh --save-overlay  在 colab-ultra-workstation 里改了脚本或 05 工作流后，把改动存回 workstation-overlay/（再提交到本仓库）
#
# colab-ultra-workstation/ 是 upstream 仓库的 clone，不提交进本仓库；本项目对它的修改都放在 workstation-overlay/：
#   workstation-overlay/UPSTREAM            upstream 地址 + 固定 commit
#   workstation-overlay/local.patch         对 upstream 已有文件的修改（git diff）
#   workstation-overlay/files/...           upstream 里没有、本项目新增的文件（如 workflows/05_i2v_first_frame）

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/proxy_env.sh"   # git clone / uv 下载也走代理（USE_PROXY=0 关闭）
WS="$ROOT/colab-ultra-workstation"
OV="$ROOT/workstation-overlay"
read -r UPSTREAM_URL UPSTREAM_COMMIT < "$OV/UPSTREAM"
# 新增文件（相对 upstream 根目录），--save-overlay 时从 clone 拷回 overlay
EXTRA_PATHS=("workflows/05_i2v_first_frame")

say() { echo "$*"; }

save_overlay() {
  [[ -d "$WS/.git" ]] || { say "❌ 没有 $WS"; exit 1; }
  git -C "$WS" diff "$UPSTREAM_COMMIT" -- . ':(exclude)workflows/05_i2v_first_frame' > "$OV/local.patch"
  rm -rf "$OV/files"; mkdir -p "$OV/files"
  local p
  for p in "${EXTRA_PATHS[@]}"; do
    mkdir -p "$OV/files/$(dirname "$p")"
    rsync -a --exclude '__pycache__' --exclude '.DS_Store' "$WS/$p/" "$OV/files/$p/"
  done
  say "✅ overlay 已更新：local.patch ($(grep -c '^diff --git' "$OV/local.patch") 个文件) + files/"
  say "   记得 git add workstation-overlay && git commit"
}

check_deps() {
  local miss=0
  for b in git rsync curl perl ssh; do command -v "$b" >/dev/null || { say "❌ 缺少 $b"; miss=1; }; done
  command -v ffmpeg >/dev/null || say "⚠️  没有 ffmpeg（brew install ffmpeg）——本地看片/合成时才需要"
  if ! command -v colab >/dev/null; then
    if command -v uv >/dev/null; then
      say "📦 安装 google-colab-cli ..."
      uv tool install --with socksio google-colab-cli
    else
      say "❌ 没有 colab-cli，也没有 uv。先 brew install uv，再重跑本脚本。"; miss=1
    fi
  fi
  if command -v colab >/dev/null && ! colab drive --help >/dev/null 2>&1; then
    say "⚠️  colab-cli 没有加载 colab-ext 扩展（colab drive / colab dfs 不可用）。"
    say "   脚本里的『免浏览器挂载 Google Drive』依赖它；装好后用 'colab ext doctor' 检查。"
  fi
  [[ -f "$HOME/.ssh/id_ed25519.pub" || -f "$HOME/.ssh/id_ecdsa.pub" ]] || \
    say "⚠️  没有 ~/.ssh/id_ed25519.pub —— novum_colab_server.sh 的 SSH 隧道需要：ssh-keygen -t ed25519"
  return $miss
}

setup_workstation() {
  if [[ ! -d "$WS/.git" ]]; then
    say "⬇️  clone $UPSTREAM_URL ..."
    git clone "$UPSTREAM_URL" "$WS"
  fi
  if [[ -n "$(git -C "$WS" status --porcelain)" ]]; then
    say "ℹ️  $WS 已有本地改动，跳过 checkout/打补丁（如需重来：删掉该目录后重跑）。"
  else
    git -C "$WS" fetch -q origin || true
    git -C "$WS" checkout -q "$UPSTREAM_COMMIT"
    if [[ -s "$OV/local.patch" ]]; then
      git -C "$WS" apply --whitespace=nowarn "$OV/local.patch"
      say "🩹 已应用 local.patch"
    fi
  fi
  rsync -a "$OV/files/" "$WS/"
  say "📁 已同步 overlay 新增文件（${EXTRA_PATHS[*]}）"
}

case "${1:-}" in
  --save-overlay) save_overlay; exit 0 ;;
  ""|--init) ;;
  *) echo "用法: $0 [--save-overlay]"; exit 2 ;;
esac

check_deps || { say "请先解决上面的 ❌ 再重跑。"; exit 1; }
setup_workstation
chmod +x "$ROOT"/*.sh
mkdir -p "$ROOT/runtime" "$ROOT/logs"

cat <<EOF

✅ 初始化完成。接下来：
  1) colab sessions                 # 第一次会弹浏览器做 Google OAuth
  2) ./init_drive_h3_cpu.sh         # 一次性：把 ComfyUI + 模型下载到 Google Drive（CPU 实例）
  3) GPU=A100 ./run_h3_i2v.sh       # 跑首帧图生视频
     或 ./novum_colab_server.sh up  # 把一台 GPU 当 Novum Agent 的远程 ComfyUI
默认走本机代理 127.0.0.1:7897，不需要时加 USE_PROXY=0。详见 README.md / AGENTS.md。
EOF
