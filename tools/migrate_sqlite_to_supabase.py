"""
Move data from the Streamlit app's SQLite database into Supabase.
-------------------------------------------------------------------
Run ONCE, after supabase/cvp_attendance_schema.sql has been executed.

    python migrate_sqlite_to_supabase.py --db ..\\CVP_Streamlit_Attendance\\data\\cvp_attendance.sqlite3 --dry-run
    python migrate_sqlite_to_supabase.py --db ..\\CVP_Streamlit_Attendance\\data\\cvp_attendance.sqlite3

Needs two environment variables (Supabase Dashboard -> Project Settings -> API):
    SUPABASE_URL               https://xxxx.supabase.co
    SUPABASE_SERVICE_ROLE_KEY  the secret "service_role" key (keep it private!)

What it copies
    users            -> login accounts + profiles (NEW temporary passwords, saved to
                        migrated_passwords.csv, because old password hashes cannot be reused)
    leave_types      -> leave_types
    holidays         -> holidays
    punches          -> attendance (first IN and last OUT per employee per day)
    leaves           -> leaves
    regularizations  -> regularizations
    selfie_records   -> photos uploaded to the "selfies" bucket + selfie_records
    audit_log        -> audit_log

Only Python's standard library is used (no pip install needed).
"""
import argparse
import csv
import json
import os
import secrets
import sqlite3
import string
import sys
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone, timedelta

IST = timezone(timedelta(hours=5, minutes=30))
LEAVE_ORDER = {"Casual Leave": 10, "Sick Leave": 20, "Annual Leave": 30, "Compensatory Off": 40, "Loss of Pay": 50}


# --------------------------------------------------------------------------- helpers
def to_ts(value):
    """SQLite ISO text -> ISO timestamp with IST offset (if none given)."""
    if not value:
        return None
    dt = datetime.fromisoformat(str(value))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=IST)
    return dt.isoformat()


def ist_date(value):
    return datetime.fromisoformat(to_ts(value)).astimezone(IST).date().isoformat()


def ist_hm(value):
    return datetime.fromisoformat(to_ts(value)).astimezone(IST).strftime("%H:%M")


def temp_password():
    alphabet = string.ascii_letters + string.digits
    return "Cvp@" + "".join(secrets.choice(alphabet) for _ in range(12))


class Supabase:
    def __init__(self, url, key, dry):
        self.url, self.key, self.dry = url.rstrip("/"), key, dry

    def _req(self, method, path, body=None, headers=None, raw=None, content_type="application/json"):
        if self.dry:
            return {}
        h = {"apikey": self.key, "Authorization": f"Bearer {self.key}"}
        h.update(headers or {})
        data = raw
        if body is not None:
            data = json.dumps(body).encode()
        if data is not None:
            h["Content-Type"] = content_type
        req = urllib.request.Request(self.url + path, data=data, headers=h, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                txt = r.read().decode() or "{}"
                return json.loads(txt) if txt.strip().startswith(("{", "[")) else {}
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path} -> {e.code}: {e.read().decode()[:400]}") from None

    def insert(self, table, rows, upsert_on=None, returning=False):
        if not rows:
            return []
        path = f"/rest/v1/{table}"
        prefer = ["return=representation" if returning else "return=minimal"]
        if upsert_on:
            path += "?on_conflict=" + urllib.parse.quote(upsert_on)
            prefer.append("resolution=merge-duplicates")
        out = []
        for i in range(0, len(rows), 500):
            res = self._req("POST", path, rows[i:i + 500], {"Prefer": ",".join(prefer)})
            if isinstance(res, list):
                out.extend(res)
        return out

    def update(self, table, match, values):
        q = "&".join(f"{k}=eq.{urllib.parse.quote(str(v))}" for k, v in match.items())
        return self._req("PATCH", f"/rest/v1/{table}?{q}", values, {"Prefer": "return=minimal"})

    def select(self, table, query):
        if self.dry:
            return []
        return self._req("GET", f"/rest/v1/{table}?{query}")

    def create_user(self, email, password, meta):
        return self._req("POST", "/auth/v1/admin/users",
                         {"email": email, "password": password, "email_confirm": True, "user_metadata": meta})

    def find_user_id_by_username(self, username):
        rows = self.select("profiles", f"select=id&username=eq.{urllib.parse.quote(username)}")
        return rows[0]["id"] if rows else None

    def upload(self, bucket, path, data, mime):
        return self._req("POST", f"/storage/v1/object/{bucket}/{urllib.parse.quote(path)}",
                         raw=data, content_type=mime, headers={"x-upsert": "true"})


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True, help="path to cvp_attendance.sqlite3")
    ap.add_argument("--email-domain", default="cvp-attendance.app",
                    help="domain for generated login e-mails (username@domain). Users still log in with username.")
    ap.add_argument("--dry-run", action="store_true", help="only print what would be migrated")
    args = ap.parse_args()

    url, key = os.getenv("SUPABASE_URL", ""), os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")
    if not args.dry_run and (not url or not key):
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (or use --dry-run).")
    sb = Supabase(url, key, args.dry_run)

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    q = lambda sql: [dict(r) for r in con.execute(sql).fetchall()]
    tables = {r["name"] for r in q("SELECT name FROM sqlite_master WHERE type='table'")}
    get = lambda t: q(f'SELECT * FROM "{t}"') if t in tables else []

    users = get("users")
    print(f"Users: {len(users)}")

    # ---- 1. login accounts + profiles
    id_map, passwords = {}, []
    for u in users:
        username = u["username"].strip().lower()
        email = f"{username}@{args.email_domain}"
        pw = temp_password()
        if args.dry_run:
            id_map[u["id"]] = f"<new-uuid-for-{username}>"
        else:
            existing = sb.find_user_id_by_username(username)
            if existing:
                id_map[u["id"]] = existing
                print(f"  = {username} already exists, reusing")
                pw = "(unchanged - account existed)"
            else:
                res = sb.create_user(email, pw, {"username": username, "full_name": u["full_name"],
                                                 "department": u.get("department") or ""})
                id_map[u["id"]] = res["id"]
        sb.update("profiles", {"id": id_map[u["id"]]}, {
            "username": username,
            "full_name": u["full_name"],
            "role": u["role"] if u["role"] in ("Employee", "HR", "Admin") else "Employee",
            "department": u.get("department"),
            "shift_start": (u.get("shift_start") or "09:00")[:5],
            "shift_end": (u.get("shift_end") or "18:00")[:5],
            "active": bool(int(u.get("active") or 0)),
            "site_employee": bool(int(u.get("site_employee") or 0)),
        })
        passwords.append({"username": username, "full_name": u["full_name"], "role": u["role"], "temporary_password": pw})
        print(f"  + {username:<20} {u['role']}")

    # ---- 2. leave types + holidays
    lt = [{"name": r["name"], "annual_quota": int(r["annual_quota"]), "counts_balance": r["name"] != "Loss of Pay",
           "sort_order": LEAVE_ORDER.get(r["name"], 100)} for r in get("leave_types")]
    sb.insert("leave_types", lt, upsert_on="name")
    print(f"Leave types: {len(lt)}")
    hol = [{"day": r["day"], "name": r["name"], "kind": r["kind"] if r["kind"] in ("General", "Restricted") else "General"}
           for r in get("holidays")]
    sb.insert("holidays", hol, upsert_on="day")
    print(f"Holidays: {len(hol)}")

    # ---- 3. punches -> one attendance row per user per IST day
    shift = {u["id"]: (u.get("shift_start") or "09:00")[:5] for u in users}
    days = defaultdict(lambda: {"IN": None, "OUT": None})
    for p in sorted(get("punches"), key=lambda r: r["punched_at"]):
        k = (p["user_id"], ist_date(p["punched_at"]))
        if p["user_id"] not in id_map:
            continue
        if p["kind"] == "IN" and days[k]["IN"] is None:
            days[k]["IN"] = p["punched_at"]
        if p["kind"] == "OUT":
            days[k]["OUT"] = p["punched_at"]
    selfie_days = {(s["user_id"], ist_date(s["captured_at"])): s.get("site_name") for s in get("selfie_records")}
    att = []
    for (uid, d), v in days.items():
        if not v["IN"]:
            continue
        out = v["OUT"] if v["OUT"] and to_ts(v["OUT"]) > to_ts(v["IN"]) else None
        att.append({
            "user_id": id_map[uid], "work_date": d,
            "check_in_at": to_ts(v["IN"]), "check_out_at": to_ts(out),
            "is_late": ist_hm(v["IN"]) > shift.get(uid, "09:00"),
            "source": "site" if (uid, d) in selfie_days else "office",
            "site_name": selfie_days.get((uid, d)),
        })
    sb.insert("attendance", att, upsert_on="user_id,work_date")
    print(f"Attendance days: {len(att)}")

    # ---- 4. leaves + regularizations
    lv = [{
        "user_id": id_map[r["user_id"]], "leave_type": r["leave_type"], "from_day": r["from_day"], "to_day": r["to_day"],
        "days": max(1, int(r["days"])), "reason": r.get("reason") or "-", "status": r["status"],
        "reviewed_by": id_map.get(r.get("reviewed_by")), "reviewed_at": to_ts(r.get("reviewed_at")),
    } for r in get("leaves") if r["user_id"] in id_map]
    sb.insert("leaves", lv)
    print(f"Leaves: {len(lv)}")
    rg = [{
        "user_id": id_map[r["user_id"]], "day": r["day"],
        "requested_in": r.get("requested_in") or "09:00", "requested_out": r.get("requested_out") or "18:00",
        "reason": r.get("reason") or "-", "status": r["status"],
        "reviewed_by": id_map.get(r.get("reviewed_by")), "reviewed_at": to_ts(r.get("reviewed_at")),
    } for r in get("regularizations") if r["user_id"] in id_map]
    sb.insert("regularizations", rg)
    print(f"Regularizations: {len(rg)}")

    # ---- 5. selfies (photo -> storage, record -> table)
    att_ids = {}
    if not args.dry_run and att:
        for row in sb.select("attendance", "select=id,user_id,work_date"):
            att_ids[(row["user_id"], row["work_date"])] = row["id"]
    n = 0
    for s in get("selfie_records"):
        if s["user_id"] not in id_map or not s.get("image_blob"):
            continue
        uid = id_map[s["user_id"]]
        mime = s.get("mime_type") or "image/jpeg"
        ext = {"image/png": "png", "image/webp": "webp"}.get(mime, "jpg")
        path = f"{uid}/migrated_{s['id']}_{s['kind']}.{ext}"
        sb.upload("selfies", path, bytes(s["image_blob"]), mime)
        sb.insert("selfie_records", [{
            "user_id": uid, "attendance_id": att_ids.get((uid, ist_date(s["captured_at"]))),
            "captured_at": to_ts(s["captured_at"]), "kind": s["kind"],
            "site_name": s.get("site_name") or "Site", "note": s.get("note"), "photo_path": path,
        }])
        n += 1
    print(f"Selfies: {n}")

    # ---- 6. audit log
    au = [{"actor_id": id_map.get(r.get("actor_id")), "action": r["action"], "detail": r.get("detail"),
           "logged_at": to_ts(r["logged_at"])} for r in get("audit_log")]
    sb.insert("audit_log", au)
    print(f"Audit events: {len(au)}")

    if not args.dry_run:
        with open("migrated_passwords.csv", "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["username", "full_name", "role", "temporary_password"])
            w.writeheader()
            w.writerows(passwords)
        print("\nDONE. Temporary passwords saved to migrated_passwords.csv - share them privately,")
        print("ask everyone to change their password from My Profile, then DELETE that file.")
    else:
        print("\nDry run only - nothing was written.")


if __name__ == "__main__":
    main()
