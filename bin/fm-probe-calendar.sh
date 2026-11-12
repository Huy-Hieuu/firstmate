#!/usr/bin/env bash
# fm-probe-calendar.sh - daily brief source: the captain's meetings in the next
# 36 hours from private iCal (ICS) feeds, read-only.
#
# Reads config/calendar (local, gitignored), key=value lines:
#   ics=<url>     one per calendar, for example Google Calendar's "secret
#                 address in iCal format"; the URL is itself a secret, so it
#                 lives only in this local file
#   me=<email>    optional, repeatable; the captain's own addresses, left out
#                 of attendee lists, and an event he declined is skipped
# Fetches each feed with one GET and prints one NDJSON day row per event
# occurrence starting within FM_PROBE_CALENDAR_HOURS (default 36) hours:
# id, title, start, end (epoch), allday, join (a Meet, Zoom, or Teams link),
# attendees, keys (ticket keys such as ABC-123 in the title or description),
# clash (overlaps another timed event), and remind_at (10 minutes before a
# timed event). Daily and weekly RRULEs (with BYDAY), monthly and yearly ones
# on the start date, INTERVAL, COUNT, UNTIL, EXDATE, moved instances, and
# cancelled events are handled; other rule parts are ignored. Exit 3 when a feed host is unreachable, 1 on a missing config or any
# other failure. Run it through `fm-daily-brief.sh source calendar`.
# FM_BRIEF_NOW=<epoch> overrides the clock for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONF="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/calendar"

[ -f "$CONF" ] || { echo "fm-probe-calendar: config/calendar is missing; add ics=<private iCal URL> (see the script header)" >&2; exit 1; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe-calendar.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
n=0
while IFS= read -r line; do
  case "$line" in
    ics=?*) ;;
    *) continue ;;
  esac
  n=$((n + 1))
  rc=0
  curl -sS -f -L --max-time 15 -o "$TMP/$n.ics" -- "${line#ics=}" || rc=$?
  case "$rc" in
    0) ;;
    6|7|28) exit 3 ;;
    *) echo "fm-probe-calendar: feed $n failed (curl exit $rc)" >&2; exit 1 ;;
  esac
done < "$CONF"
[ "$n" -gt 0 ] || { echo "fm-probe-calendar: config/calendar has no ics= line" >&2; exit 1; }

ME=$(awk 'index($0, "me=") == 1 { print tolower(substr($0, 4)) }' "$CONF")
NOW=${FM_BRIEF_NOW:-$(date +%s)} HOURS=${FM_PROBE_CALENDAR_HOURS:-36} ME=$ME \
  python3 - "$TMP"/*.ics <<'PY'
import datetime as dt, json, os, re, sys
from zoneinfo import ZoneInfo

UTC = dt.timezone.utc
now = dt.datetime.fromtimestamp(int(os.environ["NOW"]), UTC)
end_w = now + dt.timedelta(hours=int(os.environ["HOURS"]))
me = {m for m in os.environ.get("ME", "").split() if m}
local = dt.datetime.now().astimezone().tzinfo
JOIN = re.compile(r"https://(?:[\w-]+\.)*(?:meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com)/[^\s\"<>\\,;]+")
KEY = re.compile(r"\b[A-Z][A-Z0-9]+-\d+\b")
DAYS = {"MO": 0, "TU": 1, "WE": 2, "TH": 3, "FR": 4, "SA": 5, "SU": 6}

def unfold(text):
    out = []
    for raw in text.replace("\r\n", "\n").split("\n"):
        if raw[:1] in (" ", "\t") and out:
            out[-1] += raw[1:]
        else:
            out.append(raw)
    return out

def unescape(v):
    return v.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")

def parse_events(text):
    events, cur = [], None
    for line in unfold(text):
        if line == "BEGIN:VEVENT":
            cur = {}
        elif line == "END:VEVENT":
            if cur is not None:
                events.append(cur)
            cur = None
        elif cur is not None and ":" in line:
            head, value = line.split(":", 1)
            name, *params = head.split(";")
            p = dict(x.split("=", 1) for x in params if "=" in x)
            cur.setdefault(name.upper(), []).append((p, value))
    return events

def when(prop):
    p, v = prop
    v = v.strip()
    if p.get("VALUE") == "DATE" or re.fullmatch(r"\d{8}", v):
        return dt.datetime.strptime(v[:8], "%Y%m%d").replace(tzinfo=local), True
    if v.endswith("Z"):
        return dt.datetime.strptime(v, "%Y%m%dT%H%M%SZ").replace(tzinfo=UTC), False
    naive = dt.datetime.strptime(v, "%Y%m%dT%H%M%S")
    tz = local
    if "TZID" in p:
        try:
            tz = ZoneInfo(p["TZID"].strip('"'))
        except Exception:
            tz = local
    return naive.replace(tzinfo=tz), False

def first(ev, name, default=""):
    return ev[name][0][1] if name in ev else default

def occurrences(ev, start):
    """Yield occurrence starts of a recurring event up to the window end."""
    rule = dict(x.split("=", 1) for x in first(ev, "RRULE").split(";") if "=" in x)
    freq = rule.get("FREQ", "")
    interval = int(rule.get("INTERVAL", "1") or 1)
    count = int(rule["COUNT"]) if "COUNT" in rule else None
    until = None
    if "UNTIL" in rule:
        until, _ = when(({}, rule["UNTIL"]))
    byday = [DAYS[d[-2:]] for d in rule.get("BYDAY", "").split(",") if d[-2:] in DAYS]
    tz = start.tzinfo
    d0 = start.date()
    day, seen = d0, 0
    while True:
        cand = dt.datetime.combine(day, start.timetz().replace(tzinfo=None)).replace(tzinfo=tz)
        if cand > end_w or (until and cand > until):
            return
        delta = (day - d0).days
        months = (day.year - d0.year) * 12 + day.month - d0.month
        if freq == "DAILY":
            hit = delta % interval == 0 and (not byday or day.weekday() in byday)
        elif freq == "WEEKLY":
            week = ((day - dt.timedelta(days=day.weekday())) - (d0 - dt.timedelta(days=d0.weekday()))).days // 7
            hit = week % interval == 0 and day.weekday() in (byday or [d0.weekday()])
        elif freq == "MONTHLY":
            hit = months % interval == 0 and day.day == d0.day
        elif freq == "YEARLY":
            hit = (day.year - d0.year) % interval == 0 and (day.month, day.day) == (d0.month, d0.day)
        else:
            return
        if hit:
            seen += 1
            if count is not None and seen > count:
                return
            yield cand
        day += dt.timedelta(days=1)

rows = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8", errors="replace") as f:
        events = parse_events(f.read())
    moved = {}
    for ev in events:
        if "RECURRENCE-ID" in ev:
            rid, _ = when(ev["RECURRENCE-ID"][0])
            moved[(first(ev, "UID"), rid.astimezone(UTC))] = ev
    for ev in events:
        if "DTSTART" not in ev or "RECURRENCE-ID" in ev:
            continue
        start, allday = when(ev["DTSTART"][0])
        if "DTEND" in ev:
            length = when(ev["DTEND"][0])[0] - start
        else:
            length = dt.timedelta(days=1) if allday else dt.timedelta(0)
        exdates = set()
        for p, v in ev.get("EXDATE", []):
            for one in v.split(","):
                exdates.add(when((p, one))[0].astimezone(UTC))
        starts = occurrences(ev, start) if "RRULE" in ev else [start]
        for s in starts:
            key = (first(ev, "UID"), s.astimezone(UTC))
            if key[1] in exdates:
                continue
            inst, s0, ln = ev, s, length
            if key in moved:
                inst = moved[key]
                s0, _ = when(inst["DTSTART"][0])
                ln = (when(inst["DTEND"][0])[0] - s0) if "DTEND" in inst else length
            rows.append((inst, s0, s0 + ln, allday, key[0]))

out = []
for inst, s, e, allday, uid in rows:
    if first(inst, "STATUS").upper() == "CANCELLED":
        continue
    if not (s < end_w and e > now):
        continue
    people, declined = [], False
    for p, v in inst.get("ATTENDEE", []):
        mail = v.split(":", 1)[-1].strip().lower()
        if mail in me:
            declined = declined or p.get("PARTSTAT", "").upper() == "DECLINED"
            continue
        if p.get("CUTYPE", "INDIVIDUAL").upper() not in ("INDIVIDUAL", ""):
            continue
        people.append(p.get("CN", mail).strip('"'))
    if declined:
        continue
    title = unescape(first(inst, "SUMMARY", "(no title)"))
    text = " ".join(unescape(first(inst, k)) for k in ("LOCATION", "DESCRIPTION", "X-GOOGLE-CONFERENCE", "URL"))
    join = JOIN.search(text)
    row = {
        "id": "cal:%s:%d" % (uid, int(s.timestamp())),
        "section": "day",
        "title": title,
        "start": int(s.timestamp()),
        "end": int(e.timestamp()),
        "allday": allday,
        "join": join.group(0) if join else "",
        "attendees": people,
        "keys": sorted(set(KEY.findall(title + " " + text))),
    }
    if not allday:
        row["remind_at"] = row["start"] - 600
    out.append(row)

out.sort(key=lambda r: r["start"])
for r in out:
    r["clash"] = (not r["allday"]) and any(
        o is not r and not o["allday"] and o["start"] < r["end"] and r["start"] < o["end"] for o in out)
    print(json.dumps(r, ensure_ascii=False))
PY
