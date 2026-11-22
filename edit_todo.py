#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从桌面小组件编辑企业微信待办：标记完成 / 修改截止时间 / 重新打开。

用法：
    edit_todo.py finish   <todo_id> [all]
    edit_todo.py deadline <todo_id> <YYYY-MM-DD | "YYYY-MM-DD HH:MM:SS" | none>
    edit_todo.py reopen   <todo_id>
    edit_todo.py rename   <todo_id> <新标题>
    edit_todo.py delete   <todo_id>

关于 reopen：企业微信的待办完成是**单向不可逆**的，实测三条路全封死
    finish 传 finished_all=false -> 「待办已被完成过」
    update 传 status / user_status -> 「存在未知字段」
所以「恢复到未完成」只能按原标题、原截止时间新建一条未完成的待办，
再把那条已完成的删掉（先建新、后删旧：顺序反过来一旦新建失败就把数据弄丢了）。
代价是它变成一条全新待办，完成时间与参与人历史不保留。

成功后乐观合并进 data.json，小组件 3 秒内自动刷新显示，不必等全量刷新。
失败时把企业微信的原始原因打出来（例如 860024 仅待办创建者可更新），
供小组件在底部状态栏直接展示，不做任何粉饰。
"""

import json
import os
import re
import sys
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, BASE)

from fetch_data import OUT_PATH, TIME_FMT, WecomError, run_cli  # noqa: E402

# 改标题/删除同样受「仅创建者可改」限制（实测 860024），
# 所以这两项只对小组件（机器人）建的待办有效。

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DT_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(:\d{2})?$")


def api_error(res):
    """企业微信的错误有两种形态：顶层 errcode，或嵌套的 error 对象。"""
    err = res.get("error")
    if isinstance(err, dict):
        code = err.get("code")
        msg = (err.get("message") or "").split(" (callid")[0].strip()
        return "%s%s" % (("%s " % code) if code else "", msg or "接口返回错误")
    return None


def load_payload():
    try:
        with open(OUT_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_payload(payload):
    tmp = OUT_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    os.replace(tmp, OUT_PATH)


def patch_local(todo_id, changes):
    """把改动合进本地 data.json；找不到对应条目就什么都不做（下次全量刷新会校准）。"""
    payload = load_payload()
    if not payload:
        return
    todos = payload.get("todos") or []
    hit = False
    for t in todos:
        if t.get("todo_id") == todo_id:
            t.update(changes)
            t["update_time"] = datetime.now().strftime(TIME_FMT)
            hit = True
    if not hit:
        return
    payload["todos"] = todos
    payload["generated_at"] = datetime.now().strftime(TIME_FMT)
    save_payload(payload)


def do_finish(todo_id, finished_all):
    body = {"items": [{"todo_id": todo_id, "finished_all": bool(finished_all)}]}
    try:
        res = run_cli(["todo", "finish", "--json", json.dumps(body, ensure_ascii=False)])
    except WecomError as e:
        print("企业微信未接受：%s" % e)
        return 1

    e = api_error(res)
    if e:
        print("企业微信未接受：%s" % e)
        return 1

    items = res.get("items") or []
    r = items[0] if items else {}
    if not r.get("success"):
        print("企业微信未接受：%s" % (r.get("errmsg") or "未知错误"))
        return 1

    # finished_all=True 表示整体完成；否则只完成自己那份，
    # 但对他本人的待办而言效果一样：这条待办在他列表里就是做完了
    patch_local(todo_id, {"status": "finished", "user_status": "finished"})
    return 0


def do_deadline(todo_id, value):
    if value in ("none", "none-", "", "无"):
        deadline = {"type": "date", "value": ""}
        local = {"deadline": "", "deadline_type": "", "date": ""}
        tip = "已清除截止时间"
    elif DATE_RE.match(value):
        deadline = {"type": "date", "value": value}
        local = {"deadline": value, "deadline_type": "date", "date": value}
        tip = "已改到 " + value
    elif DT_RE.match(value):
        v = value if len(value) == 19 else value + ":00"
        deadline = {"type": "datetime", "value": v}
        local = {"deadline": v, "deadline_type": "datetime", "date": v[:10]}
        tip = "已改到 " + v[:16]
    else:
        print("时间格式不对：%s（要 YYYY-MM-DD 或 YYYY-MM-DD HH:MM，或 none）" % value)
        return 2

    body = {"items": [{"todo_id": todo_id, "deadline": deadline}]}
    try:
        res = run_cli(["todo", "update", "--json",
                       json.dumps(body, ensure_ascii=False)])
    except WecomError as e:
        print("企业微信未接受：%s" % e)
        return 1

    e = api_error(res)
    if e:
        print("企业微信未接受：%s" % e)
        return 1

    items = res.get("items") or []
    r = items[0] if items else {}
    if not r.get("success"):
        print("企业微信未接受：%s" % (r.get("errmsg") or "未知错误"))
        return 1

    patch_local(todo_id, local)
    print(tip)
    return 0


def find_local(todo_id):
    payload = load_payload()
    if not payload:
        return None
    for t in (payload.get("todos") or []):
        if t.get("todo_id") == todo_id:
            return t
    return None


def replace_local(old_todo_id, new_todo):
    """本地把已完成那条换成新建的那条（乐观合并，随后仍会有一次全量刷新校准）。"""
    payload = load_payload()
    if not payload:
        return
    todos = [t for t in (payload.get("todos") or []) if t.get("todo_id") != old_todo_id]
    todos.insert(0, new_todo)
    payload["todos"] = todos
    payload["generated_at"] = datetime.now().strftime(TIME_FMT)
    save_payload(payload)


def bot_created(item):
    """这条待办是不是机器人（也就是小组件）建的。

    企微对接口创建的待办不返回 source，全量刷新后本地那条 "桌面小组件" 标记会被空值覆盖，
    所以只能再认一遍创建者名（机器人固定叫「XX的机器人」）。
    """
    return (item.get("source") or "") == "桌面小组件" or (item.get("creator") or "").endswith("机器人")


def do_reopen(todo_id):
    old = find_local(todo_id)
    if old is None:
        print("本地没有这条待办，点 ↻ 刷新后再试")
        return 2
    if not bot_created(old):
        print("企业微信限制：只有创建者能删，这条是「%s」建的，需到企微客户端处理"
              % (old.get("creator") or "企微客户端"))
        return 3

    title = (old.get("title") or "").strip()
    if not title:
        print("这条待办没有标题，无法重建")
        return 2

    item = {"title": title}
    desc = (old.get("description") or "").strip()
    if desc:
        item["description"] = desc
    d_type = old.get("deadline_type") or ""
    d_value = (old.get("deadline") or "").strip()
    if d_value and d_type in ("date", "datetime"):
        if d_value[:10] < datetime.now().strftime("%Y-%m-%d"):
            # 已经过期的一律降级成「只有日期」：带一个过去的时刻容易让企微当场弹提醒
            item["deadline"] = {"type": "date", "value": d_value[:10]}
        elif d_type == "datetime":
            item["deadline"] = {"type": "datetime", "value": d_value}
        else:
            item["deadline"] = {"type": "date", "value": d_value[:10]}

    # 1) 先建新的未完成待办
    try:
        res = run_cli(["todo", "create", "--json",
                       json.dumps({"items": [item]}, ensure_ascii=False)])
    except WecomError as e:
        print("重新打开失败（新建未成功，原记录未动）：%s" % e)
        return 1
    if api_error(res):
        print("重新打开失败（新建未成功，原记录未动）：%s" % api_error(res))
        return 1
    r = (res.get("items") or [{}])[0]
    if not r.get("success"):
        print("重新打开失败（新建未成功，原记录未动）：%s" % (r.get("errmsg") or "未知错误"))
        return 1

    now = datetime.now().strftime(TIME_FMT)
    new_dl = item.get("deadline") or {}
    new_value = (new_dl.get("value") or "").strip()
    new_type = (new_dl.get("type") or "").strip()
    new_todo = {
        "todo_id": r.get("todo_id") or "",
        "title": title,
        "status": "proceed",
        "user_status": "accept",
        "deadline": new_value,
        "deadline_type": new_type,
        "date": new_value[:10],
        "creator": old.get("creator") or "",
        "followers": [],
        "source": "桌面小组件",
        "description": desc,
        "create_time": now,
        "update_time": now,
    }

    # 2) 再删旧的已完成记录；删不掉也不能装作成功，否则会留下两条同名待办
    del_msg = ""
    try:
        dres = run_cli(["todo", "delete", "--json",
                        json.dumps({"items": [{"todo_id": todo_id}]}, ensure_ascii=False)])
    except WecomError as e:
        dres = None
        del_msg = str(e)
    else:
        e = api_error(dres)
        dr = (dres.get("items") or [{}])[0]
        if e:
            del_msg = e
        elif not dr.get("success"):
            del_msg = dr.get("errmsg") or "删除失败"

    if del_msg:
        replace_local(todo_id, new_todo)   # 新条目先进列表，旧条目保留，让他看得见重复
        print("已新建未完成的「%s」，但旧的已完成记录没删掉：%s（企微里会短暂出现两条同名待办）"
              % (title, del_msg))
        return 0

    replace_local(todo_id, new_todo)
    if new_value and new_value[:10] < datetime.now().strftime("%Y-%m-%d"):
        print("已重新打开 · 原截止 %s 已过，会显示逾期" % new_value[:10])
    else:
        print("已重新打开" + (" · 截止 " + new_value[:16] if new_value else ""))
    return 0


def do_rename(todo_id, title):
    """改标题。企微 update 接口的物品字段都是可选的，只传 title 即可（实测通过）。"""
    title = (title or "").strip()
    if not title:
        print("标题不能为空")
        return 2
    if len(title) > 200:
        print("标题太长了（企业微信限制 200 字以内）")
        return 2

    body = {"items": [{"todo_id": todo_id, "title": title}]}
    try:
        res = run_cli(["todo", "update", "--json", json.dumps(body, ensure_ascii=False)])
    except WecomError as e:
        print("企业微信未接受：%s" % e)
        return 1

    e = api_error(res)
    if e:
        print("企业微信未接受：%s" % e)
        return 1

    items = res.get("items") or []
    r = items[0] if items else {}
    if not r.get("success"):
        print("企业微信未接受：%s" % (r.get("errmsg") or "未知错误"))
        return 1

    patch_local(todo_id, {"title": title})
    print("已改名为「%s」" % title)
    return 0


def drop_local(todo_id):
    payload = load_payload()
    if not payload:
        return
    todos = [t for t in (payload.get("todos") or []) if t.get("todo_id") != todo_id]
    payload["todos"] = todos
    payload["generated_at"] = datetime.now().strftime(TIME_FMT)
    save_payload(payload)


def do_delete(todo_id):
    """删除待办。企微同样只允许创建者删（860024 的另一种触发场景）。"""
    body = {"items": [{"todo_id": todo_id}]}
    try:
        res = run_cli(["todo", "delete", "--json", json.dumps(body, ensure_ascii=False)])
    except WecomError as e:
        print("企业微信未接受：%s" % e)
        return 1

    e = api_error(res)
    if e:
        print("企业微信未接受：%s" % e)
        return 1

    items = res.get("items") or []
    r = items[0] if items else {}
    if not r.get("success"):
        print("企业微信未接受：%s" % (r.get("errmsg") or "未知错误"))
        return 1

    drop_local(todo_id)
    print("已从企业微信和小组件里删除")
    return 0


def main():
    if len(sys.argv) < 3:
        print("用法: edit_todo.py finish <todo_id> [all] | deadline <todo_id> <日期|时间|none>"
              " | reopen <todo_id> | rename <todo_id> <新标题> | delete <todo_id>")
        return 2

    action, todo_id = sys.argv[1].strip(), sys.argv[2].strip()
    if not todo_id:
        print("缺少 todo_id：这条待办没有企业微信 ID，请点一次「刷新」后再试")
        return 2

    if action == "finish":
        return do_finish(todo_id, (sys.argv[3].strip() == "all") if len(sys.argv) > 3 else False)
    if action == "deadline":
        if len(sys.argv) < 4:
            print("缺少截止时间")
            return 2
        return do_deadline(todo_id, sys.argv[3].strip())
    if action == "reopen":
        return do_reopen(todo_id)
    if action == "rename":
        if len(sys.argv) < 4:
            print("缺少新标题")
            return 2
        return do_rename(todo_id, sys.argv[3])
    if action == "delete":
        return do_delete(todo_id)

    print("未知操作：%s" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main())
