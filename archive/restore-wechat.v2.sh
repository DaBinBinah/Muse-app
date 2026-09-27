#!/usr/bin/env bash
# restore-wechat.sh — 平台重建后，把微信 Linux 恢复到可用状态（幂等）
#
# v2（外部审计修订版，基于 v1 实测版，保留全部实测有效细节）：
#   1. HOME 加固：被开机钩子/看门狗以 root 调起时，HOME 可能不是 /home/hatch，先纠正
#   2. 单实例锁：开机钩子与看门狗同时触发时只允许一个实例（原子 mkdir + stale 回收）
#   3. dpkg 锁等待：重建后平台包 reconciliation 会占锁，最多等 10 分钟
#   4. 离线安装改为"缓存里所有缺失包整批装"：v1 只装 3 个顶层包，全新机器上
#      dpkg -i 会因闭包依赖缺失而失败（且 set -e 下直接退出没有兜底）
#   5. Xvfb 检查精确到 :99；日志持久化到 ~/workspace/setup/logs/
#
# 行为（保留 v1 已实测有效的部分：包清单、xshot、直连启动、1280x800）：
#   1. apt 包（xvfb / fonts-noto-cjk / x11-xserver-utils）：缺哪个装哪个；
#      优先整批离线装（~/workspace/installers/deb-cache/），仍有缺才走 apt 在线。
#   2. 微信本体：/opt/wechat/wechat 不存在才 dpkg -i 官方 deb。
#   3. X11 小工具（xshot）：二进制缺失且能编译才编。
#   4. Xvfb :99：没在跑才启动（先清残留 lock 文件）。
#   5. 微信进程：没在跑才启动（直连模式：清代理变量，沙盒代理的 TLS 拦截会导致登录失败）。
#   6. 登录：客户端启动后显示头像页，需点 "Log In"，再在手机微信上确认（约 1 分钟内有效）。
#
# 红线：绝不删除、清空、覆盖 ~/.xwechat —— 本脚本没有任何写 ~/.xwechat 的命令。

set -euo pipefail

# ---- 0a. HOME 加固（钩子环境可能 HOME=/root）----
if [ ! -d "$HOME/workspace/installers" ] && [ -d /home/hatch/workspace/installers ]; then
  export HOME=/home/hatch
fi

DISPLAY_NUM=":99"
WECHAT_DEB="$HOME/workspace/installers/WeChatLinux_x86_64.deb"
DEB_CACHE="$HOME/workspace/installers/deb-cache"
X11_TOOLS="$HOME/workspace/tools/x11"
SETUP_DIR="$HOME/workspace/setup"
LOG_DIR="$SETUP_DIR/logs"
LOG="$LOG_DIR/wechat-restore.log"
LOCKDIR="$SETUP_DIR/.wechat-restore.lock"
MAX_SEC=1800
APT_PKGS=(xvfb fonts-noto-cjk x11-xserver-utils)
TAG="[restore-wechat]"

mkdir -p "$LOG_DIR"
log() { echo "$TAG $(date '+%F %T') $*" | tee -a "$LOG"; }

# ---- 0b. 单实例锁（原子 mkdir；不用 flock，避免 fd 被子进程继承）----
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ] && [ -f "$LOCKDIR/started" ]; then
    oldpid="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
    started="$(cat "$LOCKDIR/started" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    alive=0
    if [ -n "$oldpid" ] && [ -f "/proc/$oldpid/cmdline" ] \
       && tr '\0' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null | grep -q "[r]estore-wechat.sh"; then
      alive=1
    fi
    if [ "$alive" = 1 ] && [ "$((now - started))" -lt "$MAX_SEC" ]; then
      log "已有恢复在进行中，本次退出"
      exit 0
    fi
    log "回收 stale 锁（pid=${oldpid:-?}）"
  fi
  rm -rf "$LOCKDIR"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log "抢锁失败，退出"
    exit 0
  fi
fi
echo $$ > "$LOCKDIR/pid"
date +%s > "$LOCKDIR/started"
trap 'rm -rf "$LOCKDIR"' EXIT

# ---- 0c. dpkg 锁等待 ----
wait_dpkg_lock() {
  if ! command -v fuser >/dev/null 2>&1; then return 0; fi
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if [ "$waited" -ge 600 ]; then return 1; fi
    sleep 15
    waited=$((waited + 15))
  done
  return 0
}

have_pkg() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'; }

# 整批离线安装：把缓存里"系统缺失"的包一次装上；两遍装法处理依赖顺序
install_cache_closure() {
  local missing=() deb pkg
  for deb in "$DEB_CACHE"/*.deb; do
    [ -f "$deb" ] || continue
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"
    if [ -n "$pkg" ] && ! have_pkg "$pkg"; then
      missing+=("$deb")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    log "离线闭包：无缺失包"
    return 0
  fi
  if ! wait_dpkg_lock; then
    log "WARN: dpkg 锁等待超时，离线安装放弃"
    return 1
  fi
  log "离线闭包安装 ${#missing[@]} 个包"
  if ! dpkg --force-confdef --force-confold -i "${missing[@]}" >>"$LOG" 2>&1; then
    dpkg --configure -a >>"$LOG" 2>&1 || true
    if ! dpkg --force-confdef --force-confold -i "${missing[@]}" >>"$LOG" 2>&1; then
      dpkg --configure -a >>"$LOG" 2>&1 || true
      log "WARN: 离线闭包安装有失败项"
      return 1
    fi
  fi
  return 0
}

# ---- 1. apt 包：缺哪个装哪个（离线整批优先，在线兜底）----
missing_pkgs=()
for p in "${APT_PKGS[@]}"; do
  if ! have_pkg "$p"; then missing_pkgs+=("$p"); fi
done

if [ "${#missing_pkgs[@]}" -eq 0 ]; then
  log "apt 包已齐 (${APT_PKGS[*]})，跳过"
else
  if compgen -G "$DEB_CACHE/*.deb" >/dev/null; then
    install_cache_closure || true
  else
    log "无离线缓存目录"
  fi
  still_missing=()
  for p in "${APT_PKGS[@]}"; do
    if ! have_pkg "$p"; then still_missing+=("$p"); fi
  done
  if [ "${#still_missing[@]}" -gt 0 ]; then
    log "在线安装: ${still_missing[*]}"
    if ! timeout 120 apt-get update >>"$LOG" 2>&1; then
      log "apt update 超时/失败，继续尝试安装"
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "${still_missing[@]}" >>"$LOG" 2>&1; then
      log "WARN: 在线安装 ${still_missing[*]} 失败"
    fi
  fi
  for p in "${APT_PKGS[@]}"; do
    if ! have_pkg "$p"; then log "WARN: $p 仍未装上"; fi
  done
fi

# ---- 2. 微信本体 ----
if [ -x /opt/wechat/wechat ]; then
  log "微信已装 (/opt/wechat/wechat)，跳过"
else
  if [ ! -f "$WECHAT_DEB" ]; then
    log "FATAL: 找不到 $WECHAT_DEB"
    exit 1
  fi
  log "dpkg 安装微信: $WECHAT_DEB"
  if ! dpkg --force-confdef --force-confold -i "$WECHAT_DEB" >>"$LOG" 2>&1; then
    log "补依赖：configure + 离线闭包后重试"
    dpkg --configure -a >>"$LOG" 2>&1 || true
    install_cache_closure || true
    if ! dpkg --force-confdef --force-confold -i "$WECHAT_DEB" >>"$LOG" 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -yf >>"$LOG" 2>&1 || true
    fi
  fi
  if [ ! -x /opt/wechat/wechat ]; then
    log "FATAL: 微信安装失败"
    exit 1
  fi
fi

# ---- 3. X11 小工具（xshot）：二进制缺失且能编译才编 ----
if [ ! -x "$X11_TOOLS/xshot" ] && command -v gcc >/dev/null && [ -f /usr/include/X11/Xlib.h ] && [ -f "$X11_TOOLS/xshot.c" ]; then
  if gcc -O2 -o "$X11_TOOLS/xshot" "$X11_TOOLS/xshot.c" -lX11 2>>"$LOG"; then
    log "xshot 已编译"
  else
    log "xshot 编译失败（不影响微信使用）"
  fi
fi

# ---- 4. Xvfb :99 ----
if pgrep -f '[X]vfb.*:99' >/dev/null 2>&1; then
  log "Xvfb :99 已在跑，跳过"
else
  disp="${DISPLAY_NUM#:}"
  rm -f "/tmp/.X${disp}-lock" "/tmp/.X11-unix/X${disp}"
  log "启动 Xvfb $DISPLAY_NUM"
  nohup Xvfb "$DISPLAY_NUM" -screen 0 1280x800x24 >>"$LOG_DIR/xvfb-99.log" 2>&1 &
  sleep 2
  if ! pgrep -f '[X]vfb.*:99' >/dev/null; then
    log "FATAL: Xvfb 启动失败，见 $LOG_DIR/xvfb-99.log"
    exit 1
  fi
fi

# ---- 5. 微信进程（直连模式）----
if pgrep -f '[o]pt/wechat/wechat' >/dev/null 2>&1; then
  log "微信进程已在跑，跳过"
else
  log "启动微信（直连模式，清代理变量）"
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      DISPLAY="$DISPLAY_NUM" nohup /opt/wechat/wechat >>"$LOG_DIR/wechat.log" 2>&1 &
  sleep 6
  if ! pgrep -f '[o]pt/wechat/wechat' >/dev/null; then
    log "FATAL: 微信启动失败，见 $LOG_DIR/wechat.log"
    exit 1
  fi
fi

# ---- 6. 验证 ----
log "=== 验证 ==="
pgrep -af '[o]pt/wechat/wechat' | head -2 || true
pgrep -f '[X]vfb.*:99' || true
if [ -d "$HOME/.xwechat" ]; then
  du -sh "$HOME/.xwechat" | sed "s|^|$TAG 会话目录（未动）：|"
fi
log "完成。下一步：客户端点 \"Log In\"，1 分钟内在手机微信上确认登录。"
