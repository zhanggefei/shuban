#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从桌面小组件往企业微信写一条待办。

用法：
    add_todo.py <标题> ["YYYY-MM-DD" | "YYYY-MM-DD HH:MM[:SS]"]

不传时间串      => 建无截止时间的待办
只传日期        => deadline.type=date
传日期 + 时刻    => deadline.type=datetime（小组件会在到点前 30 分钟弹桌面提醒）
创建成功后直接把新条目合并进 data.json，小组件 3 秒内即可看到，
不必等一次全量刷新（全量刷新要拉十几段日程，慢）。
"""

import json
import os
import re
import sys
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

from fetch_data import OUT_PATH, TIME_FMT, WecomError, run_cli  # noqa: E402


def parse_when(raw):
    """把 "YYYY-MM-DD" / "YYYY-MM-DD HH:MM[:SS]" 归一成 (deadline_type, value, date)。"""
    raw = (raw or "").strip()
    if not raw:
        return "", "", ""
    parts = raw.split()
    day = parts[0]
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        raise ValueError("日期格式应为 YYYY-MM-DD：" + raw)
    if len(parts) == 1:
        return "date", day, day
    hm = parts[1]
    if re.fullmatch(r"\d{1,2}:\d{2}", hm):
        hm = hm + ":00"
    elif not re.fullmatch(r"\d{1,2}:\d{2}:\d{2}", hm):
        raise ValueError("时间格式应为 HH:MM 或 HH:MM:SS：" + raw)
    h, m, s = (int(x) for x in hm.split(":"))
    if not (0 <= h < 24 and 0 <= m < 60 and 0 <= s < 60):
        raise ValueError("时间超出范围：" + raw)
    value = "%s %02d:%02d:%02d" % (day, h, m, s)
    return "datetime", value, day


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("用法: add_todo.py <标题> [YYYY-MM-DD | 'YYYY-MM-DD HH:MM']")
        return 2

    title = sys.argv[1].strip()
    try:
        d_type, d_value, d_date = parse_when(sys.argv[2] if len(sys.argv) > 2 else "")
    except ValueError as e:
        print("创建失败：" + str(e))
        return 2

    item = {"title": title}
    if d_value:
        item["deadline"] = {"type": d_type, "value": d_value}

    try:
        res = run_cli(["todo", "create", "--json",
                       json.dumps({"items": [item]}, ensure_ascii=False)])
    except WecomError as e:
        print("创建失败：" + str(e))
        return 1

    items = res.get("items") or []
    r = items[0] if items else {}
    if not r.get("success"):
        print("创建失败：" + str(r.get("errmsg") or "未知错误"))
        return 1

    now = datetime.now().strftime(TIME_FMT)
    new_todo = {
        "todo_id": r.get("todo_id") or "",
        "title": title,
        "status": "proceed",
        "user_status": "accept",
        "deadline": d_value,
        "deadline_type": d_type,
        "date": d_date,
        "creator": "",
        "followers": [],          # 自己创建的待办不重复列自己，下次全量刷新会校准
        "source": "桌面小组件",
        "description": "",
        "create_time": now,
        "update_time": now,
    }

    try:
        with open(OUT_PATH, "r", encoding="utf-8") as f:
            payload = json.load(f)
    except Exception:
        payload = {"schedules": [], "todos": [], "errors": [], "demo": False,
                   "schedules_ok": False, "todos_ok": True, "generated_at": now}

    todos = payload.get("todos") or []
    todos.insert(0, new_todo)
    payload["todos"] = todos
    payload["generated_at"] = now

    tmp = OUT_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, OUT_PATH)

    tip = r.get("extra_info") or ""
    if d_type == "datetime":
        print("已同步到企业微信 · 提醒 %s" % d_value)
    elif d_type == "date":
        print("已同步到企业微信 · 截止 %s" % d_value)
    else:
        print("已同步到企业微信" + ("：" + tip if tip else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
