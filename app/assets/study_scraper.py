#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
study_scraper.py —— 学习通(超星) / 中国大学MOOC(icourse163) 作业·测验·考试 截止时间抓取

设计要点
--------
* 只登录一次：把浏览器里已登录的 Cookie 粘进文本文件即可，脚本不接触账号密码。
* 只抓「作业 / 测验 / 考试 + 截止时间」，不抓课程资料、公告、视频进度。
* 输出两份文件：todos.json（给程序用）+ todos.md（给人看）。
* 纯 Python + requests，无浏览器依赖；解析全部用正则，离线可自测（--selftest）。

常用命令
--------
    python study_scraper.py                       # 两个平台，只要未完成的
    python study_scraper.py -s chaoxing           # 只抓学习通
    python study_scraper.py --all                 # 连已完成 / 已过期的也列出来
    python study_scraper.py --probe               # 只检查 Cookie 是否还有效
    python study_scraper.py --selftest            # 不联网，自检解析逻辑

Cookie 文件格式（任选其一，脚本自动识别）
------------------------------------------
1) 直接粘贴请求头里的 Cookie 串：
       _uid=123456; _d=xxx; fid=1234; uf=xxx; vc3=xxx; UID=123456
2) Netscape cookies.txt（浏览器插件导出，7 列制表符分隔）
3) JSON（EditThisCookie / Cookie-Editor 导出：[{"name": "...", "value": "..."}]）
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from html import unescape
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote, urljoin, urlsplit, urlunsplit, parse_qsl, urlencode

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit("缺少依赖：请先运行  pip install requests")

CST = timezone(timedelta(hours=8))
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)


def setup_stdio() -> None:
    """Windows 控制台默认 GBK，输出中文/符号会乱码或直接抛异常，这里统一切到 UTF-8。"""
    if os.name == "nt":
        try:
            import ctypes
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
        except Exception:
            pass
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[attr-defined]
        except Exception:
            pass

PLATFORM_CHAOXING = "chaoxing"
PLATFORM_ICOURSE163 = "icourse163"
PLATFORM_LABEL = {
    PLATFORM_CHAOXING: "学习通",
    PLATFORM_ICOURSE163: "中国大学MOOC",
}

KIND_HOMEWORK = "作业"
KIND_QUIZ = "测验"
KIND_EXAM = "考试"

# 出现这些词说明这条已经不用再做了
CLOSED_MARKERS = (
    "待批阅", "已提交", "已交", "已完成", "已结束", "已关闭", "已截止",
    "已过期", "已批阅", "已评", "不可作答", "查看答案", "已阅",
)
# 出现这些词说明还是待完成状态
COMPLETED_MARKERS = ("待批阅", "已提交", "已交", "已完成", "已批阅", "已评", "查看答案", "已阅")
EXPIRED_MARKERS = ("已结束", "已关闭", "已截止", "已过期", "不可作答")
OPEN_MARKERS = ("做作业", "未完成", "未交", "未提交", "可作答", "待完成", "开始答题", "去完成", "进入考试")


# --------------------------------------------------------------------------- #
# 时间工具
# --------------------------------------------------------------------------- #
def now_cst() -> datetime:
    return datetime.now(CST)


def fmt_cst(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.astimezone(CST).strftime("%Y-%m-%dT%H:%M:%S+08:00")


def human_left(dt: datetime | None, now: datetime) -> str:
    if dt is None:
        return "无截止时间"
    delta = dt - now
    total = int(delta.total_seconds())
    if total < 0:
        total = -total
        days, rem = divmod(total, 86400)
        hours, rem = divmod(rem, 3600)
        minutes = rem // 60
        parts = []
        if days:
            parts.append(f"{days}天")
        if hours:
            parts.append(f"{hours}小时")
        if not days and not hours:
            parts.append(f"{max(minutes, 1)}分钟")
        return "已逾期 " + "".join(parts)
    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    parts = []
    if days:
        parts.append(f"{days}天")
    if hours:
        parts.append(f"{hours}小时")
    if not days and not hours:
        parts.append(f"{minutes}分钟")
    return "剩 " + "".join(parts)


# --------------------------------------------------------------------------- #
# Cookie 解析
# --------------------------------------------------------------------------- #
def _parse_header_cookies(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for chunk in re.split(r"[;\n]", text):
        chunk = chunk.strip()
        if not chunk or "=" not in chunk:
            continue
        name, _, value = chunk.partition("=")
        name = name.strip()
        value = value.strip().strip('"')
        if name and name not in out:
            out[name] = value
    return out


def _parse_netscape_cookies(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#HttpOnly_"):
            line = line[len("#HttpOnly_"):]
        elif line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) >= 7 and fields[5]:
            out.setdefault(fields[5], fields[6])
    return out


def _parse_json_cookies(text: str) -> dict[str, str]:
    try:
        data = json.loads(text)
    except ValueError:
        return {}
    out: dict[str, str] = {}
    if isinstance(data, dict):
        if "cookies" in data and isinstance(data["cookies"], list):
            data = data["cookies"]
        elif all(isinstance(v, (str, int, float)) for v in data.values()):
            return {str(k): str(v) for k, v in data.items()}
        else:
            data = [data]
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and item.get("name"):
                out.setdefault(str(item["name"]), str(item.get("value", "")))
    return out


def parse_cookie_text(text: str) -> dict[str, str]:
    text = (text or "").lstrip("\ufeff").strip()
    if not text:
        return {}
    if text[0] in "[{":
        parsed = _parse_json_cookies(text)
        if parsed:
            return parsed
    if "\t" in text:
        parsed = _parse_netscape_cookies(text)
        if parsed:
            return parsed
    return _parse_header_cookies(text)


def load_cookies(path: str | None, inline: str | None = None) -> dict[str, str]:
    if inline:
        cookies = parse_cookie_text(inline)
        if not cookies:
            raise SystemExit("[错误] --cookie 内联字符串解析不出任何 Cookie")
        return cookies
    if not path:
        raise SystemExit("[错误] 未指定 Cookie 文件")
    p = Path(path)
    if not p.exists():
        raise SystemExit(
            f"[错误] 找不到 Cookie 文件：{p}\n"
            f"       请把浏览器里的 Cookie 粘贴到该文件（格式见 README.md）"
        )
    cookies = parse_cookie_text(p.read_text(encoding="utf-8-sig", errors="replace"))
    if not cookies:
        raise SystemExit(f"[错误] Cookie 文件 {p} 里解析不出任何键值对")
    return cookies


# --------------------------------------------------------------------------- #
# HTTP 封装（多线程安全：每线程一个 Session，Cookie 共享）
# --------------------------------------------------------------------------- #
class HttpError(RuntimeError):
    pass


class AuthExpired(RuntimeError):
    pass


class _PlatformSession(requests.Session):
    """Validate every destination, including requests' redirect follow-ups."""

    def __init__(self, cookie_domain: str):
        super().__init__()
        self.cookie_domain = cookie_domain

    def send(self, request, **kwargs):
        try:
            target = urlsplit(request.url)
            host = target.hostname or ""
            allowed = (
                target.scheme == "https"
                and (host == self.cookie_domain or host.endswith("." + self.cookie_domain))
                and target.port in (None, 443)
                and target.username is None and target.password is None
            )
        except ValueError:
            allowed = False
        if not allowed:
            raise HttpError("已阻止向学习平台以外或非 HTTPS 地址发送请求")
        return super().send(request, **kwargs)


class Http:
    def __init__(self, cookies: dict[str, str], timeout: float = 20.0, *, cookie_domain: str):
        if cookie_domain not in {"chaoxing.com", "icourse163.org"}:
            raise ValueError("Unsupported cookie domain")
        self.cookie_domain = cookie_domain
        self._shared = dict(cookies)
        self.timeout = timeout
        self._lock = threading.Lock()
        self._local = threading.local()

    # -- cookie ------------------------------------------------------------
    def get_cookie(self, name: str) -> str | None:
        with self._lock:
            return self._shared.get(name)

    def cookie_snapshot(self) -> dict[str, str]:
        with self._lock:
            return dict(self._shared)

    def _session(self) -> requests.Session:
        s: requests.Session | None = getattr(self._local, "session", None)
        if s is not None:
            return s
        s = _PlatformSession(self.cookie_domain)
        s.headers.update({
            "User-Agent": UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
            "Connection": "keep-alive",
        })
        for name, value in self.cookie_snapshot().items():
            s.cookies.set(name, value, domain="." + self.cookie_domain, path="/", secure=True)
        self._local.session = s
        return s

    def request(
        self,
        method: str,
        url: str,
        *,
        params: dict[str, str] | None = None,
        data: dict[str, str] | None = None,
        headers: dict[str, str] | None = None,
        referer: str | None = None,
        retries: int = 2,
    ) -> requests.Response:
        session = self._session()
        merged: dict[str, str] = {}
        if referer:
            merged["Referer"] = referer
        if headers:
            merged.update(headers)
        last_exc: Exception | None = None
        resp: requests.Response | None = None
        for attempt in range(retries + 1):
            try:
                resp = session.request(
                    method, url, params=params, data=data, headers=merged,
                    timeout=self.timeout, allow_redirects=True,
                )
                break
            except requests.RequestException as exc:
                last_exc = exc
                if attempt >= retries:
                    raise HttpError(f"{method} {url} 请求失败：{exc}") from exc
                time.sleep(0.6 * (attempt + 1))
        assert resp is not None
        with self._lock:
            for c in session.cookies:
                if c.value is not None:
                    self._shared[c.name] = c.value
        return resp

    def get(self, url: str, **kw) -> requests.Response:
        return self.request("GET", url, **kw)

    def post(self, url: str, **kw) -> requests.Response:
        return self.request("POST", url, **kw)


def looks_like_login_page(text: str) -> bool:
    head = text[:8000]
    return bool(re.search(r"passport2\.chaoxing\.com|请先登录|登录超时|用户登录|id=\"loginForm\"", head))


# --------------------------------------------------------------------------- #
# 数据结构
# --------------------------------------------------------------------------- #
@dataclass
class Course:
    course_id: str
    class_id: str
    cpi: str = ""
    title: str = ""


@dataclass
class Item:
    platform: str
    kind: str
    title: str
    course: str
    due: datetime | None
    status: str
    url: str
    uid: str
    extra: dict[str, Any] = field(default_factory=dict)

    def to_json(self, now: datetime) -> dict[str, Any]:
        return {
            "id": self.uid,
            "platform": self.platform,
            "platform_label": PLATFORM_LABEL.get(self.platform, self.platform),
            "kind": self.kind,
            "title": self.title,
            "course": self.course,
            "due_at": fmt_cst(self.due),
            "due_display": self.due.astimezone(CST).strftime("%Y-%m-%d %H:%M") if self.due else None,
            "days_left": round((self.due - now).total_seconds() / 86400, 2) if self.due else None,
            "status": self.status,
            "url": self.url,
            **({"extra": self.extra} if self.extra else {}),
        }


@dataclass
class SourceReport:
    platform: str
    ok: bool = True
    courses: int = 0
    items: int = 0
    warnings: list[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# 通用 HTML 工具
# --------------------------------------------------------------------------- #
_SCRIPT_RE = re.compile(r"<(script|style)\b[^>]*>.*?</\1\s*>", re.S | re.I)
_TAG_RE = re.compile(r"<[^>]+>")
_ATTR_RE = re.compile(r"""([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))""")
_BLOCK_RE = re.compile(r"<(li|dt)\b([^>]*)>(.*?)</\1\s*>", re.S | re.I)


def strip_tags(html: str) -> str:
    text = _SCRIPT_RE.sub(" ", html)
    text = _TAG_RE.sub(" ", text)
    return re.sub(r"\s+", " ", unescape(text)).strip()


def parse_attrs(raw: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for m in _ATTR_RE.finditer(raw):
        value = m.group(2) if m.group(2) is not None else (m.group(3) if m.group(3) is not None else m.group(4))
        out[m.group(1).lower()] = unescape(value or "")
    return out


# 截止时间：只在「截止/结束/作答时间」附近取，避免把发布时间当成截止时间
_DUE_FULL_RE = re.compile(
    r"(?:截止时间|截止日期|结束时间|提交截止时间|作答时间|考试时间)[:：]?\s*(?:至\s*)?"
    r"(\d{4})\s*[-/年]\s*(\d{1,2})\s*[-/月]\s*(\d{1,2})\s*日?\s*"
    r"(\d{1,2})\s*[:时]\s*(\d{2})"
)
_DUE_NOYEAR_RE = re.compile(
    r"(?:截止时间|截止日期|结束时间|提交截止时间)[:：]?\s*"
    r"(\d{1,2})\s*[-/月]\s*(\d{1,2})\s*日?\s*(\d{1,2})\s*[:时]\s*(\d{2})"
)
_DUE_ARIA_RE = re.compile(r"截止时间\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(\d{1,2})\s*时\s*(\d{1,2})\s*分")
_REMAIN_RE = re.compile(r"剩余\s*(?:(\d+)\s*天)?\s*(?:(\d+)\s*小时)?\s*(?:(\d+)\s*分钟)?")


def _mk_dt(year: int, month: int, day: int, hour: int, minute: int, second: int = 0) -> datetime | None:
    try:
        return datetime(year, month, day, hour, minute, second, tzinfo=CST)
    except ValueError:
        return None


def _infer_year(month: int, day: int) -> int:
    """只给了「月日」时推断年份：取最近一次没有过去太久的那个。"""
    now = now_cst()
    year = now.year
    candidate = _mk_dt(year, month, day, 23, 59)
    if candidate is None:
        return year
    while candidate < now - timedelta(days=7):
        year += 1
        candidate = _mk_dt(year, month, day, 23, 59)
        if candidate is None:
            break
    return year


def parse_due_text(text: str) -> datetime | None:
    m = _DUE_FULL_RE.search(text)
    if m:
        dt = _mk_dt(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)))
        if dt:
            return dt
    m = _DUE_ARIA_RE.search(text)
    if m:
        dt = _mk_dt(_infer_year(int(m.group(1)), int(m.group(2))),
                    int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
        if dt:
            return dt
    m = _DUE_NOYEAR_RE.search(text)
    if m:
        month, day, hour, minute = (int(m.group(i)) for i in range(1, 5))
        dt = _mk_dt(_infer_year(month, day), month, day, hour, minute)
        if dt:
            return dt
    m = _REMAIN_RE.search(text)
    if m and any(m.group(i) for i in (1, 2, 3)):
        days = int(m.group(1) or 0)
        hours = int(m.group(2) or 0)
        minutes = int(m.group(3) or 0)
        if days or hours or minutes:
            return now_cst() + timedelta(days=days, hours=hours, minutes=minutes)
    return None


def is_closed_text(text: str, html: str = "") -> bool:
    if any(marker in text for marker in CLOSED_MARKERS):
        return True
    # 学习通列表里，过期项会挂一个 ks_02 的灰色图标
    return bool(re.search(r"ks_02", html))


def pick_status(text: str) -> str:
    for marker in OPEN_MARKERS:
        if marker in text:
            return marker
    for marker in CLOSED_MARKERS:
        if marker in text:
            return marker
    return ""


# --------------------------------------------------------------------------- #
# 学习通（超星）
# --------------------------------------------------------------------------- #
CX_COURSE_LIST_URLS = (
    ("modern", "https://mooc1-1.chaoxing.com/mooc-ans/visit/courselistdata"),
    ("legacy", "https://mooc1-api.chaoxing.com/mycourse/backclazzdata?view=json&rss=1"),
)
CX_TASK_LIST_URLS = {
    "work": "https://mooc1-api.chaoxing.com/work/task-list",
    "exam": "https://mooc1-api.chaoxing.com/mooc-ans/exam/phone/task-list",
}
CX_HOME = "https://i.chaoxing.com/base"
CX_COURSE_PAGE = "https://mooc1.chaoxing.com/"


def _first_str(obj: dict, keys: Iterable[str]) -> str | None:
    for key in keys:
        value = obj.get(key)
        if isinstance(value, (str, int)) and str(value).strip():
            return str(value).strip()
    return None


def _course_from_flat(obj: dict[str, Any]) -> Course | None:
    course_id = _first_str(obj, ("courseId", "courseid", "course_id"))
    class_id = _first_str(obj, ("classId", "clazzid", "clazzId", "classid"))
    if not course_id or not class_id or class_id == "0":
        return None
    return Course(
        course_id=course_id,
        class_id=class_id,
        cpi=_first_str(obj, ("cpi", "personid", "personId")) or "",
        title=_first_str(obj, ("courseName", "coursename", "title", "name")) or "",
    )


def parse_cx_course_json(obj: Any) -> list[Course]:
    """从 backclazzdata 一类的 JSON 里挖出课程；对结构变化尽量宽容。"""
    out: list[Course] = []
    seen: set[tuple[str, str]] = set()

    def add(course: Course | None) -> None:
        if course is None:
            return
        key = (course.course_id, course.class_id)
        if key in seen:
            return
        seen.add(key)
        out.append(course)

    def walk(node: Any, depth: int = 0) -> None:
        if depth > 12 or node is None:
            return
        if isinstance(node, list):
            for entry in node:
                walk(entry, depth + 1)
            return
        if not isinstance(node, dict):
            return
        add(_course_from_flat(node))
        course = node.get("course")
        clazz_list = node.get("clazz") or node.get("clazzs") or node.get("classList")
        if isinstance(course, dict) and isinstance(clazz_list, list):
            cid = _first_str(course, ("id", "courseId"))
            title = _first_str(course, ("name", "courseName", "title")) or ""
            cpi = _first_str(node, ("personid", "personId", "cpi")) or _first_str(course, ("personid", "personId")) or ""
            for clazz in clazz_list:
                if isinstance(clazz, dict):
                    kid = _first_str(clazz, ("id", "classId", "clazzid"))
                    if cid and kid and kid != "0":
                        add(Course(cid, kid, cpi, title))
        for value in node.values():
            if isinstance(value, (dict, list)):
                walk(value, depth + 1)

    walk(obj)
    return out


def parse_cx_course_html(html: str) -> list[Course]:
    out: list[Course] = []
    seen: set[tuple[str, str]] = set()
    for match in re.finditer(r"<li\b([^>]*)>", html, re.I):
        attrs = parse_attrs(match.group(1))
        classes = (attrs.get("class") or "").split()
        if "course" not in classes:
            continue
        course_id = (attrs.get("courseid") or "").strip()
        class_id = (attrs.get("clazzid") or "").strip()
        if not course_id or not class_id or class_id == "0":
            continue
        tail = html[match.end(): match.end() + 4000]
        title = ""
        m = re.search(r'class="[^"]*course-name[^"]*"[^>]*title="([^"]*)"', tail, re.I)
        if m:
            title = unescape(m.group(1)).strip()
        if not title:
            m = re.search(r'class="[^"]*course-name[^"]*"[^>]*>([^<]*)', tail, re.I)
            if m:
                title = unescape(m.group(1)).strip()
        if not title:
            title = (attrs.get("title") or "").strip()
        key = (course_id, class_id)
        if key in seen:
            continue
        seen.add(key)
        out.append(Course(course_id, class_id, (attrs.get("personid") or "").strip(), title))
    return out


def cx_discover_courses(http: Http, log) -> tuple[list[Course], list[str]]:
    warnings: list[str] = []
    for label, url in CX_COURSE_LIST_URLS:
        try:
            resp = http.get(url, referer=CX_COURSE_PAGE)
        except HttpError as exc:
            warnings.append(f"[{label}] 课程列表请求失败：{exc}")
            continue
        if resp.status_code in (401, 403):
            raise AuthExpired("学习通 Cookie 已失效（401/403）")
        if resp.status_code >= 400:
            warnings.append(f"[{label}] 课程列表 HTTP {resp.status_code}")
            continue
        body = resp.text or ""
        if looks_like_login_page(body):
            raise AuthExpired("学习通 Cookie 已失效，被重定向到登录页")
        courses = parse_cx_course_html(body)
        if courses:
            log(f"  学习通：{label} 课程列表解析到 {len(courses)} 门课")
            return courses, warnings
        try:
            payload = resp.json()
        except ValueError:
            payload = None
        if payload is not None:
            courses = parse_cx_course_json(payload)
            if courses:
                log(f"  学习通：{label} 课程列表(JSON)解析到 {len(courses)} 门课")
                return courses, warnings
        warnings.append(f"[{label}] 没有解析到课程（Cookie 失效或页面结构变化）")
    return [], warnings


def _absolutize(url: str, base: str = "https://mooc1-api.chaoxing.com") -> str:
    url = url.strip()
    if url.startswith("//"):
        url = "https:" + url
    if not re.match(r"^https?://", url, re.I):
        url = urljoin(base, url if url.startswith("/") else "/" + url)
    return url


def parse_cx_task_html(html: str, course: Course, hint: str) -> list[Item]:
    items: list[Item] = []
    for match in _BLOCK_RE.finditer(html):
        attrs = parse_attrs(match.group(2))
        inner = match.group(3)
        entry = attrs.get("data") or attrs.get("data-url") or attrs.get("href") or ""
        if not entry:
            a = re.search(r'<a\b[^>]*href="([^"]+)"', inner, re.I)
            entry = a.group(1) if a else ""
        if not entry:
            continue
        text = strip_tags(inner)
        title = ""
        m = re.search(r"<p\b[^>]*>(.*?)</p>", inner, re.S | re.I)
        if m:
            title = strip_tags(m.group(1))
        if not title:
            m = re.search(r"<h[1-4]\b[^>]*>(.*?)</h[1-4]>", inner, re.S | re.I)
            if m:
                title = strip_tags(m.group(1))
        if not title:
            title = (attrs.get("title") or "").strip()
        if not title:
            continue
        # 过滤掉导航用的空壳 li
        if not (parse_due_text(text) or is_closed_text(text, inner) or re.search(r"work|exam|homework", entry, re.I)):
            continue
        url = _absolutize(entry)
        if "courseId=" not in url and course.course_id:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{urlencode({'courseId': course.course_id, 'classId': course.class_id})}"
        kind = hint
        if re.search(r"exam", entry, re.I) or "考试" in title:
            kind = KIND_EXAM
        elif hint == "work":
            kind = KIND_QUIZ if re.search(r"测验|测试|练习", title) else KIND_HOMEWORK
        status = pick_status(text)
        due = parse_due_text(text)
        taskref = re.search(r"(?:taskrefId|workId|examId|jobid)=([\w-]+)", entry, re.I)
        uid = f"chaoxing:{course.course_id}:{taskref.group(1) if taskref else url}"
        items.append(Item(
            platform=PLATFORM_CHAOXING,
            kind=kind,
            title=title,
            course=course.title or f"{course.course_id}/{course.class_id}",
            due=due,
            status=status,
            url=url,
            uid=uid,
            extra={"completed": any(m in text for m in COMPLETED_MARKERS),
                   "open": not is_closed_text(text, inner)},
        ))
    return items


def cx_course_tasks(http: Http, course: Course, log) -> list[Item]:
    items: list[Item] = []
    for hint, url in CX_TASK_LIST_URLS.items():
        params = {"courseId": course.course_id, "classId": course.class_id, "cpi": course.cpi}
        try:
            resp = http.get(url, params=params, referer=CX_COURSE_PAGE)
        except HttpError as exc:
            log(f"    ! {course.title} 的 {hint} 列表请求失败：{exc}")
            continue
        if resp.status_code >= 400 or looks_like_login_page(resp.text or ""):
            continue
        items.extend(parse_cx_task_html(resp.text or "", course, hint))
    return items


def collect_chaoxing(cookies: dict[str, str], args, log) -> tuple[list[Item], SourceReport]:
    report = SourceReport(PLATFORM_CHAOXING)
    if not cookies:
        report.ok = False
        report.warnings.append("没有提供 Cookie")
        return [], report
    http = Http(cookies, timeout=args.timeout, cookie_domain="chaoxing.com")
    try:
        http.get(CX_HOME, referer="https://i.chaoxing.com/")
    except HttpError as exc:
        log(f"  ! 学习通首页预热失败（继续尝试）：{exc}")

    courses, warnings = cx_discover_courses(http, log)
    report.warnings.extend(warnings)
    report.courses = len(courses)
    if not courses:
        report.ok = False
        return [], report

    def work(course: Course) -> list[Item]:
        return cx_course_tasks(http, course, log)

    items: list[Item] = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        for produced in pool.map(work, courses):
            items.extend(produced)
    report.items = len(items)
    return items, report


# --------------------------------------------------------------------------- #
# 中国大学 MOOC（icourse163）
# --------------------------------------------------------------------------- #
IC_ORIGIN = "https://www.icourse163.org"
IC_PANEL_URL = f"{IC_ORIGIN}/web/j/learnerCourseRpcBean.getMyLearnedCoursePanelList.rpc"
IC_TERM_URL = f"{IC_ORIGIN}/web/j/courseBean.getLastLearnedMocTermDto.rpc"
IC_PAGE_SIZE = 20
IC_MAX_PAGES = 20
IC_LEGACY_QUIZ_TYPE = 5


def ic_learn_url(course: dict[str, Any], tab: str) -> str:
    slug = course.get("school") or ""
    cid = course.get("course_id") or ""
    term = course.get("term_id") or ""
    prefix = f"{slug}-{cid}" if slug else cid
    return f"{IC_ORIGIN}/learn/{prefix}?tid={term}#/learn/{tab}"


def _as_dict(value: Any) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _num(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.strip()
        if re.fullmatch(r"-?\d+(?:\.\d+)?", text):
            try:
                return float(text)
            except ValueError:
                return None
    return None


def _text(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


def ic_parse_panels(payload: Any, course_type: str) -> list[dict[str, Any]] | None:
    root = _as_dict(payload)
    if root is None or root.get("code") != 0:
        return None
    result = _as_dict(root.get("result"))
    if result is None:
        return []
    out: list[dict[str, Any]] = []
    for raw in _as_list(result.get("result")):
        item = _as_dict(raw)
        if item is None:
            continue
        cid = item.get("id")
        term = _as_dict(item.get("termPanel")) or {}
        tid = term.get("id")
        if cid is None or tid is None:
            continue
        school = _as_dict(item.get("schoolPanel")) or {}
        out.append({
            "course_id": str(cid),
            "term_id": str(tid),
            "name": _text(item.get("name")) or "未命名课程",
            "school": _text(school.get("shortName")) or "",
            "type": course_type,
        })
    return out


def ic_deadline_ms(*records: dict[str, Any]) -> float | None:
    """deadline / endTime / testEndTime，按顺序取第一个数字。"""
    for record in records:
        for key in ("deadline", "endTime", "testEndTime"):
            value = _num(record.get(key))
            if value and value > 0:
                return value
    return None


def ic_status_text(*records: dict[str, Any]) -> str:
    parts: list[str] = []
    for record in records:
        for key in ("evaluateStatusName", "testStatusName", "statusName", "evaluateStatus", "testStatus", "status"):
            value = record.get(key)
            if isinstance(value, str) and value.strip():
                parts.append(value.strip())
    return " ".join(parts)


def ic_is_open(deadline_ms: float | None, status_text: str, used_try: float | None,
               score: float | None, now: datetime) -> bool:
    if any(marker in status_text for marker in CLOSED_MARKERS):
        return False
    if used_try is not None and used_try > 0:
        return False
    if score is not None and score > 0:
        return False
    if deadline_ms is None:
        return True
    return deadline_ms > now.timestamp() * 1000


def ic_kind(source: str, name: str) -> str:
    if source == "exam" or "考试" in name:
        return KIND_EXAM
    if source == "homework" or "作业" in name:
        return KIND_HOMEWORK
    return KIND_QUIZ


def ic_item_from(record: dict[str, Any], course: dict[str, Any], source: str,
                 name: str, item_id: str, now: datetime) -> Item | None:
    test = _as_dict(record.get("test")) or {}
    deadline = ic_deadline_ms(test, record)
    status = ic_status_text(test, record)
    used_try = _num(record.get("usedTryCount")) if _num(record.get("usedTryCount")) is not None else _num(test.get("usedTryCount"))
    score = _num(test.get("userScore")) if _num(test.get("userScore")) is not None else _num(test.get("testScore"))
    if score is None:
        score = _num(record.get("userScore"))
    due = datetime.fromtimestamp(deadline / 1000, tz=CST) if deadline else None
    tab = "examlist" if source == "exam" else "testlist"
    return Item(
        platform=PLATFORM_ICOURSE163,
        kind=ic_kind(source, name),
        title=name,
        course=course["name"],
        due=due,
        status=status,
        url=ic_learn_url(course, tab),
        uid=f"icourse163:{course['course_id']}:{course['term_id']}:{source}:{item_id}",
        extra={"open": ic_is_open(deadline, status, used_try, score, now),
               "completed": any(m in status for m in COMPLETED_MARKERS)
                   or (used_try is not None and used_try > 0) or (score is not None and score > 0)},
    )


def ic_items_from_moc(moc: dict[str, Any], course: dict[str, Any], now: datetime) -> list[Item]:
    items: list[Item] = []
    for raw_chapter in _as_list(moc.get("chapters")):
        chapter = _as_dict(raw_chapter)
        if chapter is None:
            continue
        for raw in _as_list(chapter.get("quizs")):
            quiz = _as_dict(raw)
            if quiz is None:
                continue
            test = _as_dict(quiz.get("test")) or {}
            name = _text(quiz.get("name")) or _text(test.get("name")) or "未知测验"
            item_id = quiz.get("id") if quiz.get("id") is not None else test.get("id")
            if item_id is None:
                continue
            item = ic_item_from(quiz, course, "quiz", name, str(item_id), now)
            if item:
                items.append(item)
        for raw in _as_list(chapter.get("homeworks")):
            homework = _as_dict(raw)
            if homework is None:
                continue
            test = _as_dict(homework.get("test")) or {}
            name = _text(homework.get("name")) or _text(test.get("name")) or "未知作业"
            item_id = homework.get("id") if homework.get("id") is not None else test.get("id")
            if item_id is None:
                continue
            item = ic_item_from(homework, course, "homework", name, str(item_id), now)
            if item:
                items.append(item)
        for raw_lesson in _as_list(chapter.get("lessons")):
            lesson = _as_dict(raw_lesson)
            if lesson is None:
                continue
            for raw_unit in _as_list(lesson.get("units")):
                unit = _as_dict(raw_unit)
                if unit is None or _num(unit.get("contentType")) != IC_LEGACY_QUIZ_TYPE:
                    continue
                name = _text(unit.get("name")) or "未知测验"
                if unit.get("id") is None:
                    continue
                item = ic_item_from(unit, course, "unit", name, str(unit.get("id")), now)
                if item:
                    items.append(item)
    for raw_exam in _as_list(moc.get("exams")):
        exam = _as_dict(raw_exam)
        if exam is None:
            continue
        test = _as_dict(exam.get("test")) or {}
        name = _text(exam.get("name")) or _text(exam.get("title")) or _text(test.get("name")) or "未知考试"
        item_id = exam.get("id") if exam.get("id") is not None else test.get("id")
        if item_id is None:
            continue
        item = ic_item_from(exam, course, "exam", name, str(item_id), now)
        if item:
            items.append(item)
    return items


def ic_fetch_moc(http: Http, csrf: str, course: dict[str, Any], log) -> dict[str, Any] | None:
    url = f"{IC_TERM_URL}?csrfKey={quote(csrf)}"
    referer = ic_learn_url(course, "testlist")
    for attempt in range(3):
        try:
            resp = http.post(url, data={"termId": course["term_id"]},
                             headers={"Origin": IC_ORIGIN}, referer=referer)
        except HttpError as exc:
            log(f"    ! {course['name']} 课程结构请求失败：{exc}")
            return None
        if resp.status_code in (401, 403):
            raise AuthExpired("中国大学MOOC Cookie 已失效（401/403）")
        try:
            payload = resp.json()
        except ValueError:
            return None
        root = _as_dict(payload) or {}
        if root.get("code") == 0:
            result = _as_dict(root.get("result")) or {}
            return _as_dict(result.get("mocTermDto")) or result or None
        message = str(root.get("message") or root.get("msg") or "")
        if "并发限制" in message and attempt < 2:
            time.sleep(0.3 * (attempt + 1))
            continue
        return None
    return None


def collect_icourse163(cookies: dict[str, str], args, log) -> tuple[list[Item], SourceReport]:
    report = SourceReport(PLATFORM_ICOURSE163)
    if not cookies:
        report.ok = False
        report.warnings.append("没有提供 Cookie")
        return [], report
    http = Http(cookies, timeout=args.timeout, cookie_domain="icourse163.org")
    csrf = http.get_cookie("NTESSTUDYSI")
    if not csrf:
        raise AuthExpired(
            "中国大学MOOC 的 Cookie 里找不到 NTESSTUDYSI —— "
            "请确认是在 www.icourse163.org 登录后复制的完整 Cookie"
        )
    try:
        http.get(f"{IC_ORIGIN}/", referer=f"{IC_ORIGIN}/")
    except HttpError as exc:
        log(f"  ! 预热 icourse163 失败（继续尝试）：{exc}")
    csrf = http.get_cookie("NTESSTUDYSI") or csrf

    courses: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for course_type in ("1", "2"):
        for page in range(1, IC_MAX_PAGES + 1):
            url = f"{IC_PANEL_URL}?csrfKey={quote(csrf)}"
            try:
                resp = http.post(
                    url,
                    data={"type": "30", "p": str(page), "psize": str(IC_PAGE_SIZE), "courseType": course_type},
                    headers={"Origin": IC_ORIGIN}, referer=f"{IC_ORIGIN}/",
                )
            except HttpError as exc:
                report.ok = False
                report.warnings.append(f"课程面板请求失败：{exc}")
                return [], report
            if resp.status_code in (401, 403):
                raise AuthExpired("中国大学MOOC Cookie 已失效（401/403）")
            if resp.status_code >= 400:
                report.ok = False
                report.warnings.append(f"课程面板 HTTP {resp.status_code}")
                return [], report
            try:
                payload = resp.json()
            except ValueError:
                raise AuthExpired("中国大学MOOC 返回的不是 JSON，Cookie 可能已失效")
            panels = ic_parse_panels(payload, course_type)
            if panels is None:
                root = _as_dict(payload) or {}
                report.ok = False
                report.warnings.append(
                    f"课程面板 RPC 返回 code={root.get('code')} {root.get('message') or ''}".strip()
                )
                return [], report
            for panel in panels:
                key = (panel["course_id"], panel["term_id"])
                if key in seen:
                    continue
                seen.add(key)
                courses.append(panel)
            if len(panels) < IC_PAGE_SIZE:
                break
    report.courses = len(courses)
    if not courses:
        report.ok = False
        report.warnings.append("没有拿到任何课程，Cookie 可能已失效")
        return [], report
    log(f"  中国大学MOOC：{len(courses)} 门课程")

    now = now_cst()
    items: list[Item] = []

    def work(course: dict[str, Any]) -> list[Item]:
        moc = ic_fetch_moc(http, csrf, course, log)
        if moc is None:
            return []
        return ic_items_from_moc(moc, course, now)

    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        for produced in pool.map(work, courses):
            items.extend(produced)
    report.items = len(items)
    return items, report


# --------------------------------------------------------------------------- #
# 输出
# --------------------------------------------------------------------------- #
def sort_items(items: list[Item]) -> list[Item]:
    return sorted(items, key=lambda it: (it.due is None, it.due or datetime.max.replace(tzinfo=CST), it.course, it.title))


def filter_items(items: list[Item], include_all: bool, horizon_days: int | None,
                 now: datetime, expired_after_days: int | None = None,
                 stats: dict[str, int] | None = None) -> list[Item]:
    kept: list[Item] = []
    days = expired_after_days if expired_after_days is not None else (-1 if include_all else 0)
    ignored = 0
    for item in items:
        completed = item.extra.get("completed") is True or any(m in item.status for m in COMPLETED_MARKERS)
        marked_expired = any(m in item.status for m in EXPIRED_MARKERS)
        is_expired = item.due is not None and item.due <= now
        if not include_all and (completed or
                (item.extra.get("open") is False and not (marked_expired or is_expired))):
            continue
        too_old = days >= 0 and (
            (days == 0 and (is_expired or (item.due is None and marked_expired))) or
            (days > 0 and item.due is not None and item.due < now - timedelta(days=days)))
        if too_old:
            ignored += 1
            continue
        if horizon_days is not None and item.due is not None:
            if item.due > now + timedelta(days=horizon_days):
                continue
        kept.append(item)
    if stats is not None:
        stats["ignored_expired"] = ignored
    return sort_items(kept)


def write_json(path: Path, items: list[Item], reports: list[SourceReport], args, now: datetime) -> None:
    payload = {
        "generated_at": fmt_cst(now),
        "timezone": "Asia/Shanghai",
        "filters": {"include_all": args.include_all, "horizon_days": args.horizon_days,
                    "ignore_expired_days": args.expired_after_days},
        "ignored_expired": getattr(args, "ignored_expired", 0),
        "count": len(items),
        "sources": [
            {"platform": r.platform, "label": PLATFORM_LABEL.get(r.platform, r.platform),
             "ok": r.ok, "courses": r.courses, "items": r.items, "warnings": r.warnings}
            for r in reports
        ],
        "todos": [item.to_json(now) for item in items],
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def _bucket(item: Item, now: datetime) -> str:
    if item.due is None:
        return "无截止时间"
    due = item.due
    if due < now:
        return "已逾期"
    if due.date() == now.date():
        return "今天"
    if due.date() == (now + timedelta(days=1)).date():
        return "明天"
    if due <= now + timedelta(days=7):
        return "七天内"
    return "更晚"


BUCKET_ORDER = ("已逾期", "今天", "明天", "七天内", "更晚", "无截止时间")


def write_markdown(path: Path, items: list[Item], reports: list[SourceReport], now: datetime) -> None:
    lines: list[str] = []
    lines.append("# 作业 / 测验 / 考试 截止提醒")
    lines.append("")
    lines.append(f"> 抓取时间：{now.astimezone(CST).strftime('%Y-%m-%d %H:%M')}　共 **{len(items)}** 项")
    lines.append("")
    summary = "　".join(
        f"{PLATFORM_LABEL.get(r.platform, r.platform)} {r.items} 项"
        + ("" if r.ok else "（失败）")
        for r in reports
    )
    if summary:
        lines.append(f"> 来源：{summary}")
        lines.append("")
    for report in reports:
        for warning in report.warnings:
            lines.append(f"- ⚠️ {PLATFORM_LABEL.get(report.platform, report.platform)}：{warning}")
    if any(not r.ok for r in reports):
        lines.append("")

    if not items:
        lines.append("（没有需要处理的待办，或者 Cookie 已失效 —— 用 `--probe` 检查登录状态）")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return

    for bucket in BUCKET_ORDER:
        group = [item for item in items if _bucket(item, now) == bucket]
        if not group:
            continue
        lines.append(f"## {bucket}（{len(group)}）")
        lines.append("")
        lines.append("| 截止时间 | 剩余 | 平台 | 类型 | 课程 | 标题 | 状态 |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- |")
        for item in group:
            due = item.due.astimezone(CST).strftime("%m-%d %H:%M") if item.due else "—"
            left = human_left(item.due, now)
            platform = PLATFORM_LABEL.get(item.platform, item.platform)
            title = item.title.replace("|", "\\|")
            course = (item.course or "—").replace("|", "\\|")
            link = f"[{title}]({item.url})" if item.url else title
            lines.append(f"| {due} | {left} | {platform} | {item.kind} | {course} | {link} | {item.status or '—'} |")
        lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def print_console(items: list[Item], now: datetime) -> None:
    if not items:
        print("  （没有未完成的作业/测验）")
        return
    for item in items:
        due = item.due.astimezone(CST).strftime("%Y-%m-%d %H:%M") if item.due else "无截止"
        left = human_left(item.due, now)
        print(f"  [{due}] {left:<14} {PLATFORM_LABEL.get(item.platform, item.platform)}"
              f" | {item.kind} | {item.course} | {item.title}")


# --------------------------------------------------------------------------- #
# 自检
# --------------------------------------------------------------------------- #
def selftest() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        if condition:
            print(f"  [OK]   {name}")
        else:
            failures.append(name)
            print(f"  [FAIL] {name} {detail}")

    print("Cookie 解析")
    check("请求头串", parse_cookie_text("_uid=1; _d=abc; fid=9") == {"_uid": "1", "_d": "abc", "fid": "9"})
    netscape = ".chaoxing.com\tTRUE\t/\tFALSE\t0\t_uid\t12345\n#HttpOnly_.chaoxing.com\tTRUE\t/\tFALSE\t0\tUID\t99\n"
    check("Netscape", parse_cookie_text(netscape) == {"_uid": "12345", "UID": "99"})
    check("JSON", parse_cookie_text('[{"name":"NTESSTUDYSI","value":"deadbeef"}]') == {"NTESSTUDYSI": "deadbeef"})

    print("截止时间解析")
    due = parse_due_text("作业名称 作业 截止时间：2026-11-20 23:59 剩余2天3小时")
    check("完整日期", due is not None and due.strftime("%Y-%m-%d %H:%M") == "2026-11-20 23:59", repr(due))
    due = parse_due_text("截止时间：11月20日 23时59分")
    check("月日+时分", due is not None and (due.month, due.day, due.hour) == (11, 20, 23), repr(due))
    due = parse_due_text("剩余 3天2小时15分钟")
    check("剩余时间", due is not None and 2 < (due - now_cst()).days <= 3, repr(due))
    check("发布时间不当截止", parse_due_text("发布时间：2026-10-01 08:00") is None)

    print("学习通课程列表")
    html = ('<ul><li class="course" courseid="111" clazzid="222" personid="333">'
            '<span class="course-name" title="高等数学">高等数学</span></li>'
            '<li class="course" courseid="0" clazzid="0" personid="1"><span class="course-name">垃圾</span></li></ul>')
    courses = parse_cx_course_html(html)
    check("HTML 课程", len(courses) == 1 and courses[0].course_id == "111" and courses[0].cpi == "333")
    payload = {"channelList": [{"content": {"course": {"id": 777, "name": "线性代数", "personid": 888},
                                            "clazz": [{"id": 999, "name": "一班"}]}}]}
    courses = parse_cx_course_json(payload)
    check("JSON 课程", len(courses) == 1 and courses[0].course_id == "777" and courses[0].title == "线性代数")

    print("学习通任务列表")
    task_html = (
        '<ul><li data="/work/phone/doHomeWork?workId=555&courseId=111">'
        '<p>第三章 习题</p><span>截止时间：2026-12-01 23:59</span></li>'
        '<li data="/mooc-ans/exam/test/reVersionTestStartNew?examId=666">'
        '<p>期中考试</p><span>已过期</span></li>'
        '<li data="/work/phone/doHomeWork?workId=777"><p>第四章 习题</p><span>剩余 5天</span></li></ul>'
    )
    course = Course("111", "222", "333", "高等数学")
    items = parse_cx_task_html(task_html, course, "work")
    check("任务条数", len(items) == 3, str(len(items)))
    check("作业标题", items[0].title == "第三章 习题" and items[0].kind == KIND_HOMEWORK)
    check("作业截止", items[0].due is not None and items[0].due.day == 1)
    check("补全 courseId", "courseId=111" in items[0].url and items[0].url.startswith("https://"))
    check("考试类型", items[1].kind == KIND_EXAM)
    check("剩余时间→截止", items[2].due is not None)

    print("icourse163 面板")
    panel = {"code": 0, "result": {"result": [
        {"id": 1001, "name": "数据结构", "termPanel": {"id": 2002}, "schoolPanel": {"shortName": "ZJU"}},
    ]}}
    courses = ic_parse_panels(panel, "1")
    check("面板解析", courses is not None and len(courses) == 1 and courses[0]["term_id"] == "2002")
    check("学习链接", ic_learn_url(courses[0], "testlist") ==
          "https://www.icourse163.org/learn/ZJU-1001?tid=2002#/learn/testlist")

    print("icourse163 待办抽取")
    moc = {
        "chapters": [
            {"quizs": [{"id": 11, "name": "第1章测验",
                        "test": {"deadline": 1790000000000, "testEndTime": 1790000000000}}],
             "homeworks": [{"id": 12, "name": "第1章作业", "test": {"deadline": 1790000000000}}],
             "lessons": [{"units": [{"id": 13, "name": "单元测验", "contentType": 5,
                                     "testEndTime": 1790000000000},
                                    {"id": 14, "name": "视频", "contentType": 1}]}]},
        ],
        "exams": [{"id": 15, "name": "期末考试", "test": {"endTime": 1790000000000}}],
    }
    items = ic_items_from_moc(moc, courses[0], now_cst())
    check("抽取条数", len(items) == 4, str(len(items)))
    check("类型判定", {i.kind for i in items} == {KIND_QUIZ, KIND_HOMEWORK, KIND_EXAM})
    check("截止时间", all(i.due is not None for i in items))
    check("忽略非测验单元", all("视频" not in i.title for i in items))

    print("状态过滤")
    now = now_cst()
    future = now + timedelta(days=1)
    check("已交不算待办", ic_is_open(future.timestamp() * 1000, "已提交", 1, 0, now) is False)
    check("过期不算待办", ic_is_open((now - timedelta(hours=1)).timestamp() * 1000, "", None, None, now) is False)
    check("未完成算待办", ic_is_open(future.timestamp() * 1000, "未交", 0, 0, now) is True)

    print()
    if failures:
        print(f"[FAIL] 自检失败 {len(failures)} 项：{', '.join(failures)}")
        return 1
    print("[OK] 全部自检通过（解析逻辑与网络无关，可离线验证）")
    return 0


# --------------------------------------------------------------------------- #
# 入口
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="抓取学习通 / 中国大学MOOC 的作业、测验、考试及截止时间",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例：\n"
            "  python study_scraper.py\n"
            "  python study_scraper.py -s chaoxing --all\n"
            "  python study_scraper.py --probe\n"
        ),
    )
    p.add_argument("-s", "--source", choices=["all", PLATFORM_CHAOXING, PLATFORM_ICOURSE163],
                   default="all", help="抓取哪个平台（默认 all）")
    p.add_argument("--chaoxing-cookie", default="cookies/chaoxing.txt",
                   help="学习通 Cookie 文件（默认 cookies/chaoxing.txt）")
    p.add_argument("--icourse163-cookie", default="cookies/icourse163.txt",
                   help="中国大学MOOC Cookie 文件（默认 cookies/icourse163.txt）")
    p.add_argument("--cookie", default=None,
                   help="直接给 Cookie 字符串，覆盖上面的两个文件（只适合单平台）")
    p.add_argument("-o", "--out-dir", default="out", help="输出目录（默认 out/）")
    p.add_argument("--json", dest="json_name", default="todos.json", help="JSON 文件名")
    p.add_argument("--md", dest="md_name", default="todos.md", help="Markdown 文件名")
    p.add_argument("--all", dest="include_all", action="store_true",
                   help="连已完成 / 已过期的也列出来")
    p.add_argument("--days", dest="horizon_days", type=int, default=None,
                   help="只看未来 N 天内截止的")
    def expired_days(value):
        try:
            days = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError("过期天数须为整数") from None
        if days < -1 or days > 3650:
            raise argparse.ArgumentTypeError("过期天数须为 -1 至 3650")
        return days
    p.add_argument("--ignore-expired-days", dest="expired_after_days", type=expired_days,
                   default=None, help="忽略过期超过 N 天的任务；0 忽略全部过期，-1 不忽略；默认 0（--all 除外）")
    p.add_argument("--workers", type=int, default=6, help="并发数（默认 6）")
    p.add_argument("--timeout", type=float, default=20.0, help="单请求超时秒数（默认 20）")
    p.add_argument("--probe", action="store_true", help="只检查 Cookie 是否可用，不抓任务")
    p.add_argument("--selftest", action="store_true", help="离线自检解析逻辑")
    p.add_argument("--demo", action="store_true", help="用假数据渲染一份示例输出，看看格式长什么样")
    p.add_argument("--quiet", action="store_true", help="不在终端打印明细")
    return p


def run_demo(args) -> int:
    """用合成数据跑一遍真实的写文件流程，验证 JSON / Markdown 输出格式。"""
    now = now_cst()

    def at(days: float) -> datetime:
        return now + timedelta(days=days)

    samples = [
        ("chaoxing", "作业", "第 5 章 栈与队列 课后作业", "数据结构", at(0.05), "待完成", "做作业"),
        ("chaoxing", "考试", "期中测验（第 1-4 章）", "数据结构", at(0.6), "待完成", "开始考试"),
        ("chaoxing", "作业", "第 3 章 线性表 编程题", "数据结构", at(-1.5), "已过期", "已过期"),
        ("chaoxing", "作业", "实验报告二：链表实现", "程序设计基础", at(3.2), "待完成", "做作业"),
        ("icourse163", "测验", "Unit 2 单元测验", "大学英语（一）", at(1.9), "待完成", "去测验"),
        ("icourse163", "作业", "第一次编程作业：Hello World", "Python 程序设计", at(9.5), "待完成", "去提交"),
        ("icourse163", "考试", "期末考试", "Python 程序设计", None, "待完成", "查看"),
    ]
    items = []
    for platform, kind, title, course, due, status, action in samples:
        items.append(
            Item(
                platform=platform,
                kind=kind,
                title=title,
                course=course,
                due=due.astimezone(CST) if due else None,
                status=status,
                url=f"https://example.invalid/{platform}/{quote(title)}",
                uid=f"{platform}:{kind}:{title}",
                extra={"action": action, "note": "示例数据"},
            )
        )
    reports = [
        SourceReport(platform=PLATFORM_CHAOXING, ok=True, courses=3, items=4),
        SourceReport(platform=PLATFORM_ICOURSE163, ok=True, courses=2, items=3),
    ]

    stats = {}
    kept = filter_items(items, args.include_all, args.horizon_days, now,
                        args.expired_after_days, stats)
    args.ignored_expired = stats.get("ignored_expired", 0)
    out_dir = Path(args.out_dir)
    json_path = out_dir / f"demo_{args.json_name}"
    md_path = out_dir / f"demo_{args.md_name}"
    write_json(json_path, kept, reports, args, now)
    write_markdown(md_path, kept, reports, now)

    print(f"示例数据已写入：{json_path}  |  {md_path}")
    print(f"（共 {len(kept)} 项，其中若干已逾期/无截止时间，正是真实抓取时要提醒你的那几类）\n")
    print_console(kept, now)
    return 0


def main(argv: list[str] | None = None) -> int:
    setup_stdio()
    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest()
    if args.demo:
        return run_demo(args)

    def log(message: str) -> None:
        if not args.quiet:
            print(message)

    now = now_cst()
    wants: list[str] = []
    if args.source in ("all", PLATFORM_CHAOXING):
        wants.append(PLATFORM_CHAOXING)
    if args.source in ("all", PLATFORM_ICOURSE163):
        wants.append(PLATFORM_ICOURSE163)

    # 先把 Cookie 统统读出来：少一个文件就地报错，不要白发请求
    cookie_map: dict[str, dict[str, str]] = {}
    for platform in wants:
        path = args.chaoxing_cookie if platform == PLATFORM_CHAOXING else args.icourse163_cookie
        try:
            cookie_map[platform] = load_cookies(None, args.cookie) if args.cookie else load_cookies(path)
        except SystemExit as exc:
            print(f"{PLATFORM_LABEL[platform]}：{exc}", file=sys.stderr)
    if not cookie_map:
        print("\n没有可用的 Cookie，未发起任何请求。", file=sys.stderr)
        print("请先按 README.md 把浏览器 Cookie 保存到 cookies/ 目录（或直接用 --cookie 传入）。", file=sys.stderr)
        return 2

    log(f"开始抓取（{now.strftime('%Y-%m-%d %H:%M')}）")
    all_items: list[Item] = []
    reports: list[SourceReport] = []
    fatal: list[str] = []

    def run(platform: str, cookies: dict[str, str]) -> None:
        try:
            if platform == PLATFORM_CHAOXING:
                log("学习通：登录中…")
                items, report = collect_chaoxing(cookies, args, log)
            else:
                log("中国大学MOOC：登录中…")
                items, report = collect_icourse163(cookies, args, log)
            all_items.extend(items)
            reports.append(report)
            if args.probe:
                if report.ok:
                    log(f"  [OK] {PLATFORM_LABEL[platform]} Cookie 有效，{report.courses} 门课程，{report.items} 条待办")
                else:
                    detail = "；".join(report.warnings) or "未登录或没有课程"
                    log(f"  [FAIL] {PLATFORM_LABEL[platform]} Cookie 不可用：{detail}")
        except AuthExpired as exc:
            reports.append(SourceReport(platform, ok=False, warnings=[str(exc)]))
            fatal.append(f"{PLATFORM_LABEL[platform]}：{exc}")
        except HttpError as exc:
            reports.append(SourceReport(platform, ok=False, warnings=[str(exc)]))
            fatal.append(f"{PLATFORM_LABEL[platform]}：{exc}")
        except Exception as exc:  # noqa: BLE001 —— 单个平台炸掉不影响另一个
            reports.append(SourceReport(platform, ok=False, warnings=[f"{type(exc).__name__}: {exc}"]))
            fatal.append(f"{PLATFORM_LABEL[platform]}：{type(exc).__name__}: {exc}")

    for platform in wants:
        if platform in cookie_map:
            run(platform, cookie_map[platform])

    stats = {}
    kept = filter_items(all_items, args.include_all, args.horizon_days, now,
                        args.expired_after_days, stats)
    args.ignored_expired = stats.get("ignored_expired", 0)

    if args.probe:
        log("")
        for report in reports:
            label = PLATFORM_LABEL.get(report.platform, report.platform)
            state = "可用" if report.ok else "不可用"
            log(f"{label}：{state}；课程 {report.courses} 门；抓取 {report.items} 条")
            for warning in report.warnings:
                log(f"  - {warning}")
        return 0 if not fatal else 2

    out_dir = Path(args.out_dir)
    json_path = out_dir / args.json_name
    md_path = out_dir / args.md_name
    try:
        write_json(json_path, kept, reports, args, now)
        write_markdown(md_path, kept, reports, now)
    except OSError as exc:
        print(f"[错误] 写文件失败：{exc}", file=sys.stderr)
        return 1

    log("")
    log(f"共 {len(kept)} 项待办：")
    if not args.quiet:
        print_console(kept, now)
    log("")
    for report in reports:
        for warning in report.warnings:
            log(f"  ⚠️ {PLATFORM_LABEL.get(report.platform, report.platform)}：{warning}")
    log(f"已写入：{json_path}  |  {md_path}")

    if fatal and not kept:
        print("\n".join(f"[失败] {msg}" for msg in fatal), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
