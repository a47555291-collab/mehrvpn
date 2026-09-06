import contextlib
import json
import os
import re
import socket
import sqlite3
import time
from pathlib import Path

NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,47}$")
PERMISSIONS = {"dashboard", "clients.read", "clients.write", "clients.export", "admins", "settings", "audit"}

def valid_name(value):
    if not isinstance(value, str) or not NAME.fullmatch(value) or value.lower() in {"server", "ca"}:
        raise ValueError("Use 1–48 ASCII letters, numbers, underscores or hyphens; do not start with a hyphen.")
    return value

def connect_db(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True); db=sqlite3.connect(path, timeout=15); db.row_factory=sqlite3.Row; db.execute("PRAGMA journal_mode=WAL"); db.execute("PRAGMA foreign_keys=ON"); return db
@contextlib.contextmanager
def transaction(path):
    db=connect_db(path)
    try: db.execute("BEGIN IMMEDIATE"); yield db; db.commit()
    except Exception: db.rollback(); raise
    finally: db.close()
def rpc(action,payload=None,hook=False):
    path=os.environ.get("MEHRVPN_HOOK_SOCKET" if hook else "MEHRVPN_AGENT_SOCKET", "/run/mehrvpn/hook.sock" if hook else "/run/mehrvpn/control.sock")
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as sock:
        sock.settimeout(100 if action in {"create","revoke"} else 10); sock.connect(path); sock.sendall(json.dumps({"action":action,"payload":payload or {}}).encode()+b"\n"); buffer=b""
        while not buffer.endswith(b"\n"):
            chunk=sock.recv(65536)
            if not chunk: raise ConnectionError("Agent connection closed")
            buffer+=chunk
            if len(buffer)>8*1024*1024: raise ValueError("Agent response too large")
    result=json.loads(buffer)
    if not result.get("ok"): raise ValueError(result.get("error","Agent operation failed"))
    return result.get("data")
def client_state(client,now=None):
    now=time.time() if now is None else now
    if client["state"]!="active": return client["state"]
    if client["expires_at"] and client["expires_at"]<=now: return "expired"
    if client["quota_bytes"] and client["upload"]+client["download"]>=client["quota_bytes"]: return "quota"
    return "active"
