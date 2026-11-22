#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成一份示例数据，用于企业微信权限未就绪时预览「书办」的界面排版。

用法：python3 make_demo_data.py    然后 ./build.sh && open build/书办.app
真实数据刷新（./refresh.sh）成功后会覆盖本文件生成的内容。

这些条目是刻意挑过的，一条数据看全所有排版分支：
已过期待办 / 今天截止（带时刻）/ 只标日期 / 无截止 / 已完成口径 /
会议（带会议室）与非会议（带地点）日程 / 每周重复 / 多参与人。
"""
import json, os
from datetime import datetime, timedelta

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(BASE, "data", "data.json")
today = datetime.now()


def d(offset, hm):
    return ((today + timedelta(days=offset)).strftime("%Y-%m-%d") + " " + hm + ":00")


schedules = [
    {"subject": "团队晨会", "begin": d(-2, "09:00"), "end": d(-2, "09:30"), "all_day": False,
     "attendees": ["li si(李四)", "wang wu(王五)"], "location": "", "room": "1605",
     "is_meeting": True, "creator": "zhang san(张三)", "description": "", "repeat_label": "每周一次", "date": d(-2, "00:00")[:10]},
    {"subject": "示例客户 A · 续约方案沟通", "begin": d(0, "10:30"), "end": d(0, "11:30"), "all_day": False,
     "attendees": ["zhao liu(赵六)", "sun qi(孙七)"], "location": "客户现场", "room": "",
     "is_meeting": False, "creator": "zhang san(张三)", "description": "", "repeat_label": "", "date": d(0, "00:00")[:10]},
    {"subject": "新产品 功能培训", "begin": d(0, "14:00"), "end": d(0, "15:30"), "all_day": False,
     "attendees": ["zhou ba(周八)", "wu jiu(吴九)"], "location": "", "room": "1801",
     "is_meeting": True, "creator": "product", "description": "", "repeat_label": "", "date": d(0, "00:00")[:10]},
    {"subject": "示例客户 B · 回款跟进", "begin": d(1, "09:30"), "end": d(1, "10:00"), "all_day": False,
     "attendees": ["zheng shi(郑十)"], "location": "", "room": "", "is_meeting": False,
     "creator": "zhang san(张三)", "description": "", "repeat_label": "", "date": d(1, "00:00")[:10]},
    {"subject": "季度业绩复盘", "begin": d(3, "15:00"), "end": d(3, "17:00"), "all_day": False,
     "attendees": ["li si(李四)", "qian yi(钱一)"], "location": "会议室 B", "room": "",
     "is_meeting": True, "creator": "zhang san(张三)", "description": "", "repeat_label": "", "date": d(3, "00:00")[:10]},
    {"subject": "示例客户 C · 二期需求确认", "begin": d(6, "11:00"), "end": d(6, "12:00"), "all_day": False,
     "attendees": ["wang wu(王五)"], "location": "", "room": "", "is_meeting": False,
     "creator": "wang wu(王五)", "description": "", "repeat_label": "", "date": d(6, "00:00")[:10]},
    {"subject": "季度冲刺启动会", "begin": d(9, "09:00"), "end": d(9, "10:00"), "all_day": False,
     "attendees": ["全部门"], "location": "", "room": "大会议厅", "is_meeting": True,
     "creator": "zhang san(张三)", "description": "", "repeat_label": "", "date": d(9, "00:00")[:10]},
]

todos = [
    {"title": "跟进示例客户 A 的续约合同用印", "status": "proceed", "user_status": "accept",
     "deadline": d(-1, "18:00"), "deadline_type": "datetime", "date": d(-1, "00:00")[:10],
     "creator": "", "followers": ["zhao liu(赵六)"], "source": "群聊", "description": "", "create_time": d(-10, "00:00"), "update_time": d(-1, "00:00")},
    {"title": "提交本半年度赢单分析报告", "status": "proceed", "user_status": "accept",
     "deadline": d(0, "18:00"), "deadline_type": "datetime", "date": d(0, "00:00")[:10],
     "creator": "", "followers": [], "source": "单聊", "description": "", "create_time": d(-5, "00:00"), "update_time": d(0, "00:00")},
    {"title": "确认新产品报价单模板", "status": "proceed", "user_status": "accept",
     "deadline": d(2, "00:00"), "deadline_type": "date", "date": d(2, "00:00")[:10],
     "creator": "product", "followers": ["sun qi(孙七)"], "source": "智能总结", "description": "", "create_time": d(-3, "00:00"), "update_time": d(0, "00:00")},
    {"title": "整理下季度重点客户拜访计划", "status": "proceed", "user_status": "accept",
     "deadline": d(7, "00:00"), "deadline_type": "date", "date": d(7, "00:00")[:10],
     "creator": "", "followers": ["zhou ba(周八)", "wu jiu(吴九)"], "source": "会议纪要", "description": "", "create_time": d(-2, "00:00"), "update_time": d(0, "00:00")},
    {"title": "更新数据看板的统计口径", "status": "proceed", "user_status": "accept",
     "deadline": "", "deadline_type": "", "date": "",
     "creator": "", "followers": [], "source": "", "description": "", "create_time": d(-8, "00:00"), "update_time": d(-4, "00:00")},
    {"title": "桌面小组件的新能力验收", "status": "proceed", "user_status": "accept",
     "deadline": d(12, "00:00"), "deadline_type": "date", "date": d(12, "00:00")[:10],
     "creator": "", "followers": [], "source": "文档", "description": "", "create_time": d(-6, "00:00"), "update_time": d(-1, "00:00")},
]

# `own` 是企业微信返回的「是不是我参与的」标记：小组件默认视图是「只看我的」，
# 按这个字段过滤。示例数据必须给上，否则第一次跑起来首屏是 0 条日程，
# 完全看不出排版（最后一条故意留 False，用来看「全部」视图与「我的」视图的差别）。
for i, s in enumerate(schedules):
    s["own"] = (i != len(schedules) - 1)

payload = {
    "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "range_begin": (today - timedelta(days=30)).strftime("%Y-%m-%d"),
    "range_end": (today + timedelta(days=30)).strftime("%Y-%m-%d"),
    "demo": True,
    "schedules_ok": False,
    "todos_ok": False,
    "schedules": schedules,
    "todos": todos,
    "errors": [{"module": "示例数据", "code": "demo",
                "message": "当前为示例数据（企业微信日程/待办权限待授权）", "help": "", "stale": False}],
    "prev_generated_at": "",
}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
print("示例数据已写入", OUT)
