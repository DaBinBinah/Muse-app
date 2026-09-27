---
name: muse-app
description: "在 Muse/hatch 沙盒上部署「Linux 微信持久化守护」（muse-app）：微信 deb 与依赖闭包全量离线缓存到家目录、幂等一键恢复脚本、沙盒内看门狗 + 平台开机钩子，沙盒重建后约 2 分钟内自动把微信装回并拉起，登录态与数据（~/.xwechat）全程不动。刻意不包含上游 muse-guardian 的自动审批（MuseAutoApprove）、CF 探针、Hermes 等组件；不处理任何 muse.ai 凭据；平台审批卡片一律由用户手动点击。触发词：微信持久化、微信保活、重建后恢复微信、微信一直登录、muse-app。"
version: 1.0.0
license: MIT
---

# muse-app：微信持久化守护一键部署手册

> 📌 **版本说明（v4.1 对齐）**：本手册是 muse-app 的可复用部署蓝图，已并入实战终版 v4.1 的全部关键修订（见步骤 3 的「v4.1 实战修订清单」；开机钩子为可选层，实战中"沙盒 cron + 平台定时任务"双调度已足够）。部署时请遵守本手册的「实测优先」规则：微信启动序列以部署 Agent 自己验证过的为准并回写脚本。

## 一、这套东西是什么（以及刻意不包含什么）

平台（Muse / hatch 沙盒）会不定期**重建**沙盒：整机从外部重装，系统目录（`/opt`、`/usr`、dpkg 数据库、cron、Xvfb）全部消失，**只有 `$HOME`（`/home/hatch`）保留**。已实测确认：`~/workspace`、`~/workspace/installers/WeChatLinux_x86_64.deb`、`~/.xwechat`（微信登录态与数据）都能在重建中幸存。

本手册部署的是一套**微信专用的恢复体系**：

| 层         | 组件                                                  | 对付的故障                        | 恢复时间          |
| ---------- | ----------------------------------------------------- | --------------------------------- | ----------------- |
| 核心       | `restore-wechat.sh`（幂等一键恢复）                   | 被下面各层调用                    | 约 2 分钟         |
| Layer 1    | `wechat-watchdog.sh`（沙盒内 cron，每分钟）           | 机器活着，但 Xvfb / 微信进程挂了  | 1 分钟内          |
| Layer 2b   | 平台开机钩子（每次启动跑一次）                        | 整机重建，沙盒内一切全灭          | 开机后约 2 分钟   |
| Layer 2a（可选） | 平台定时巡检（每 5 分钟）                       | 开机钩子偶发失败（钩子不重试）    | 最坏 5 分钟       |

**刻意不包含的内容（与上游 muse-guardian 的区别，不要自行加回）**：

- ❌ 不装 MuseAutoApprove，**不自动批准任何平台审批卡片**。部署/缓存过程若弹审批卡（apt 源、镜像站），请用户手动点一次允许即可。
- ❌ 不需要、不处理任何 muse.ai 账号密码。
- ❌ 不部署 Cloudflare 监控探针、Hermes 微信机器人等与"保住用户自己的 Linux 微信"无关的组件。

**没有任何一层能阻止平台重建沙盒**——重建是平台从外部做的。本体系只保证「重建后自动恢复」。

## 二、执行规则（AI 必读）

1. **开工先问执行方式**：A 全部安装 / B 逐模块（默认 B）。同一模块内的步骤连着做完，只在"用户手动做"出现时才停。
2. **数据红线（最高优先级，凌驾于本手册任何步骤之上）**：`~/.xwechat` 是微信的登录态与聊天数据。**任何步骤、任何脚本都绝不删除、清空、覆盖、重置它**。我们只重装程序、重启进程，不碰数据目录。
3. **实测优先**：本手册给出的微信启动序列是参考实现。如果你（执行手册的 Agent）自己有此前实测可用的启动命令（Xvfb 参数、微信启动参数、环境变量等），**以你的实测版本为准**，并把它固化进 `restore-wechat.sh` 对应段落（这是本手册明确授权且鼓励的）。
4. **幂等**：所有脚本可重复执行；每步先判断（包已装？进程已在跑？），是则跳过。
5. **离线优先**：所有安装包缓存在 `$HOME`；重建后的恢复流程**不依赖网络**（断网也要能装回来）。
6. 每条命令都要真跑过再报告结果；跑不了就直说，不编造输出。

### 模块地图（顺序不可乱）

| 模块                 | 干什么                                       | 步骤 | 用户要做什么           |
| -------------------- | -------------------------------------------- | ---- | ---------------------- |
| A｜离线缓存底座      | 微信 deb 核对 + 依赖闭包下载                 | 1–2  | 可能点几次审批卡       |
| B｜恢复脚本          | lib-pkgs.sh + restore-wechat.sh 落盘并演练   | 3–4  | 无                     |
| C｜自动恢复接入      | 看门狗 cron、开机钩子、（可选）平台巡检      | 5–7  | 平台端确认授权         |
| 收尾                 | 验证清单 + 重建演练                          | 8–9  | 决定是否做演练         |

---

# 模块 A｜离线缓存底座（步骤 1–2）

## 步骤 1：前置核对

### ① 🤖 AI 执行（命令）

```bash
echo "HOME=$HOME"; id -u; uname -m
ls -l ~/workspace/installers/WeChatLinux_x86_64.deb
dpkg -l | grep -iE 'wechat|weixin' || echo "微信当前未装（没关系，脚本会装回）"
ls -ld ~/.xwechat && du -sh ~/.xwechat
command -v Xvfb || echo "Xvfb 当前未装"
```

### ② 💬 对用户说

> 📋 开始部署微信持久化。先核对现有资产（安装包、数据目录），不用你操作。

### ③ 🙋 用户手动做

无。

### ④ ✅ 做完的标志

- `WeChatLinux_x86_64.deb` 存在；
- `~/.xwechat` 存在（这是数据幸存的证据，也是整个方案的前提）。

微信当前装没装、Xvfb 在不在都无所谓——没装正好由恢复脚本装回并顺便完成一次实战验证。

### ⑤ 🛠️ 常见失败与处理

| 现象                          | 处理                                                         |
| ----------------------------- | ------------------------------------------------------------ |
| deb 文件不在                  | 找回官方安装包放回 `~/workspace/installers/`（需网络，可能要点审批卡） |
| `~/.xwechat` 不存在           | 说明数据目录被挪过或账号未登录过；确认登录一次后再继续       |
| 架构不是 x86_64               | 换对应架构的 deb，并把本手册中的文件名同步替换               |

## 步骤 2：依赖闭包缓存（重建后断网也能装回）

### ① 🤖 AI 执行（命令）

**前置**：微信最好是已安装状态（依赖已就位，闭包才算得全）。未装就先 `dpkg -i ~/workspace/installers/WeChatLinux_x86_64.deb` 装上再缓存。

```bash
cd ~/workspace/installers
apt-get update -qq

# 1) 从微信 deb 提取直接依赖的包名（剥掉版本约束）
dpkg-deb -f WeChatLinux_x86_64.deb Depends | tr ',' '\n' \
  | sed -E 's/\(.*//; s/[[:space:]]//g' | grep -vE '^$' > /tmp/wx-direct.txt

# 2) 加上本体系自己要用的组件
printf 'xvfb\nfonts-noto-cjk\nfontconfig\ncron\nx11-utils\n' >> /tmp/wx-direct.txt
sort -u /tmp/wx-direct.txt -o /tmp/wx-direct.txt

# 3) 递归闭包：只保留镜像里真实安装着的包，并剔除互斥替代品
{ while read -r p; do
    apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
      --no-breaks --no-replaces --no-enhances "$p" 2>/dev/null
  done < /tmp/wx-direct.txt; } | grep '^[a-z0-9]' | sort -u > /tmp/closure.txt
while read -r p; do dpkg -l "$p" 2>/dev/null | grep -q '^ii' && echo "$p"; done \
  < /tmp/closure.txt \
  | grep -vxE 'systemd-standalone-sysusers|opensysusers|cdebconf|libdebian-installer4|libtextwrap1' \
  > /tmp/closure.final.txt

# 4) 下载到持久缓存目录
mkdir -p ~/workspace/installers/deb-cache && cd ~/workspace/installers/deb-cache
xargs -a /tmp/closure.final.txt apt-get download || true

# 5) 验证
ls *.deb | wc -l
for p in xvfb fonts-noto-cjk cron; do ls ${p}_*.deb >/dev/null 2>&1 && echo "OK  $p" || echo "MISSING $p"; done
for d in *.deb; do dpkg-deb -f "$d" Package >/dev/null 2>&1 || echo "BAD $d"; done; echo "全部 .deb 可解析"
du -sh .
```

### ② 💬 对用户说

> 💾 现在把"重建后要用的安装包"提前下载缓存到家目录（几十 MB）。过程中如果平台弹"是否允许访问"的卡片，**请手动点一次允许**——就这一次，之后同类请求平台会记住。你不用做别的。

### ③ 🙋 用户手动做

- 弹审批卡时点"允许"。

### ④ ✅ 做完的标志

- `deb-cache/` 里 deb 数量 ≥ 40（参考值，以实际闭包为准）；
- `xvfb`、`fonts-noto-cjk`、`cron` 三个关键包都在；
- 所有 .deb 可被 `dpkg-deb` 解析。

### ⑤ 🛠️ 常见失败与处理

| 现象                                  | 原因                       | 处理                                                       |
| ------------------------------------- | -------------------------- | ---------------------------------------------------------- |
| `apt-get download` 报 Unable to locate | apt 列表空 / 源不可达      | 先 `apt-get update`；仍不行换源或从能上网的机器拷 .deb 过来 |
| 数量只有个位数                        | 闭包没算出来               | 检查第 3 步的管道是否有报错                                |
| 某些包 MISSING                        | xargs 遇错中断             | 重跑 `xargs -a /tmp/closure.final.txt apt-get download`    |
| 磁盘不足                              | 闭包含大型运行库           | 正常（约几十 MB）；不要为省空间删依赖                      |

---

# 模块 B｜恢复脚本（步骤 3–4）

## 步骤 3：落盘公共函数与恢复脚本

### ① 🤖 AI 执行（命令）

```bash
mkdir -p ~/workspace/setup/logs
# 把下面两个脚本按代码 1/2、2/2 落盘到 ~/workspace/setup/，然后：
chmod +x ~/workspace/setup/*.sh
for f in ~/workspace/setup/*.sh; do bash -n "$f" && echo "OK  $f" || echo "FAIL $f"; done
```

### ② 💬 对用户说

> 🧱 现在写核心的恢复脚本（幂等、可反复执行），写完我会当场演练一遍给你看结果。

### ③ 🙋 用户手动做

无。

### ④ ✅ 做完的标志

两个脚本都存在、可执行、语法检查通过。

### ⑤ 🛠️ 常见失败与处理

| 现象                    | 处理                                     |
| ----------------------- | ---------------------------------------- |
| `bash -n` 报语法错      | 复制不完整：重新整段落盘，别手抄         |
| bash 报 `$'\r'`         | 复制时带上了 CRLF：`sed -i 's/\r$//' <文件>` |

### 代码 1/2：`lib-pkgs.sh`（离线 deb 安装公共函数）

**目标路径**：`~/workspace/setup/lib-pkgs.sh`　**权限**：`chmod +x`

```bash
#!/usr/bin/env bash
# lib-pkgs.sh — 离线 deb 安装公共函数（被 restore-wechat.sh source）。
# 策略：只安装缺失的包（避免降级镜像自带的新版本）；
# dpkg 跑两遍，第二遍解决 pre-depends 顺序问题。

# 等待 dpkg/apt 锁释放。重建刚完成时平台自己的包 reconciliation 可能占着锁，
# 直接 dpkg 会失败；最多等 10 分钟，每 15 秒检查一次。
wait_for_dpkg_lock() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
    if [ "$waited" -ge 600 ]; then
      return 1
    fi
    sleep 15
    waited=$((waited + 15))
  done
  return 0
}

# install_offline_debs <deb-cache-dir> [log-file]
# 返回 0 表示成功（或无需安装），非 0 表示失败。
install_offline_debs() {
  local cache_dir="$1" log_file="${2:-/dev/null}"
  local missing="" deb pkg

  for deb in "$cache_dir"/*.deb; do
    [ -f "$deb" ] || continue
    pkg="$(dpkg-deb -f "$deb" Package 2>/dev/null)"
    if [ -n "$pkg" ] && ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
      missing="$missing $deb"
    fi
  done

  if [ -z "$missing" ]; then
    return 0
  fi

  if ! wait_for_dpkg_lock; then
    echo "dpkg 锁等待超时" >>"$log_file"
    return 1
  fi

  # shellcheck disable=SC2086
  if DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i $missing >>"$log_file" 2>&1; then
    return 0
  fi
  # 第一遍可能因 pre-depends 顺序失败：configure 已解包的包，再装一遍
  dpkg --configure -a >>"$log_file" 2>&1 || true
  # shellcheck disable=SC2086
  if DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i $missing >>"$log_file" 2>&1; then
    dpkg --configure -a >>"$log_file" 2>&1 || true
    return 0
  fi
  dpkg --configure -a >>"$log_file" 2>&1 || true
  return 1
}
```

### v4.1 实战修订清单（部署时必须并入脚本——每条都来自真实重建演练的教训）

1. **HOME 加固**：脚本最前面纠正 `HOME=/root` 的调用环境（平台钩子/巡检以 root 调起时常见）；
2. **单实例锁**：原子 mkdir + stale 回收——开机钩子、看门狗、手动同时触发时只允许一个实例在跑；
3. **dpkg 锁等待**：重建后平台在后台做包 reconciliation 占着锁，最多等 10 分钟再动手，硬闯必败；
4. **离线整批安装**：装缓存里**所有**缺失包（只装顶层包会在全新机器上因闭包依赖缺失而失败）；安装失败**逐包重试**，互斥替代品（`opensysusers` / `systemd-standalone-sysusers` 等）记"跳过"，只有真装不上才 WARN；
5. **cron 三连**（顺序敏感）：装 cron 包（离线优先）→ 判活后起 cron 守护 → 用**临时文件中转**幂等重写 crontab。⚠️ 空表时 `crontab -l` 退出码为 1，在 `set -euo pipefail` 下直接接管道会把子 shell 杀掉——装出空 crontab 还让整个脚本 rc=1（实战演练抓出的头号 showstopper）；
6. **machine-id 回写（0d 段，必须在启动微信之前）**：基线存 `$SETUP_DIR/machine-id.baseline`；格式护栏 `^[0-9a-f]{32}$` 通过且与当前值不同才 `cp` 回写 `/etc/machine-id`；`/var/lib/dbus/machine-id` 仅当为独立文件（非符号链接）时同步；hostname 只记基线、不回写（防干扰平台识别沙盒）。目的：让微信不再把重建后的机器判为"新设备"。

### 代码 2/2：`restore-wechat.sh`（核心：幂等一键恢复）

**目标路径**：`~/workspace/setup/restore-wechat.sh`　**权限**：`chmod +x`

```bash
#!/usr/bin/env bash
# restore-wechat.sh — 沙盒重建后一键恢复 Linux 微信（幂等，可反复执行）。
# 红线：绝不删除/清空/覆盖 ~/.xwechat（微信登录态与数据在家目录，幸存无需处理）。
# 流程：等 dpkg 锁 → 离线装依赖 → 装微信 deb → 起 Xvfb → 起微信 → 验证。
set -uo pipefail

# HOME 加固：环境异常（如 HOME=/root）时纠正
if [ ! -d "$HOME/workspace/setup" ] && [ -d /home/hatch/workspace/setup ]; then
  export HOME=/home/hatch
fi

SETUP_DIR="$HOME/workspace/setup"
INSTALLERS="$HOME/workspace/installers"
WECHAT_DEB="$INSTALLERS/WeChatLinux_x86_64.deb"
DEBCACHE="$INSTALLERS/deb-cache"
LOG="$SETUP_DIR/logs/wechat-restore.log"
LOCKDIR="$SETUP_DIR/.wechat-restore.lock"
MAX_RESTORE_SEC=1200   # 20 分钟：超过视为 stale 锁
XVFB_DISPLAY=":99"

# shellcheck disable=SC1091
. "$SETUP_DIR/lib-pkgs.sh"

export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export DEBIAN_FRONTEND=noninteractive

mkdir -p "$SETUP_DIR/logs"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# --- 单实例锁（原子 mkdir + stale 回收；不用 flock，避免 fd 被子进程继承）---
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -f "$LOCKDIR/pid" ] && [ -f "$LOCKDIR/started" ]; then
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    started=$(cat "$LOCKDIR/started" 2>/dev/null || echo 0)
    now=$(date +%s); alive=0
    if [ -n "$oldpid" ] && [ -f "/proc/$oldpid/cmdline" ] \
       && tr '\0' ' ' < "/proc/$oldpid/cmdline" 2>/dev/null | grep -q "[/]restore-wechat.sh"; then
      alive=1
    fi
    if [ "$alive" = 1 ] && [ $((now - started)) -lt "$MAX_RESTORE_SEC" ]; then
      log "已有恢复在进行中，本次退出"; exit 0
    fi
    log "检测到 stale 锁（pid=$oldpid），回收后继续"
  fi
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { log "抢锁失败，退出"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"; date +%s > "$LOCKDIR/started"
trap 'rm -rf "$LOCKDIR"' EXIT

log "===== 微信恢复开始 ====="

# --- 0. 等 apt/dpkg 锁（重建后平台可能在 reconciliation，最多等 10 分钟）---
for i in $(seq 1 20); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
    break
  fi
  log "apt/dpkg 锁被占用，等待 30s ($i/20)"; sleep 30
done

# --- 1. 依赖：离线缓存优先，失败回退 apt（回退需网络）---
log "安装依赖（离线缓存优先）"
if [ -d "$DEBCACHE" ] && ls "$DEBCACHE"/*.deb >/dev/null 2>&1; then
  install_offline_debs "$DEBCACHE" "$LOG" || log "WARN: 离线依赖安装有失败项"
else
  log "WARN: 无离线缓存目录，跳过离线安装"
fi
if ! command -v Xvfb >/dev/null 2>&1; then
  log "Xvfb 仍缺失，回退 apt（需网络）"
  apt-get update -qq >>"$LOG" 2>&1
  apt-get install -y xvfb fonts-noto-cjk >>"$LOG" 2>&1 || log "WARN: apt 安装 xvfb/字体失败"
fi

# --- 2. 微信本体（dpkg 里没有才装）---
pkg="$(dpkg-deb -f "$WECHAT_DEB" Package 2>/dev/null || echo wechat)"
if [ -n "$pkg" ] && dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
  log "微信已安装，跳过"
elif [ -f "$WECHAT_DEB" ]; then
  log "安装微信 deb（$WECHAT_DEB）"
  if ! dpkg --force-confdef --force-confold -i "$WECHAT_DEB" >>"$LOG" 2>&1; then
    # 典型原因是依赖顺序：configure 后补装依赖再试一遍
    dpkg --configure -a >>"$LOG" 2>&1 || true
    install_offline_debs "$DEBCACHE" "$LOG" || true
    dpkg --force-confdef --force-confold -i "$WECHAT_DEB" >>"$LOG" 2>&1 \
      || { apt-get install -f -y >>"$LOG" 2>&1 || true; }
  fi
  if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    log "微信安装完成"
  else
    log "WARN: 微信安装未确认成功，看 $LOG"
  fi
else
  log "ERROR: 找不到微信安装包 $WECHAT_DEB"
  exit 1
fi

# --- 3. Xvfb ---
if ! pgrep -f "[X]vfb.*$XVFB_DISPLAY" >/dev/null 2>&1; then
  log "启动 Xvfb $XVFB_DISPLAY"
  nohup Xvfb "$XVFB_DISPLAY" -screen 0 1920x1080x24 -nolisten tcp \
    >> "$SETUP_DIR/logs/xvfb.log" 2>&1 &
  sleep 2
  if pgrep -f "[X]vfb.*$XVFB_DISPLAY" >/dev/null 2>&1; then
    log "Xvfb 已启动"
  else
    log "WARN: Xvfb 启动失败，看 logs/xvfb.log"
  fi
fi

# --- 4. 启动微信 ---
# ⚠️ 参考实现。部署时若与你此前实测可用的启动命令（参数、环境变量、启动前
#    的额外步骤）不同，以实测版本为准替换本段，并保留下面的存活判断逻辑。
WECHAT_BIN="$(readlink -f "$(command -v wechat 2>/dev/null || echo /opt/wechat/wechat)" 2>/dev/null || echo /opt/wechat/wechat)"
WX_PAT="${WECHAT_BIN%/*}/[w]echat"   # 用完整路径匹配，避免误配到脚本自身

if pgrep -f "$WX_PAT" >/dev/null 2>&1; then
  log "微信进程已在运行，跳过启动"
else
  log "启动微信（DISPLAY=$XVFB_DISPLAY）"
  nohup env DISPLAY="$XVFB_DISPLAY" "$WECHAT_BIN" \
    >> "$SETUP_DIR/logs/wechat.log" 2>&1 &
  sleep 5
  if pgrep -f "$WX_PAT" >/dev/null 2>&1; then
    log "微信已启动"
  else
    log "WARN: 微信启动后未见进程，看 logs/wechat.log"
  fi
fi

# --- 5. 结果 ---
if pgrep -f "$WX_PAT" >/dev/null 2>&1; then
  log "===== 微信恢复完成（数据目录未动） ====="
  echo "OK: 微信已恢复"
  exit 0
else
  log "===== 微信恢复失败 ====="
  echo "FAIL: 见 $LOG"
  exit 1
fi
```

## 步骤 4：当场演练（两种场景各一次）

### ① 🤖 AI 执行（命令）

```bash
# 演练 1：幂等空跑——微信已在时，应全部跳过并正常退出
bash ~/workspace/setup/restore-wechat.sh; echo "rc=$?"
tail -5 ~/workspace/setup/logs/wechat-restore.log

# 演练 2：实战——杀掉微信进程，让脚本把它救回来
pkill -f "/opt/wechat/[w]echat" 2>/dev/null; sleep 2
bash ~/workspace/setup/restore-wechat.sh; echo "rc=$?"
tail -8 ~/workspace/setup/logs/wechat-restore.log
```

### ② 💬 对用户说

> 🧪 恢复脚本写好了，我正在做两种演练：① 什么都不缺时跑一遍（应当全部跳过）；② 把微信进程杀掉再跑一遍（应当自动装回/拉起）。结果马上给你。

### ③ 🙋 用户手动做

无。

### ④ ✅ 做完的标志

- 演练 1：`rc=0`，日志显示"已安装，跳过 / 已在运行，跳过"；
- 演练 2：`rc=0`，微信进程重新出现在进程列表里；
- 两次演练后 `~/.xwechat` 完好（`ls ~/.xwechat | head` 有内容）。

### ⑤ 🛠️ 常见失败与处理

| 现象                             | 原因                     | 处理                                                           |
| -------------------------------- | ------------------------ | -------------------------------------------------------------- |
| 演练 2 后微信没起来              | 启动参数不对             | 换成你此前实测可用的启动命令，回写脚本第 4 段后重试            |
| 日志显示 dpkg 一直等锁           | 平台 reconciliation 中   | 正常，脚本会等最多 10 分钟；超时看锁被谁占着                   |
| `dpkg -i` 报依赖缺失             | 缓存闭包不全             | 联网补跑步骤 2 的下载；或临时 `apt-get install -f -y`          |
| 微信起来了但界面异常（方块字）   | 中文字体缺失             | 确认 `fonts-noto-cjk` 在缓存里且已装                           |

---

# 模块 C｜自动恢复接入（步骤 5–7）

## 步骤 5：Layer 1 — 沙盒内看门狗（写入 cron）

### ① 🤖 AI 执行（命令）

落盘 `wechat-watchdog.sh`（代码见下），然后：

```bash
chmod +x ~/workspace/setup/wechat-watchdog.sh
bash -n ~/workspace/setup/wechat-watchdog.sh && echo "语法 OK"

# 写入 crontab（幂等）
(crontab -l 2>/dev/null | grep -v "wechat-watchdog.sh"; echo "* * * * * $HOME/workspace/setup/wechat-watchdog.sh") | crontab -
crontab -l | grep wechat

# 手动跑一次
bash ~/workspace/setup/wechat-watchdog.sh; echo "rc=$?"
tail -3 ~/workspace/setup/logs/watchdog.log
```

### ② 💬 对用户说

> 🐕 第一层保活：沙盒自己的看门狗，每分钟检查 Xvfb 和微信进程，挂了就自动拉起。你不用做任何事。

### ③ 🙋 用户手动做

无。

### ④ ✅ 做完的标志

- crontab 里有且只有一行 `wechat-watchdog.sh`；
- 手动跑一次日志有记录（微信在跑时应是"巡检正常"）。

### ⑤ 🛠️ 常见失败与处理

| 现象                        | 处理                                                              |
| --------------------------- | ----------------------------------------------------------------- |
| `crontab: command not found` | cron 未装：跑一遍 `restore-wechat.sh`（离线缓存里有 cron 包）    |
| 日志不增长                  | cron 守护进程没跑：`pgrep -f "[/]usr/sbin/cron"`；`service cron start` |

### 代码：`wechat-watchdog.sh`

**目标路径**：`~/workspace/setup/wechat-watchdog.sh`　**权限**：`chmod +x`

```bash
#!/usr/bin/env bash
# wechat-watchdog.sh — 每分钟巡检：Xvfb 在不在、微信在不在；
# 不在就跑 restore（其内部有单实例锁，重复触发安全）。
set -uo pipefail
if [ ! -d "$HOME/workspace/setup" ] && [ -d /home/hatch/workspace/setup ]; then
  export HOME=/home/hatch
fi
SETUP_DIR="$HOME/workspace/setup"
LOG="$SETUP_DIR/logs/watchdog.log"
export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# 单实例（原子 mkdir）
LOCKDIR="$SETUP_DIR/.wx-watchdog.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then exit 0; fi
trap 'rm -rf "$LOCKDIR"' EXIT

WECHAT_BIN="$(readlink -f "$(command -v wechat 2>/dev/null || echo /opt/wechat/wechat)" 2>/dev/null || echo /opt/wechat/wechat)"
WX_PAT="${WECHAT_BIN%/*}/[w]echat"

if ! pgrep -f "[X]vfb.*:99" >/dev/null 2>&1 || ! pgrep -f "$WX_PAT" >/dev/null 2>&1; then
  log "检测到 Xvfb 或微信进程缺失，触发 restore"
  bash "$SETUP_DIR/restore-wechat.sh" >>"$LOG" 2>&1
  if pgrep -f "$WX_PAT" >/dev/null 2>&1; then
    log "restore 后微信在跑"
  else
    log "WARN: restore 后仍无微信进程，看 wechat-restore.log"
  fi
else
  log "巡检正常"
fi
```

## 步骤 6：Layer 2b — 平台开机钩子（重建后自动恢复的关键）

### ① 🤖 AI 执行（命令）

```bash
mkdir -p /home/hatch/hooks/definitions /home/hatch/hooks/scripts /home/hatch/hooks/state /home/hatch/hooks/logs
# 落盘三个文件（代码见下），然后：
chmod +x /home/hatch/hooks/scripts/wechat-init.sh
chmod 700 /home/hatch/init.sh
ls -l /home/hatch/hooks/definitions/wechat-init.json /home/hatch/hooks/scripts/wechat-init.sh /home/hatch/init.sh
jq -e '.enabled == true and .poll_interval_secs == 60' /home/hatch/hooks/definitions/wechat-init.json
bash -n /home/hatch/hooks/scripts/wechat-init.sh && echo "wechat-init.sh 语法 OK"
bash -n /home/hatch/init.sh && echo "init.sh 语法 OK"
```

### ② 💬 对用户说

> 🔌 最关键的一层：开机钩子。沙盒每次重建启动后会自动跑一次恢复脚本，把微信从缓存装回并拉起——这就是"重启后微信自己回来"的机制。如果平台弹出权限提示（注册钩子 / root 执行），请点允许。

### ③ 🙋 用户手动做

- 平台弹权限提示时点允许。

### ④ ✅ 做完的标志

- 三个文件都在、权限对（`init.sh` 为 `-rwx------`）、`jq` 断言通过、语法 OK。

### ⑤ 🛠️ 常见失败与处理

| 现象                     | 原因                          | 处理                                                    |
| ------------------------ | ----------------------------- | ------------------------------------------------------- |
| 钩子不跑                 | `init.sh` 没有执行位（700）   | `chmod 700 /home/hatch/init.sh`——这是启用开关           |
| 脚本报 HATCH_HOOK_RUNTIME 未设置 | 不是被平台调用       | 正常：保留 `source "${HATCH_HOOK_RUNTIME:?}"`，由平台调 |
| 钩子每次都跑             | `/run` 标记被清（重启即清）   | 这正是"每次启动恰好一次"的实现，正常                    |

### 代码 1/3：`/home/hatch/hooks/definitions/wechat-init.json`（钩子注册）

```json
{
  "created_at_ms": 0,
  "delivery": { "surface": "main" },
  "enabled": true,
  "id": "wechat-init",
  "poll_interval_secs": 60,
  "prompt": "WeChat persistence restore hook. Its script always returns silent.",
  "script_path": "/home/hatch/hooks/scripts/wechat-init.sh",
  "script_timeout_secs": 600,
  "updated_at_ms": 0,
  "version": 1
}
```

### 代码 2/3：`/home/hatch/hooks/scripts/wechat-init.sh`（钩子脚本）

```bash
#!/bin/bash
set -e
umask 077
source "${HATCH_HOOK_RUNTIME:?}"
[[ "${HATCH_HOOK_DRY_RUN:-0}" == 1 ]] && silent "dry-run"
[[ -x /home/hatch/init.sh ]] || silent "waiting for init.sh"
mkdir -p /run/hatch-wechat-init
exec 9>/run/hatch-wechat-init/lock
flock -n 9 || silent "running"
[[ ! -e /run/hatch-wechat-init/started ]] || silent "already run"
cd /home/hatch
{
    touch /run/hatch-wechat-init/started  # 每次启动只尝试一次，失败不重跑（兜底交给看门狗/巡检）
    printf '\n[%s] wechat-init started\n' "$(date -Is)"
    /bin/bash ./init.sh 9>&- </dev/null && rc=0 || rc=$?
    printf '[%s] init exited: %s\n' "$(date -Is)" "$rc"
} >>/tmp/wechat-init.log 2>&1
silent "done"
```

### 代码 3/3：`/home/hatch/init.sh`（开机命令，必须 700 才生效）

```bash
#!/bin/bash
# /home/hatch/init.sh — 平台开机钩子入口：每次沙盒启动后自动运行一次。
# 运行身份为 root，工作目录 /home/hatch。必须可执行（chmod 700）才会生效。
# 失败不重试；兜底由沙盒内看门狗（每分钟）负责。
set -euo pipefail

if [ ! -d "${HOME:-}/workspace/setup" ] && [ -d /home/hatch/workspace/setup ]; then
  export HOME=/home/hatch
fi

RESTORE=/home/hatch/workspace/setup/restore-wechat.sh
if [[ ! -x "$RESTORE" ]]; then
  echo "ERROR: $RESTORE 缺失或不可执行" >&2
  exit 1
fi

exec "$RESTORE"
```

## 步骤 7：（可选）Layer 2a — 平台定时巡检

开机钩子"每次启动只跑一次、失败不重试"。加一层平台巡检做兜底：跑在沙盒外面，重建也杀不死。

### ① 🤖 AI 执行（命令）

先落盘健康检查脚本（代码见下），再由**平台侧**创建定时任务（沙盒内 Agent 没有平台任务工具时，把下面的任务定义交给用户/平台侧执行）：

- 任务 id：`wechat-keepalive-monitor`
- 周期：每 5 分钟
- 超时：600 秒
- 执行提示词（原文照搬）：

```text
你是微信持久化巡检员。每轮只做以下步骤：
1. 用 exec 运行 bash ~/workspace/setup/wechat-health-check.sh，看退出码。
2. 退出码 0（健康）：什么都不做，不给用户发任何消息。
3. 退出码 1（Xvfb 或微信进程缺失）：
   a. 后台执行 bash ~/workspace/setup/restore-wechat.sh 并等待完成（脚本幂等，可安全重跑，内部有锁）。
   b. 完成后重跑 health-check 验证。
   c. 恢复成功：给用户发一条简短中文通知（检测到什么、已恢复）。
   d. 恢复失败：把 ~/workspace/setup/logs/wechat-restore.log 尾部错误报告用户，等用户指示，不要自己反复重试。
4. 退出码 2 或 exec 连不上沙盒：本轮跳过，下轮再试。
铁律：绝不删除、清空、覆盖 ~/.xwechat；健康时保持静默。
```

### ② 💬 对用户说

> ⏰（可选）加一层平台级巡检兜底，每 5 分钟检查一次，防止开机钩子偶发失败后没人管。你在平台端确认创建即可；不想加也行，看门狗 + 开机钩子已覆盖绝大多数情况。

### ③ 🙋 用户手动做

- 平台端确认创建定时任务（如弹授权卡片，点允许）。

### ④ ✅ 做完的标志

```bash
bash ~/workspace/setup/wechat-health-check.sh; echo "rc=$?"   # 期望 0
```
加上平台任务列表里能看到该任务且状态启用。

### 代码：`wechat-health-check.sh`

**目标路径**：`~/workspace/setup/wechat-health-check.sh`　**权限**：`chmod +x`

```bash
#!/usr/bin/env bash
# wechat-health-check.sh — 退出码契约：0=健康 1=需恢复 2=环境异常
if [ ! -d "$HOME/workspace/setup" ] && [ -d /home/hatch/workspace/setup ]; then
  export HOME=/home/hatch
fi
SETUP_DIR="$HOME/workspace/setup"
[ -f "$SETUP_DIR/restore-wechat.sh" ] || { echo "ENV_BAD: 无恢复脚本"; exit 2; }

WECHAT_BIN="$(readlink -f "$(command -v wechat 2>/dev/null || echo /opt/wechat/wechat)" 2>/dev/null || echo /opt/wechat/wechat)"
WX_PAT="${WECHAT_BIN%/*}/[w]echat"

fail=""
pgrep -f "[X]vfb.*:99" >/dev/null 2>&1 || fail="$fail xvfb"
pgrep -f "$WX_PAT" >/dev/null 2>&1 || fail="$fail wechat"
if [ -z "$fail" ]; then
  echo "OK"
  exit 0
fi
echo "NEED_RESTORE:$fail"
exit 1
```

---

# 收尾｜验证与演练（步骤 8–9）

## 步骤 8：端到端验证清单

### ① 🤖 AI 执行（命令）

```bash
echo "=== 1. 恢复脚本可用 ==="
bash -n ~/workspace/setup/restore-wechat.sh && echo 语法OK
bash ~/workspace/setup/wechat-health-check.sh; echo "rc=$?（期望 0）"

echo "=== 2. 看门狗 cron ==="
crontab -l | grep wechat-watchdog

echo "=== 3. 微信进程 ==="
WECHAT_BIN="$(readlink -f "$(command -v wechat 2>/dev/null || echo /opt/wechat/wechat)" 2>/dev/null || echo /opt/wechat/wechat)"
pgrep -af "${WECHAT_BIN%/*}/[w]echat" && echo "微信在跑" || echo "微信未在跑"

echo "=== 4. Xvfb ==="
pgrep -af "[X]vfb.*:99" && echo "Xvfb 在跑" || echo "Xvfb 未在跑"

echo "=== 5. 数据目录完好 ==="
du -sh ~/.xwechat

echo "=== 6. 开机钩子 ==="
jq -e '.enabled == true' /home/hatch/hooks/definitions/wechat-init.json >/dev/null && echo "钩子已启用"
ls -l /home/hatch/init.sh | grep -q '^-rwx------' && echo "init.sh 权限 700"

echo "=== 7. 离线缓存 ==="
ls ~/workspace/installers/deb-cache/*.deb | wc -l
ls -l ~/workspace/installers/WeChatLinux_x86_64.deb
```

### ② 💬 对用户说

> 🏁 部署完成。最后建议做一次**真实重建演练**：等下次平台重建（或你主动触发一次重启），观察微信是否在开机后约 2 分钟内自动回来、且**不需要重新扫码授权**。我可以把验证结果整理给你。

### ③ 🙋 用户手动做

- 决定是否做重建演练；演练时观察微信是否自动恢复。

### ④ ✅ 做完的标志

清单 7 项全部符合期望。

## 步骤 9：重建演练（可选但强烈推荐）

等一次真实的平台重建发生后（或用户主动触发），检查：

```bash
grep -E '微信恢复开始|微信恢复完成' ~/workspace/setup/logs/wechat-restore.log | tail -4
cat /tmp/wechat-init.log 2>/dev/null | tail -5
bash ~/workspace/setup/wechat-health-check.sh; echo "rc=$?（期望 0）"
```

判据：`wechat-init.log` 有本次启动的记录 → `wechat-restore.log` 有完整的"开始 → 完成"→ 健康检查 0 → 微信进程在跑且**无需重新扫码**（个别情况微信安全策略会要求手机上点一次"确认登录"，点一下即可，无需扫码重登）。

---

## 铁律（违反必出事）

1. **`~/.xwechat` 是红线**：任何脚本、任何步骤绝不删除、清空、覆盖它。只重装程序、重启进程。
2. **一切幂等**：所有脚本先判断再动手；重复执行必须安全。
3. **重建后先等 dpkg 锁**：平台 reconciliation 可能占锁最多 10 分钟，直接 dpkg 必失败。
4. **进程匹配用完整路径 + 中括号技巧**（`/opt/wechat/[w]echat`）：脚本自身名字里就含 "wechat"，裸 `pgrep -f wechat` 会误配到自己。
5. **不自动批准任何平台审批卡片**：这是与上游 muse-guardian 的根本区别。弹卡让用户手点，一次即永久放行。
6. **离线缓存是底线**：平台换基础镜像、或微信升级换 deb 后，重做步骤 2 的闭包缓存。
7. **微信启动序列以实测为准**：你有此前验证过的启动命令就用它，并回写进 `restore-wechat.sh`，别迷信本手册的参考实现。
8. **写 crontab 一律"临时文件中转"**：空表时 `crontab -l` 退出 1，配合 `set -euo pipefail` 的管道会静默杀掉整个流程——这是实战演练抓出的最严重 bug。
9. **离线闭包要容忍互斥替代品**：`opensysusers` 与 `systemd-standalone-sysusers` 互斥且系统 systemd 已提供等价能力；安装时逐包重试、冲突记跳过，不要整批判失败。

## 已知边界（诚实清单）

1. **微信自身的设备安全策略不受我们控制**：数据目录保留时，绝大多数情况免登录直接恢复；偶发风控会要求手机微信上点一次"确认登录"（点一下即可，不用扫码）。这是腾讯侧策略，无法从服务器端保证 100% 永不弹。
2. **开机钩子机制随平台版本可能变化**（本方案沿用 Muse/hatch 已实测的形态：`/home/hatch/hooks/definitions/` + `init.sh` 700）。若钩子失效，退化到"看门狗 + 平台巡检"两层，恢复会慢一些但仍有兜底。
3. **依赖闭包基于当前镜像**：平台更换基础镜像后部分包版本对不上，需联网重做步骤 2。
4. **Xvfb 无声卡、无 GPU**：微信的音视频通话不可用属正常（不在本手册范围）。
5. **长期挂机是否符合平台使用条款**，由用户自行评估；本方案不含任何绕过平台审批/风控的组件。
