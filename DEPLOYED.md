# muse-app 部署实录（as-built）

> 本文件是作者真实部署的竣工实录与踩坑记录（可当案例研究读）；通俗版总说明见同目录 `README.md`。

> 记录时间：2026-09-28。目标环境：Muse.ai hatch 沙盒（x86_64 Ubuntu，家目录 `/home/hatch`，平台不定期重建、仅 `$HOME` 幸存）。
> 目标：重建后 Linux 微信自动恢复、登录态不丢、尽量免手机确认。

## 已部署组件（均为沙盒内 Agent 落盘的实测版）

| 组件 | 位置 | 要点 |
|---|---|---|
| 恢复脚本 v4.1（终版） | `~/workspace/setup/restore-wechat.sh` | HOME 加固、单实例锁（原子 mkdir + stale 回收）、dpkg 锁等待（≤10min）、整批离线闭包安装（失败逐包重试；互斥替代品如 opensysusers 记"跳过"，仅真装不上才 WARN）、cron 三连（装包/起守护/crontab 经临时文件幂等重写——避开 `crontab -l` 空表退出 1 被 pipefail 放大）、machine-id 回写（0d 段，基线 `machine-id.baseline`）、xshot 编译、Xvfb :99、清代理直连启动微信 |
| 看门狗 | `~/workspace/setup/wechat-watchdog.sh` | 每分钟判 `Xvfb :99` + `/opt/wechat/wechat` 进程，缺则调恢复脚本（锁互斥） |
| 沙盒内调度 | root crontab 每分钟 | 绝对路径调用看门狗；cron 包及依赖已入离线缓存，恢复脚本重建 |
| 平台调度 | 平台任务 `wechat-watchdog__interval@1m`（定义在 `~/workspace/goals/.../crons/minutely/`） | 跑在沙盒外、重建不死；健康静默，触发恢复/WARN 才通知用户 |
| 离线缓存 | `~/workspace/installers/deb-cache/`（142 包 145MB）+ `WeChatLinux_x86_64.deb` | 断网也能全量恢复 |
| 设备指纹基线 | `machine-id.baseline`（回写）、`hostname.baseline`（只记录不回写） | 机器身份指纹假设，待真实重建验证 |

**数据红线：`~/.xwechat`（微信登录态与聊天数据）任何环节绝不删除/清空/覆盖。**

**状态（2026-09-28）：竣工。** 模拟测试（"重建后 cron 缺失"全链路）抓出并修复两个 `set -euo pipefail` 管道类 bug：① 空表时 `crontab -l` 退出 1 → pipefail 杀掉子 shell → 装了个空 crontab 且整个脚本 rc=1（真重建场景的 showstopper）；② 离线闭包误含互斥替代品导致误报。修复后四点验收全绿（cron 包装回 / 守护在跑 / crontab 恰好 1 行 / 微信无影响），rc=0、无 WARN。仅待真实重建做终极验收。

## 双保险架构

- 进程挂了（机器还在）→ crontab 看门狗 1 分钟内拉起。
- 整机重建 → 平台任务 1 分钟内发现 → 恢复脚本：回写 machine-id → 离线装依赖+微信 → 起 Xvfb+微信 → 重建 cron 线。开机钩子方案经评估不采用（两层独立调度已够）。

## 真实重建后的验收三判据

1. 无人工干预，微信几分钟内自己回来（最多手机上点一次确认登录）；
2. `~/workspace/setup/logs/wechat-restore.log` 有完整"微信恢复开始 → 完成"链路；
3. `~/workspace/setup/logs/watchdog.log` 时间戳每分钟一条、无超过约 3 分钟的空窗。

## 待验证 / 已知边界

- machine-id 假设：重建后微信是否不再要求手机确认（仍要确认则继续查网卡 MAC 等其他指纹维度）。
- hostname 是否随重建变化（仅记录，未自动回写，怕干扰平台识别沙盒）。
- 回滚预案：恢复后若平台任务异常（不触发/历史断档），第一怀疑 machine-id 回写，去掉 0d 段观察。
- 每分钟平台任务 ≈ 1440 次/天 Agent 调用，消耗 Muse 额度；吃紧可放宽到 5 分钟（仅影响重建发现延迟）。
- 刻意不包含（合规边界）：不装 MuseAutoApprove、不自动批平台审批卡、不处理 muse.ai 凭据。

## 运维速查

```bash
tail -f ~/workspace/setup/logs/wechat-restore.log   # 恢复主日志
tail -f ~/workspace/setup/logs/watchdog.log         # 巡检日志
pgrep -f '[o]pt/wechat/wechat'                      # 微信进程
bash ~/workspace/setup/restore-wechat.sh            # 手动恢复（幂等）
# 微信升级：换新 deb 后必须重做依赖闭包缓存，否则重建后断网装不回
```
