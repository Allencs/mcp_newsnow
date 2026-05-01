#!/usr/bin/env bash
# 一键通过 uv 部署 mcp-newsnow MCP 服务
#
# 用法:
#   ./deploy.sh                       # 默认: 本地源码模式 (uv sync), 适合开发/本仓库修改场景
#   ./deploy.sh --mode pypi           # 从 PyPI 安装 mcp-newsnow 为全局工具 (uv tool install)
#   ./deploy.sh --mode uvx            # 不安装, 仅生成调用 'uvx mcp-newsnow' 的 Claude 配置
#   ./deploy.sh --claude              # 同时把服务写入 Claude Desktop 配置 (自动备份)
#   ./deploy.sh --claude --yes        # 跳过所有交互确认
#   ./deploy.sh --skip-test           # 不执行连通性自检
#   ./deploy.sh -h | --help           # 查看帮助
#
# 退出码: 0 成功, 非 0 失败 (并打印失败原因)

set -euo pipefail

# ---------- 颜色与日志 ----------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info()    { printf "%s[INFO]%s %s\n"  "$BLUE"   "$RESET" "$*"; }
ok()      { printf "%s[ OK ]%s %s\n"  "$GREEN"  "$RESET" "$*"; }
warn()    { printf "%s[WARN]%s %s\n"  "$YELLOW" "$RESET" "$*"; }
err()     { printf "%s[FAIL]%s %s\n"  "$RED"    "$RESET" "$*" >&2; }
section() { printf "\n%s== %s ==%s\n" "$BOLD"   "$*"     "$RESET"; }

# ---------- 默认参数 ----------
MODE="local"           # local | pypi | uvx
WRITE_CLAUDE=0
ASSUME_YES=0
RUN_TEST=1

# ---------- 解析参数 ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)       MODE="${2:-}"; shift 2 ;;
    --mode=*)     MODE="${1#*=}"; shift ;;
    --claude)     WRITE_CLAUDE=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --skip-test)  RUN_TEST=0; shift ;;
    -h|--help)
      sed -n '2,13p' "$0"; exit 0 ;;
    *)
      err "未知参数: $1"; exit 2 ;;
  esac
done

case "$MODE" in
  local|pypi|uvx) ;;
  *) err "--mode 必须是 local / pypi / uvx, 当前: $MODE"; exit 2 ;;
esac

confirm() {
  # confirm "提示" -> 0 表示同意, 1 表示拒绝
  [[ "$ASSUME_YES" == 1 ]] && return 0
  local ans
  read -r -p "$1 [y/N] " ans || true
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ---------- 0. 环境信息 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

section "环境信息"
info "工作目录: $SCRIPT_DIR"
info "部署模式: $MODE"
info "操作系统: $(uname -s) $(uname -m)"

# ---------- 1. 安装/检测 uv ----------
section "步骤 1/4: 检测 uv"
if ! command -v uv >/dev/null 2>&1; then
  warn "未检测到 uv"
  if confirm "是否自动安装 uv? (使用 astral.sh 官方安装脚本)"; then
    info "安装 uv ..."
    # uv 安装器在某些环境下 (例如 fish 补全目录无写权限) 会以非 0 退出,
    # 但 uv 二进制其实已经装好。所以这里关掉 errexit, 后面以 'uv 是否可用' 为最终判据。
    set +e
    curl -LsSf https://astral.sh/uv/install.sh | sh
    install_rc=$?
    set -e
    # 把官方安装目录加入本会话 PATH
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
    if ! command -v uv >/dev/null 2>&1; then
      err "uv 安装失败 (rc=$install_rc), 请手动安装: https://docs.astral.sh/uv/getting-started/installation/"
      exit 1
    fi
    if [[ "$install_rc" -ne 0 ]]; then
      warn "uv 安装器报告了非致命错误 (rc=$install_rc, 通常是 shell 补全写入失败), 但二进制可用, 继续"
    fi
  else
    err "需要 uv 才能继续, 请先安装: https://docs.astral.sh/uv/getting-started/installation/"
    exit 1
  fi
fi
ok "uv 已就绪: $(uv --version)"

# ---------- 2. 部署 ----------
section "步骤 2/4: 部署 ($MODE)"
RUN_CMD=""    # 真正用来启动 MCP 服务的命令字符串 (用于自检 & Claude 配置)

case "$MODE" in
  local)
    info "使用 'uv sync' 基于 pyproject.toml + uv.lock 在 .venv 中安装本地源码 ..."
    if [[ ! -f pyproject.toml ]]; then
      err "当前目录缺少 pyproject.toml, 不像是项目根目录"; exit 1
    fi
    uv sync
    VENV_PY="$SCRIPT_DIR/.venv/bin/python"
    if [[ ! -x "$VENV_PY" ]]; then
      # Windows 路径兜底 (在 git-bash / msys 下也尽量能跑)
      VENV_PY="$SCRIPT_DIR/.venv/Scripts/python.exe"
    fi
    if [[ ! -x "$VENV_PY" ]]; then
      err "未找到虚拟环境内的 python, uv sync 似乎失败了"; exit 1
    fi
    RUN_CMD="$VENV_PY -m mcp_newsnow_server"
    ok "本地源码已安装 (含本仓库的所有修改)"
    ;;

  pypi)
    info "使用 'uv tool install' 把 mcp-newsnow 装为全局可用工具 ..."
    uv tool install --force mcp-newsnow
    if ! command -v mcp-newsnow >/dev/null 2>&1; then
      # uv tool 的 bin 目录通常是 ~/.local/bin
      export PATH="$HOME/.local/bin:$PATH"
    fi
    if ! command -v mcp-newsnow >/dev/null 2>&1; then
      err "mcp-newsnow 命令仍不可用, 请确认 uv tool 的 bin 目录在 PATH 中 (uv tool dir --bin)"
      exit 1
    fi
    RUN_CMD="$(command -v mcp-newsnow)"
    ok "PyPI 版本已安装: $RUN_CMD"
    warn "注意: 当前 PyPI 版本可能还没合并 Cloudflare/User-Agent 修复, 若调用 API 出现 403 请改用 --mode local"
    ;;

  uvx)
    info "uvx 模式: 不预装, 每次由 uvx 临时拉起 (首次会下载 mcp-newsnow)"
    RUN_CMD="uvx mcp-newsnow"
    ok "已选择 uvx 直跑模式"
    ;;
esac

# ---------- 3. 自检 ----------
section "步骤 3/4: 连通性自检"
if [[ "$RUN_TEST" != 1 ]]; then
  warn "已通过 --skip-test 跳过自检"
elif [[ "$MODE" != "local" ]]; then
  warn "非 local 模式, 跳过端到端自检 (该自检需要导入仓库源码 fixture)"
else
  info "调用 fetch_news('知乎') 进行真实接口请求 ..."
  set +e
  "$VENV_PY" - <<'PY'
import asyncio, json, sys
from mcp_newsnow_server.server import news_mgr, BASE_URL

async def main():
    print(f"BASE_URL = {BASE_URL}")
    result = await news_mgr.fetch_news("知乎")
    if isinstance(result, str) and result.startswith("{"):
        try:
            data = json.loads(result)
            n = len(data.get("items", []))
            if n > 0:
                print(f"成功: 拿到 {n} 条新闻, 首条标题 = {data['items'][0].get('title', '')[:40]}")
                return 0
        except Exception as e:
            print(f"解析失败: {e}")
    print(f"失败: {str(result)[:200]}")
    return 1

sys.exit(asyncio.run(main()))
PY
  rc=$?
  set -e
  if [[ "$rc" != 0 ]]; then
    err "自检失败 (rc=$rc), 请检查上面的报错"
    exit "$rc"
  fi
  ok "自检通过"
fi

# ---------- 4. Claude Desktop 配置 (可选) ----------
section "步骤 4/4: Claude Desktop 配置"

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Darwin)  CLAUDE_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json" ;;
  Linux)   CLAUDE_CFG="$HOME/.config/Claude/claude_desktop_config.json" ;;
  MINGW*|MSYS*|CYGWIN*) CLAUDE_CFG="${APPDATA:-$HOME/AppData/Roaming}/Claude/claude_desktop_config.json" ;;
  *)       CLAUDE_CFG="" ;;
esac

# 把 RUN_CMD 拆成 command + args (JSON 数组形式)
build_server_json() {
  local cmd args_json
  # shellcheck disable=SC2206
  local parts=( $RUN_CMD )
  cmd="${parts[0]}"
  unset 'parts[0]'
  if [[ ${#parts[@]} -eq 0 ]]; then
    args_json="[]"
  else
    args_json="[$(printf '"%s",' "${parts[@]}")]"
    args_json="${args_json/,]/]}"
  fi
  cat <<JSON
{
  "command": "$cmd",
  "args": $args_json
}
JSON
}

if [[ "$WRITE_CLAUDE" == 1 ]]; then
  if [[ -z "$CLAUDE_CFG" ]]; then
    warn "无法识别系统 ($OS_NAME), 不知道 Claude Desktop 配置文件位置, 请手动配置"
  else
    info "目标配置文件: $CLAUDE_CFG"
    if ! command -v python3 >/dev/null 2>&1; then
      err "需要 python3 来安全地合并 JSON, 当前缺失"; exit 1
    fi
    mkdir -p "$(dirname "$CLAUDE_CFG")"
    if [[ -f "$CLAUDE_CFG" ]]; then
      backup="${CLAUDE_CFG}.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$CLAUDE_CFG" "$backup"
      ok "已备份原配置 -> $backup"
    fi

    SERVER_JSON="$(build_server_json)"
    if confirm "将以下条目写入 mcpServers.get_news ?\n$SERVER_JSON\n继续?"; then
      python3 - "$CLAUDE_CFG" "$SERVER_JSON" <<'PY'
import json, os, sys
cfg_path, server_json = sys.argv[1], sys.argv[2]
data = {}
if os.path.exists(cfg_path) and os.path.getsize(cfg_path) > 0:
    try:
        with open(cfg_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError:
        print("现有配置不是合法 JSON, 已视为空配置 (原文件已备份)", file=sys.stderr)
        data = {}
data.setdefault("mcpServers", {})
data["mcpServers"]["get_news"] = json.loads(server_json)
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
print("OK: 已写入 mcpServers.get_news")
PY
      ok "Claude Desktop 配置已更新, 请重启 Claude Desktop 后生效"
    else
      warn "已取消写入 Claude Desktop 配置"
    fi
  fi
else
  info "未指定 --claude, 跳过 Claude Desktop 配置"
  if [[ -n "$CLAUDE_CFG" ]]; then
    cat <<EOF
如需手动配置, 把下面的片段并入 ${CLAUDE_CFG}
{
  "mcpServers": {
    "get_news": $(build_server_json | sed 's/^/    /' | sed '1s/    //')
  }
}
EOF
  fi
fi

section "完成"
ok "部署完成 (模式: $MODE)"
echo
echo "${BOLD}手动启动命令:${RESET}  $RUN_CMD"
echo "${BOLD}调试方式:${RESET}      在终端粘贴上面的命令, 然后按 Ctrl+C 退出"
echo "${BOLD}重新部署:${RESET}      $0 $* "
