# shellcheck shell=bash
# 公共代理配置：被 run_h3_*.sh / init_drive_h3_cpu.sh / colab_meter.sh 通过 source 引入。
# 也可以在当前终端手动加载：  source ./proxy_env.sh
#
#   默认走本机代理 http://127.0.0.1:7897（Clash Verge 等默认端口）
#   换端口/地址：  PROXY_HOST=127.0.0.1 PROXY_PORT=7890 ./run_h3_i2v.sh
#   临时不走代理： USE_PROXY=0 ./run_h3_i2v.sh

if [[ "${USE_PROXY:-1}" != "0" ]]; then
  _proxy_host="${PROXY_HOST:-127.0.0.1}"
  _proxy_port="${PROXY_PORT:-7897}"
  export https_proxy="http://${_proxy_host}:${_proxy_port}"
  export http_proxy="http://${_proxy_host}:${_proxy_port}"
  export all_proxy="socks5://${_proxy_host}:${_proxy_port}"
  export HTTPS_PROXY="$https_proxy" HTTP_PROXY="$http_proxy" ALL_PROXY="$all_proxy"
  export no_proxy="localhost,127.0.0.1,::1"
  export NO_PROXY="$no_proxy"

  if ! nc -z -G 2 "$_proxy_host" "$_proxy_port" >/dev/null 2>&1; then
    echo "⚠️  代理 ${_proxy_host}:${_proxy_port} 连不上（代理软件没开？）。如需直连请用 USE_PROXY=0 重新运行。" >&2
  fi
  unset _proxy_host _proxy_port
fi
