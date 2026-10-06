#!/bin/bash
# publish.sh — winpin 一键双端发布：码云 Gitee + GitHub
#
# 用法：
#   scripts/publish.sh                # 用现有 DMG 发布（不重新构建）
#   scripts/publish.sh --build        # 先构建 App 并重新打 DMG
#   scripts/publish.sh --gitee-only   # 只发码云
#   scripts/publish.sh --github-only  # 只发 GitHub
#   scripts/publish.sh --dry-run      # 只打印将执行的命令，不真正发布
#
# 依赖：
#   - 码云：~/.git-credentials 中存在 https://<user>:<token>@gitee.com
#           （或环境变量 GITEE_TOKEN）
#   - GitHub：~/.config/gh/hosts.yml 中的 oauth_token
#           （或环境变量 GITHUB_TOKEN）
#   - gh CLI：可用 PATH 中的 gh，或 ~/.workbuddy/tools/gh_*/bin/gh
#   - GitHub 需要代理才能直连：脚本自动探测 127.0.0.1:10886（SOCKS5），开着就自动用
#     端口不是 10886 时用 PROXY_PORT=xxxx scripts/publish.sh 指定
#
# 行为：
#   1. 从 Info.plist 读版本号 → tag v<版本号>
#   2. 推送 main 分支到两个 remote（gitee / origin）
#   --dry-run 时只打印将要执行的命令
#   3. 两端创建或更新 Release，并上传（覆盖）同名 DMG
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ---------- 参数 ----------
DO_BUILD=0
DRY=0
TARGET="both"
for arg in "$@"; do
  case "$arg" in
    --build)       DO_BUILD=1 ;;
    --gitee-only)  TARGET="gitee" ;;
    --github-only) TARGET="github" ;;
    --dry-run)     DRY=1 ;;
    -h|--help)     sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^#//'; exit 0 ;;
    *) echo "!! 未知参数: $arg（用 --help 查看用法）" >&2; exit 1 ;;
  esac
done

# ---------- dry-run 辅助 ----------
maybe() {
  if [[ "$DRY" == "1" ]]; then
    echo "   [dry-run] $*"
    return 0
  fi
  "$@"
}

# ---------- 版本号 ----------
PLIST="$ROOT/winpin/Resources/Info.plist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")}"
TAG="v${VERSION}"
DMG="$ROOT/build/winpin-${VERSION}-arm64.dmg"
DMG_NAME="winpin-${VERSION}-arm64.dmg"

echo "════════ winpin 发布 v${VERSION} ════════"

# ---------- 可选：构建 ----------
if [[ "$DO_BUILD" == "1" ]]; then
  echo "==> 构建 App"
  bash "$ROOT/scripts/build_release.sh"
  echo "==> 打包 DMG"
  bash "$ROOT/scripts/make_dmg.sh" "$VERSION"
fi

if [[ ! -f "$DMG" ]]; then
  echo "!! 未找到 $DMG" >&2
  echo "   先加 --build 构建，或手动打包后重试" >&2
  exit 1
fi
DMG_SIZE=$(du -h "$DMG" | awk '{print $1}')
echo "==> DMG: $DMG_NAME ($DMG_SIZE)"

# ---------- 凭据 ----------
GITEE_TOKEN="${GITEE_TOKEN:-}"
if [[ -z "$GITEE_TOKEN" && -f "$HOME/.git-credentials" ]]; then
  GITEE_TOKEN="$(grep 'gitee.com' "$HOME/.git-credentials" 2>/dev/null | head -1 | sed -E 's#https://[^:]*:([^@]*)@gitee.*#\1#' || true)"
fi

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$GITHUB_TOKEN" && -f "$HOME/.config/gh/hosts.yml" ]]; then
  GITHUB_TOKEN="$(grep 'oauth_token' "$HOME/.config/gh/hosts.yml" 2>/dev/null | head -1 | awk '{print $2}' || true)"
fi

# gh CLI 路径
GH=""
if command -v gh >/dev/null 2>&1; then
  GH="gh"
else
  for candidate in "$HOME"/.workbuddy/tools/gh_*/bin/gh; do
    [[ -x "$candidate" ]] && GH="$candidate" && break
  done
fi

# ---------- 代理探测（仅 GitHub 需要） ----------
PROXY_PORT="${PROXY_PORT:-10886}"
PROXY_ARGS=()
if nc -z -G1 127.0.0.1 "$PROXY_PORT" 2>/dev/null; then
  echo "==> 探测到 SOCKS5 代理 127.0.0.1:${PROXY_PORT}（GitHub 走代理，码云走直连）"
  PROXY_ARGS=(-c http.version=HTTP/1.1)
  GH_PROXY_ENV=(env -u HTTP_PROXY -u HTTPS_PROXY https_proxy=socks5://127.0.0.1:$PROXY_PORT http_proxy=socks5://127.0.0.1:$PROXY_PORT)
  GIT_PROXY_ENV=(env -u HTTP_PROXY -u HTTPS_PROXY https_proxy=socks5h://127.0.0.1:$PROXY_PORT http_proxy=socks5h://127.0.0.1:$PROXY_PORT)
else
  echo "==> 未探测到代理，GitHub 可能连不上（码云不受影响）"
  GH_PROXY_ENV=(env -u HTTP_PROXY -u HTTPS_PROXY)
  GIT_PROXY_ENV=(env -u HTTP_PROXY -u HTTPS_PROXY)
fi
GITEE_PROXY_ENV=(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy)

# ---------- 发布说明 ----------
RELEASE_NOTES="$(cat <<EOF
macOS 窗口置顶工具 winpin $TAG

## 下载安装
1. 打开 DMG，把 winpin.app 拖入「应用程序」
2. 首次打开被系统拦截：**右键 App → 打开**（详见 README）
3. 首次启动按引导授予「屏幕录制」权限

## 主要功能
- ⌃⌥P 置顶任意窗口为悬浮镜像（可拖动 / 单击跳转源窗口 / 双击取消）
- 右键菜单：镜像缩放（50%~200%）、透明度（50%~100%）、取消置顶
- 菜单栏面板搜索、开机自启、快捷键自定义

## 系统要求
- macOS 14.0+ / Apple Silicon
- 未做苹果公证，首次打开需右键打开（原因见 README）

MIT License
EOF
)"

# ---------- 1. 码云 Gitee ----------
gitee_publish() {
  echo
  echo "──── 码云 Gitee ────"
  if [[ -z "$GITEE_TOKEN" ]]; then
    echo "!! 未找到码云令牌（配置 ~/.git-credentials 或设置 GITEE_TOKEN）" >&2
    return 1
  fi

  maybe "${GITEE_PROXY_ENV[@]}" git -c http.version=HTTP/1.1 push gitee main:main

  API="https://gitee.com/api/v5/repos/ibicf771/winpin"
  REL_ID="$(curl -s --noproxy '*' "$API/releases/tags/$TAG?access_token=$GITEE_TOKEN" \
    | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("id") or "")
except Exception: print("")')"

  if [[ -z "$REL_ID" ]]; then
    echo "==> 创建发行版 $TAG"
    REL_ID="$(maybe curl -s --noproxy '*' -X POST "$API/releases" \
      -F "access_token=$GITEE_TOKEN" \
      -F "tag_name=$TAG" \
      -F "name=winpin $TAG" \
      -F "target_commitish=main" \
      -F "body=$RELEASE_NOTES" \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id"))')"
  else
    echo "==> 发行版 $TAG 已存在（id=${REL_ID}），将覆盖同名附件"
  fi

  if [[ -z "$REL_ID" ]]; then
    echo "!! 发行版创建失败" >&2; return 1
  fi

  # 幂等：同名旧附件先删除，避免重复运行堆积
  OLD_IDS="$(
    curl -s --noproxy '*' "$API/releases/$REL_ID/attach_files?access_token=$GITEE_TOKEN" \
      | python3 -c '
import json,sys
try:
    assets = json.load(sys.stdin)
except Exception:
    assets = []
print(" ".join(str(a["id"]) for a in assets if a.get("name") == "'"$DMG_NAME"'"))'
  )"
  if [[ -n "$OLD_IDS" ]]; then
    echo "==> 清理同名旧附件: $OLD_IDS"
    for aid in $OLD_IDS; do
      maybe curl -sS --noproxy '*' -X DELETE \
        "$API/releases/$REL_ID/attach_files/$aid?access_token=$GITEE_TOKEN" -o /dev/null
    done
  fi

  echo "==> 上传 DMG"
  maybe curl -sS --noproxy '*' -X POST "$API/releases/$REL_ID/attach_files" \
    -F "access_token=$GITEE_TOKEN" \
    -F "file=@$DMG" \
    -o /dev/null
  echo "✅ 码云: https://gitee.com/ibicf771/winpin/releases"
}

# ---------- 2. GitHub ----------
github_publish() {
  echo
  echo "──── GitHub ────"
  if [[ -z "$GH" ]]; then
    echo "!! 未找到 gh CLI，跳过（安装后放在 ~/.workbuddy/tools/gh_*/bin/gh）" >&2
    return 1
  fi
  if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "!! 未找到 GitHub 令牌，跳过" >&2
    return 1
  fi

  maybe "${GIT_PROXY_ENV[@]}" git -c http.version=HTTP/1.1 push \
    "https://x-access-token:${GITHUB_TOKEN}@github.com/ibicf771/winpin.git" main:main

  local gh_env=(-u HTTP_PROXY -u HTTPS_PROXY GH_TOKEN="$GITHUB_TOKEN")
  if [[ ${#PROXY_ARGS[@]} -gt 0 ]]; then
    gh_env+=(https_proxy=socks5://127.0.0.1:$PROXY_PORT http_proxy=socks5://127.0.0.1:$PROXY_PORT)
  fi

  if env "${gh_env[@]}" "$GH" release view "$TAG" --repo ibicf771/winpin >/dev/null 2>&1; then
    echo "==> 发行版 $TAG 已存在，上传（覆盖）DMG"
    maybe env "${gh_env[@]}" "$GH" release upload "$TAG" "$DMG" --repo ibicf771/winpin --clobber
  else
    echo "==> 创建发行版 $TAG 并上传 DMG"
    maybe env "${gh_env[@]}" "$GH" release create "$TAG" "$DMG" \
      --repo ibicf771/winpin --title "winpin $TAG" --notes "$RELEASE_NOTES"
  fi
  echo "✅ GitHub: https://github.com/ibicf771/winpin/releases"
}

# ---------- 执行 ----------
case "$TARGET" in
  both)   gitee_publish || true; github_publish || true ;;
  gitee)  gitee_publish ;;
  github) github_publish ;;
esac

echo
echo "════════ 完成 v${VERSION} ════════"
[[ "$TARGET" != "github" ]] && echo "码云:    https://gitee.com/ibicf771/winpin/releases"
[[ "$TARGET" != "gitee"  ]] && echo "GitHub: https://github.com/ibicf771/winpin/releases"
exit 0
