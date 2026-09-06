"""Durable, idempotent accounting. Values are VPN payload bytes, not NIC totals."""
import time
from .core import transaction, client_state
class Accounting:
    def __init__(self,path):
        self.path=path
        with transaction(path) as db: db.executescript('''CREATE TABLE IF NOT EXISTS clients (name TEXT PRIMARY KEY,label TEXT NOT NULL DEFAULT '',state TEXT NOT NULL DEFAULT 'provisioning',quota_bytes INTEGER NOT NULL DEFAULT 0 CHECK(quota_bytes>=0),expires_at INTEGER,upload INTEGER NOT NULL DEFAULT 0,download INTEGER NOT NULL DEFAULT 0,created_at INTEGER NOT NULL,note TEXT NOT NULL DEFAULT '',error TEXT NOT NULL DEFAULT ''); CREATE TABLE IF NOT EXISTS counters (session TEXT PRIMARY KEY,name TEXT NOT NULL,upload INTEGER NOT NULL,download INTEGER NOT NULL,updated_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);''')
    def list(self):
        with transaction(self.path) as db: rows=[dict(r) for r in db.execute("SELECT * FROM clients ORDER BY created_at DESC")]
        for r in rows: r["effective_state"]=client_state(r)
        return rows
    def add(self,name,**fields):
        with transaction(self.path) as db: db.execute("INSERT INTO clients(name,label,quota_bytes,expires_at,created_at,note) VALUES(?,?,?,?,?,?)",(name,fields.get("label",name),fields.get("quota_bytes",0),fields.get("expires_at"),int(time.time()),fields.get("note","")))
    def update(self,name,**fields):
        allowed={"state","label","quota_bytes","expires_at","note","error"}
        if not fields or not set(fields)<=allowed: raise ValueError("Invalid client changes")
        with transaction(self.path) as db:
            if db.execute("UPDATE clients SET "+",".join(k+"=?" for k in fields)+" WHERE name=?",(*fields.values(),name)).rowcount!=1: raise ValueError("Client not found")
    def account(self,name,session,upload,download):
        if upload<0 or download<0: raise ValueError("Negative counter")
        with transaction(self.path) as db:
            row=db.execute("SELECT * FROM counters WHERE session=?",(session,)).fetchone()
            if row and row["name"]!=name: raise ValueError("Session owner mismatch")
            old_up,old_down=(row["upload"],row["download"]) if row else (0,0); up,down=max(upload,old_up),max(download,old_down)
            db.execute("UPDATE clients SET upload=upload+?,download=download+? WHERE name=?",(up-old_up,down-old_down,name)); db.execute("INSERT INTO counters VALUES(?,?,?,?,?) ON CONFLICT(session) DO UPDATE SET upload=excluded.upload,download=excluded.download,updated_at=excluded.updated_at",(session,name,up,down,int(time.time())))
    def reset(self,name):
        with transaction(self.path) as db: db.execute("UPDATE clients SET upload=0,download=0 WHERE name=?",(name,))
    def allowed(self,name):
        with transaction(self.path) as db: row=db.execute("SELECT * FROM clients WHERE name=?",(name,)).fetchone()
        return bool(row and client_state(row)=="active")
def parse_status(text):
    headers,result=None,[]
    for line in text.splitlines():
        values=line.split("\t")
        if values[:2]==["HEADER","CLIENT_LIST"]: headers=values[2:]
        elif values[0]=="CLIENT_LIST" and headers:
            row=dict(zip(headers,values[1:])); result.append({"name":row["Common Name"],"remote":row["Real Address"],"vpn_ip":row.get("Virtual Address",""),"since":int(row["Connected Since (time_t)"]),"upload":int(row["Bytes Received"]),"download":int(row["Bytes Sent"])})
    if "END" not in text.splitlines(): raise ValueError("Incomplete OpenVPN status")
    return result
def session_key(name,remote,since): return f"{name}|{remote}|{int(since)}"
