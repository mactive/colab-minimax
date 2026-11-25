#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxy_env.sh"

COLAB_PY="$HOME/.local/share/uv/tools/google-colab-cli/bin/python"
if [[ ! -x "$COLAB_PY" ]]; then
  echo "❌ 未找到 google-colab-cli Python 解释器: $COLAB_PY" >&2
  echo "请先运行: uv tool install --with socksio google-colab-cli" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METER_PY="$SCRIPT_DIR/colab-ultra-workstation/scripts/colab_meter.py"
if [[ ! -f "$METER_PY" ]]; then
  METER_PY="$HOME/.agents/skills/colab-ultra-workstation/scripts/colab_meter.py"
fi

exec "$COLAB_PY" "$METER_PY" "$@"
