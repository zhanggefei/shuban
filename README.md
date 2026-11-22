<div align="center">

# 书办 · ShuBan

**常驻 macOS 桌面的办公小助手。贴到屏幕边就收成一条书脊，鼠标移过去立刻展开。**

当前接通企业微信的日程与待办；会持续往上叠能力，目标是把每天要看的、要办的事收在一个小窗口里。

<sub>macOS 13+ · Swift + SwiftUI · MIT License</sub>

<sub>名字取自「书办」——旧时官署里文案办理的那份差事。贴在屏幕边时它就像一根书脊，摊开是一桌待办。</sub>

</div>

![主界面](docs/screenshots/main.png)

---

## 它现在能做什么

| 能力 | 说明 |
| --- | --- |
| 月历 + 当日安排 | 点任意日期看那天的日程与待办，有安排的日子带圆点（红=日程/已过期，金=待办） |
| 待办列表 | 进行中 / 已完成两个视图，逾期直接标「已过期」，不再让你猜 |
| 行内新建待办 | 底部输入框回车即写入企业微信，可带提醒时间（只标日期或精确到分） |
| 行内编辑 | 勾完成、改截止时间、改名、删除，都在列表行尾「⋯」里，改完立刻落到企业微信 |
| 日程详情 | 会议时间、会议室、地点、参与人 |
| 自动同步 | 默认每 10 分钟静默拉一次；也可以点 ↻ 手动刷新 |
| 到点桌面提醒 | 盖在全屏应用之上，可推迟 1 小时 / 3 小时 / 1 天 / 3 天 / 1 周 |
| 贴边收起 | 贴上屏幕任一边就缩成 14pt 窄条，鼠标压到线上展开，移开立刻缩回 |
| 自由缩放 | 320–768 宽、430–1040 高，字号跟着等比缩放，宽扁和高瘦都不切内容 |
| 单实例 + 自启 | 重复启动会静默退出（避免提醒弹两遍）；可选登录自启 |

<table>
<tr>
<td width="50%"><img src="docs/screenshots/reminder.png" alt="到点提醒" /></td>
<td width="50%"><img src="docs/screenshots/peek.png" alt="贴边收起" /></td>
</tr>
<tr>
<td align="center"><sub>到点提醒：可直接推迟或完成</sub></td>
<td align="center"><sub>贴右边后的窄条：左边是原比例，右边放大 3 倍</sub></td>
</tr>
</table>

## 快速开始

**依赖**：macOS 13+、Xcode 命令行工具（`swiftc`）、Python 3、[企业微信 CLI](https://developer.work.weixin.qq.com/)（`wecom-cli`，用于取数）

先不接企业微信，用示例数据看界面：

```bash
git clone https://github.com/zhanggefei/shuban.git
cd shuban
python3 make_demo_data.py     # 写入一份示例数据（结构和真实数据一致）
./build.sh                    # 编译到 build/书办.app
open build/书办.app
```

接真实数据：

```bash
wecom-cli auth show           # 确认已授权（Status: authorized）
./refresh.sh                  # 拉取日程 + 待办，写入 data/data.json
```

> 企业微信机器人需要分别开通「日程」和「待办」的权限。权限没开时界面会显示 `850003` 并给出提示，不会把已有数据刷空。

开机自启（可选，会额外装一个 30 分钟的定时刷新，小组件自己已经每 10 分钟同步，一般不需要）：

```bash
./install_autostart.sh            # 安装
./install_autostart.sh uninstall  # 卸载
```

## 目录结构

```
build.sh              编译并打包成 .app（含 Info.plist、签名、图标）
refresh.sh            一键拉数据（补 PATH，解决从 Dock 启动找不到 wecom-cli）
fetch_data.py         调 wecom-cli 取日程/待办 → data/data.json
add_todo.py           新建待办（写企业微信 + 乐观合并本地快照）
edit_todo.py          完成 / 改截止 / 恢复未完成
make_demo_data.py     生成示例数据
install_autostart.sh  登录自启 + 定时刷新（LaunchAgent）
src/main.swift        主面板、日历、待办、贴边收起、自动同步
src/Reminder.swift    桌面提醒窗口
data/data.json        本地数据快照（不入库）
```

## 几个绕不开的设计取舍

这些是踩了坑之后定下来的，改之前值得先读一遍：

1. **不用 WidgetKit，自建 NSPanel 浮窗。** WidgetKit 的沙箱里调不了企业微信 CLI，只能靠主 App 取数；而小组件要的是「随时可点、可输入、可提醒」，浮窗反而更合适。
2. **窗口尺寸自己存（`wecal.frame`），不用 `setFrameAutosaveName`。** NSWindow 的 autosave 在每次 frame 变化时都写，收缩成 14pt 窄条那一刻也会写进去 —— 退出时正收着，下次启动窗口就只有 14 像素宽。现在只在展开态保存，并设了宽高下限。
3. **界面必须有时间驱动。** SwiftUI 的 body 只在 `@Published` 变化时重算，`Date()` 算出来的「已过期」不会自己翻新。所以每 5 秒推一次 `clock`，所有时效性文案都读它。
4. **接口偶发返回空要挡住。** 有数据变没数据时先重试一次，仍为空就沿用上次快照并标记 `stale`；全部模块都失败时干脆不覆盖旧文件 —— 否则一次异常刷新能让界面永久变空。
5. **提醒扫描窗口收得很窄（`-600s, +2s`）。** 轮询 5 秒一次，宁可错过 10 分钟内补发，也不要提前弹。
6. **单实例闸门按 bundle id 比对 pid。** 已提醒记录只在启动时读一次，两份进程各持一份就会同一条提醒弹两遍。

## 调试与离屏验收开关

没有 GUI 自动化也能验界面，全部走环境变量（因为透明浮窗在锁屏/无头环境里截不到图）：

| 变量 | 作用 |
| --- | --- |
| `WECAL_SIZE=384x560` | 指定内容尺寸启动 |
| `WECAL_SNAP_MAIN=/tmp/m.png` | 把主面板离屏渲染成 PNG，配合 `_FRAMES` / `_STEP` 连拍 |
| `WECAL_SNAP_WINDOWS=/tmp/w.png` | 逐个可见窗口拍图（弹层是独立窗口，主面板钩子拍不到） |
| `WECAL_SNAP=/tmp/r.png` | 拍提醒卡 |
| `WECAL_TEST_REMINDER=1\|2` | 启动即弹日程卡 / 待办卡 |
| `WECAL_OPEN_PANEL=1\|2` | 启动即打开改期面板（只标日期 / 带时刻） |
| `WECAL_PEEK_TEST=1\|2\|3` | 贴边收起：贴右 / 收起再展开 / 贴顶（验窄条版式） |
| `WECAL_PEEK_TEST=4` | 用假坐标跑贴边几何判定的用例表（真机鼠标伪造不了，但规则能钉死） |
| `WECAL_SYNC_MINUTES=3` | 覆盖自动同步间隔 |
| `WECAL_ALLOW_MULTI=1` | 放行多实例（验收时需要同时跑两份） |

## 路线图

- [ ] **审批（只读）** —— 需要企业自建应用 + 审批数据权限 + 可信 IP 才能调 `oa/getapprovalinfo`
- [ ] 邮件摘要：未读重要邮件进副面板
- [ ] 会议开始前 N 分钟自动提示，一键进会议
- [ ] 更多数据源按同一套 `data.json` 契约接入

## 隐私

- 数据只存在你本机的 `data/data.json`，除企业微信官方接口外不做任何上传。
- 仓库里不含任何真实日程、待办或人名，`data/` 与日志都在 `.gitignore` 里；示例数据是脚本生成的占位内容。

## 许可证

[MIT](LICENSE) —— 随便用，商用、改、二次分发都行，保留版权声明即可。

个人项目，作者 **zhanggefei@126.com**。如果它对你有用，**点个 ⭐ 就是最好的鼓励**。
