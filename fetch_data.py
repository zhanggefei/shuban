#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
拉取企业微信「日程」+「待办」，归一化为桌面小组件可读的 data.json。

设计要点：
1. 单个模块拉取失败（如机器人权限过期 errcode 850003）时，只记录错误并沿用
   上一次 data.json 里该模块的旧数据，绝不用空数组覆盖，避免小组件"变空"。
2. 输出文件先写 .tmp 再原子替换，防止小组件读到写了一半的 JSON。
3. 输出中不包含任何企微内部 ID（schedule_id / todo_id / userid），只保留展示字段。
"""

import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timedelta

BASE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(BASE, "data")
OUT_PATH = os.path.join(DATA_DIR, "data.json")
TIME_FMT = "%Y-%m-%d %H:%M:%S"

# 已完成待办只取最近的一批：历史完成项会无限累积，
# 全量拉回来每页都要一次 CLI 调用，刷新会越来越慢
DONE_MAX_PAGES = 5     # 最多翻 5 页（20 条/页）
DONE_KEEP = 60         # 按完成时间倒序后只留最近 60 条

# 待办来源枚举 -> 可读名称
SOURCE_MAP = {
    "single_chat": "单聊",
    "group_chat": "群聊",
    "doc": "文档",
    "ai_summary": "智能总结",
    "meeting_summary": "会议纪要",
    "face_chat": "面聊",
    "fused_doc": "融合文档",
    "smart_sheet": "智能表格",
    "smart_doc": "智能文档",
    "JSAPI": "接口创建",
}

REPEAT_MAP = {
    "daily": "每天",
    "weekly": "每周",
    "monthly": "每月",
    "monthly_on_the_nth_day": "每月",
    "yearly": "每年",
    "yearly_on_the_nth_day": "每年",
    "work_day": "工作日",
}


def extract_auth_url(help_message):
    """从 help_message 的 markdown 链接里取出最新授权地址"""
    import re
    m = re.search(r"\((https?://[^)\s]+)\)", help_message or "")
    return m.group(1) if m else ""


# ---------------------------------------------------------------- CLI 定位
# 坑：从 Finder / Dock 启动的小组件，PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin，
# 而 wecom-cli 装在 ~/.workbuddy/... 这类目录里，`subprocess(["wecom-cli"])` 直接
# FileNotFoundError → 两个模块全失败 → 数据被写成空（实测「点刷新就没数据」）。
# 所以这里不能只信 PATH：显式扫一遍常见安装位置，并把它们补进子进程 PATH
# （wecom-cli 的 shebang 是 `#!/usr/bin/env node`，找不到 node 同样会挂）。

_CLI_EXTRA_DIRS = [
    os.path.expanduser("~/.workbuddy/binaries/node/cli-connector-packages/bin"),
    os.path.expanduser("~/.workbuddy/binaries/node/versions"),
    os.path.expanduser("~/.workbuddy/binaries/node/versions/.locks/bin"),
    os.path.expanduser("~/.workbuddy/binaries/python/versions"),
    os.path.expanduser("~/.octop/bin"),
    os.path.expanduser("~/bin"),
    os.path.expanduser("~/.local/bin"),
    "/usr/local/bin",
    "/opt/homebrew/bin",
]

_cli_cache = {"path": None, "env": None}


def _version_bins(root):
    """~/.workbuddy/binaries/node/versions/<版本>/bin 这种带版本号的目录"""
    out = []
    try:
        for name in sorted(os.listdir(root), reverse=True):
            d = os.path.join(root, name, "bin")
            if os.path.isdir(d):
                out.append(d)
    except OSError:
        pass
    return out


def _cli_dirs():
    for d in _CLI_EXTRA_DIRS:
        if os.path.isdir(d):
            yield d
        sub = os.path.join(d, "versions")
        if os.path.isdir(sub):
            for vd in _version_bins(sub):
                yield vd


def resolve_cli():
    """返回 wecom-cli 的绝对路径；找不到返回 None。结果缓存。"""
    if _cli_cache["path"] is not None:
        return _cli_cache["path"]

    env = os.environ.copy()
    extra = [d for d in _cli_dirs()]
    if extra:
        env["PATH"] = os.pathsep.join(extra) + os.pathsep + env.get("PATH", "")

    explicit = os.environ.get("WECOM_CLI", "")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        found = explicit
    else:
        found = shutil.which("wecom-cli")
        if not found:
            # 用补全后的 PATH 再找一次（GUI 环境的 PATH 是残缺的）
            probe = env["PATH"].split(os.pathsep)
            found = next((os.path.join(d, "wecom-cli") for d in probe
                          if os.path.isfile(os.path.join(d, "wecom-cli"))), None)

    if found:
        _cli_cache["path"], _cli_cache["env"] = found, env
    return found


class WecomError(Exception):
    def __init__(self, errcode, errmsg, help_message=""):
        super().__init__("[%s] %s" % (errcode, errmsg))
        self.errcode = errcode
        self.errmsg = errmsg
        self.help_message = help_message
        self.auth_url = extract_auth_url(help_message)


def run_cli(args, timeout=90):
    """执行 wecom-cli，返回解析后的 results 字典。"""
    cli = resolve_cli()
    if not cli:
        raise WecomError("cli_missing",
                         "未找到 wecom-cli（已搜索 PATH 与 ~/.workbuddy、~/.octop、"
                         "/usr/local/bin 等常见位置），请先执行 npm install -g @wecom/cli")
    cmd = [cli] + args
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            env=_cli_cache["env"] or None,
        )
    except FileNotFoundError:
        raise WecomError("cli_missing", "未找到 wecom-cli，请先执行 npm install -g @wecom/cli")
    except subprocess.TimeoutExpired:
        raise WecomError("timeout", "wecom-cli 执行超时")

    raw = (proc.stdout or "").strip()
    if not raw:
        raise WecomError("empty", (proc.stderr or "wecom-cli 无输出").strip()[:300])

    # 输出可能含前置非 JSON 行，从第一个 '{' 开始截取
    start = raw.find("{")
    if start < 0:
        raise WecomError("parse", raw[:300])
    try:
        obj = json.loads(raw[start:])
    except json.JSONDecodeError as e:
        raise WecomError("parse", "JSON 解析失败: %s / %s" % (e, raw[:200]))

    errcode = obj.get("errcode", 0)
    if errcode not in (0, None):
        raise WecomError(errcode, obj.get("errmsg", ""), obj.get("help_message", ""))

    results = obj.get("results_json")
    if isinstance(results, str):
        try:
            results = json.loads(results)
        except json.JSONDecodeError:
            results = {}
    if not isinstance(results, dict):
        # 少数接口把数据平铺在顶层
        results = {k: v for k, v in obj.items() if k not in ("errcode", "errmsg", "help_instruction", "help_message")}
    return results or {}


def clean_names(items, key="name"):
    out = []
    for it in items or []:
        if isinstance(it, dict):
            n = (it.get(key) or it.get("user_name") or "").strip()
        else:
            n = str(it).strip()
        if n:
            out.append(n)
    return out


def _is_all_day(begin_time, end_time):
    """接口不返回 is_all_day，用 00:00:00 ~ 23:59:59 推导全天日程"""
    return begin_time.endswith("00:00:00") and end_time.endswith("23:59:59")


def _fetch_span(begin_dt, end_dt, sink, budget):
    """拉取一个时间片；命中 100 条上限时二分递归，直到取全"""
    if budget[0] <= 0:
        return
    budget[0] -= 1
    results = run_cli([
        "calendar", "schedules", "list", "--json",
        json.dumps({
            "begin_time": begin_dt.strftime(TIME_FMT),
            "end_time": end_dt.strftime(TIME_FMT),
        }, ensure_ascii=False),
    ])
    lst = results.get("schedule_list") or []
    span = (end_dt - begin_dt).total_seconds()
    # 服务端单次最多返回 100 条，满额且跨度够大就继续二分
    if len(lst) >= 100 and span > 86400 and budget[0] > 1:
        mid = begin_dt + (end_dt - begin_dt) / 2
        _fetch_span(begin_dt, mid, sink, budget)
        _fetch_span(mid + timedelta(seconds=1), end_dt, sink, budget)
        return
    for x in lst:
        key = x.get("schedule_id") or (str(x.get("subject")) + "|" + str(x.get("begin_time")))
        sink[key] = x


def fetch_schedules(begin_dt, end_dt):
    """按 7 天切片 + 满额二分，规避单次 100 条上限与服务端窗口限制"""
    raw = {}
    budget = [60]  # 单次刷新最多 60 次请求
    cur = begin_dt
    while cur < end_dt and budget[0] > 0:
        seg_end = min(cur + timedelta(days=7) - timedelta(seconds=1), end_dt)
        _fetch_span(cur, seg_end, raw, budget)
        cur = seg_end + timedelta(seconds=1)

    out = []
    for s in raw.values():
        begin_time = s.get("begin_time") or ""
        end_time = s.get("end_time") or ""
        meeting = s.get("meeting") or {}
        room = s.get("meeting_room") or {}
        repeat = s.get("repeat_rule") or {}
        calendar_name = (s.get("calendar_name") or "").strip()
        is_share = bool(s.get("is_share_cal"))

        repeat_label = ""
        if repeat.get("is_repeat"):
            base = REPEAT_MAP.get(repeat.get("repeat_type", ""), "周期")
            until = (repeat.get("repeat_until") or "").strip()
            if until:
                repeat_label = "%s · 截止 %s" % (base, until[:10])
            elif int(repeat.get("repeat_time") or 0) > 0:
                repeat_label = "%s · 共 %s 次" % (base, repeat.get("repeat_time"))
            else:
                repeat_label = base

        out.append({
            "subject": (s.get("subject") or "（无主题）").strip(),
            "begin": begin_time,
            "end": end_time,
            "all_day": _is_all_day(begin_time, end_time),
            "attendees": clean_names(s.get("attendees"), "name"),
            "location": (s.get("location") or "").strip(),
            "room": (room.get("meeting_room_name") or "").strip(),
            "is_meeting": bool((meeting.get("meeting_code") or "").strip()
                               or (meeting.get("meeting_link") or "").strip()),
            "creator": (s.get("creator_name") or "").strip(),
            "description": (s.get("description") or "").strip(),
            "repeat_label": repeat_label,
            "date": begin_time[:10],
            "calendar": calendar_name,
            "own": not is_share,
        })

    out.sort(key=lambda x: (x["begin"], x["subject"]))
    return out


def _todo_pages(status, max_pages):
    """按完成状态翻页拉待办原始条目（cursor 翻页，max_pages 防死循环）。"""
    items, cursor, page = [], None, 0
    while page < max_pages:
        body = {"status_filter": [status], "limit": 20}
        if cursor:
            body["cursor"] = cursor
        results = run_cli(["todo", "list", "--json", json.dumps(body, ensure_ascii=False)])
        batch = results.get("items") or []
        items.extend(batch)
        page += 1
        cursor = results.get("next_cursor")
        if not results.get("has_more") or not cursor:
            break
    return items


def _norm_todo(t):
    deadline = t.get("deadline") or {}
    dl_value = (deadline.get("value") or "").strip()
    creator = ((t.get("creator") or {}).get("user_name") or "").strip()
    return {
        # todo_id 供小组件回写（标记完成 / 改截止时间 / 重新打开）用；data.json 只存本机
        "todo_id": (t.get("todo_id") or "").strip(),
        "title": (t.get("title") or "（无标题）").strip(),
        "status": t.get("status") or "proceed",
        "user_status": t.get("user_status") or "",
        "deadline": dl_value,
        "deadline_type": deadline.get("type") or "",
        "date": dl_value[:10],
        "creator": creator,
        "followers": clean_names(t.get("followers"), "user_name"),
        "source": SOURCE_MAP.get(t.get("source") or "", ""),
        "description": (t.get("description") or "").strip(),
        "create_time": t.get("create_time") or "",
        "update_time": t.get("update_time") or "",
    }


def fetch_todos():
    """进行中 + 已完成。

    已完成单独限量并按完成时间倒序：用户历史完成过的待办会一直累积，
    全量拉回来既拖慢刷新（每页一次 CLI 调用），也会把「已完成」列表撑到没法看。
    """
    proceed = [_norm_todo(t) for t in _todo_pages("proceed", 50)]
    done = [_norm_todo(t) for t in _todo_pages("finished", DONE_MAX_PAGES)]

    done.sort(key=lambda x: x["update_time"], reverse=True)
    done = done[:DONE_KEEP]

    # 有截止时间的在前、按截止升序；无截止的按更新时间倒序排在后面
    proceed.sort(key=lambda x: (x["deadline"] == "", x["deadline"] or "", -(len(x["update_time"]))))
    # 进行中整体在前，已完成沉底（界面另有筛选，这里只是兜底顺序）
    return proceed + done


def load_previous():
    if not os.path.exists(OUT_PATH):
        return {}
    try:
        with open(OUT_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def guard_empty(fetch_fn, prev_items, prev_is_demo, module):
    """空结果保护：接口偶发会「成功返回 0 条」（实测一次刷新把 221 条日程刷成 0 条，
    小组件当场被清空）。上次有数据而这次为空时重试一次，仍为空则沿用旧数据。

    返回 (items, used_prev)；used_prev=True 表示本次未取到数据、用的是上次的。
    """
    items = fetch_fn()
    if items or prev_is_demo or not prev_items:
        return items, False
    time.sleep(1.5)
    items = fetch_fn()
    if items:
        return items, False
    return list(prev_items), True


def main():
    now = datetime.now()
    # 服务端限定「前后 30 天」，贴边（含时分秒越界）会静默返回空列表，故收紧到 29 天
    begin_dt = (now - timedelta(days=29)).replace(hour=0, minute=0, second=0, microsecond=0)
    end_dt = (now + timedelta(days=29)).replace(hour=23, minute=59, second=59, microsecond=0)

    prev = load_previous()
    prev_is_demo = bool(prev.get("demo"))
    errors = []

    # 日程
    try:
        schedules, sched_stale = guard_empty(
            lambda: fetch_schedules(begin_dt, end_dt),
            prev.get("schedules") or [], prev_is_demo, "日程")
        sched_ok = not sched_stale
        if sched_stale:
            errors.append({"module": "日程", "code": "EMPTY_RESULT",
                           "message": "日程接口返回空列表，已沿用上次数据",
                           "help": "", "url": "", "stale": True})
    except WecomError as e:
        # 上次是示例数据时一律不沿用，避免假数据冒充真实日程
        schedules = [] if prev_is_demo else (prev.get("schedules") or [])
        sched_ok = False
        errors.append({"module": "日程", "code": str(e.errcode), "message": str(e),
                       "help": e.help_message, "url": e.auth_url, "stale": bool(schedules)})

    # 待办
    try:
        todos, todo_stale = guard_empty(
            fetch_todos, prev.get("todos") or [], prev_is_demo, "待办")
        todo_ok = not todo_stale
        if todo_stale:
            errors.append({"module": "待办", "code": "EMPTY_RESULT",
                           "message": "待办接口返回空列表，已沿用上次数据",
                           "help": "", "url": "", "stale": True})
    except WecomError as e:
        todos = [] if prev_is_demo else (prev.get("todos") or [])
        todo_ok = False
        errors.append({"module": "待办", "code": str(e.errcode), "message": str(e),
                       "help": e.help_message, "url": e.auth_url, "stale": bool(todos)})

    # 最后一道闸：一条都没取到、而且确实是出了错（不是用户真的清空了），
    # 就绝不覆盖旧文件。否则会「刷一次空 → 下次沿用空 → 永远空」雪崩，
    # 这里遇到的就是这个：点一次刷新，界面全空且再也回不来。
    if not schedules and not todos and errors:
        print()
        print("!! 本次一条数据都没取到，已保留上次的数据文件不覆盖")
        for e in errors:
            print("   %s: %s" % (e["module"], e["message"]))
            if e.get("url"):
                print("   授权地址: %s" % e["url"])
        return 2

    payload = {
        "generated_at": now.strftime(TIME_FMT),
        "range_begin": begin_dt.strftime("%Y-%m-%d"),
        "range_end": end_dt.strftime("%Y-%m-%d"),
        "demo": False,
        "schedules_ok": sched_ok,
        "todos_ok": todo_ok,
        "schedules": schedules,
        "todos": todos,
        "errors": errors,
        # 沿用上次刷新成功的模块时间戳，便于界面提示"数据可能已过期"
        "prev_generated_at": prev.get("generated_at", ""),
    }

    os.makedirs(DATA_DIR, exist_ok=True)
    # 临时文件名必须带 pid：两个刷新撞在一起时（手动点 + 自动刷新）共用一个 .tmp，
    # 先跑完的那个 replace 成功后，后跑的 replace 直接 FileNotFoundError 崩掉。
    # 数据本身不会坏，但第二个进程会白跑一趟并报错。
    tmp = "%s.tmp.%d" % (OUT_PATH, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, ensure_ascii=False, indent=2)
        os.replace(tmp, OUT_PATH)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    print("写入 %s" % OUT_PATH)
    print("日程 %d 条 (%s) | 待办 %d 条 (%s)" % (
        len(schedules), "成功" if sched_ok else "失败-沿用旧数据",
        len(todos), "成功" if todo_ok else "失败-沿用旧数据"))
    for e in errors:
        print("!! %s: %s" % (e["module"], e["message"]))
        if e.get("url"):
            print("   授权地址: %s" % e["url"])
    return 0 if not errors else 2


if __name__ == "__main__":
    sys.exit(main())
