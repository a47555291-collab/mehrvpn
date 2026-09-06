import hashlib
import json
import secrets
import time
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError
from .core import transaction, PERMISSIONS
HASHER=PasswordHasher(); DUMMY=HASHER.hash(secrets.token_urlsafe(32))
def digest(value): return hashlib.sha256(value.encode()).hexdigest()
def hash_password(password):
    if len(password)<12 or len(password)>256: raise ValueError("Password must contain 12–256 characters")
    return HASHER.hash(password)
def init_auth(path):
    with transaction(path) as db:
        db.executescript('''CREATE TABLE IF NOT EXISTS admins (username TEXT PRIMARY KEY,password TEXT NOT NULL,permissions TEXT NOT NULL,owner INTEGER NOT NULL DEFAULT 0,enabled INTEGER NOT NULL DEFAULT 1); CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY,username TEXT NOT NULL REFERENCES admins(username) ON DELETE CASCADE,csrf TEXT NOT NULL,expires_at INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS attempts (subject TEXT NOT NULL,at INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS attempt_subject ON attempts(subject,at); CREATE TABLE IF NOT EXISTS audit (id INTEGER PRIMARY KEY,at INTEGER NOT NULL,actor TEXT NOT NULL,action TEXT NOT NULL,target TEXT NOT NULL,result TEXT NOT NULL); CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS shares (token TEXT PRIMARY KEY,client TEXT NOT NULL,expires_at INTEGER NOT NULL,actor TEXT NOT NULL);''')
def audit(path,actor,action,target="",result="ok"):
    with transaction(path) as db: db.execute("INSERT INTO audit(at,actor,action,target,result) VALUES(?,?,?,?,?)",(int(time.time()),actor,action,target,result))
def login(path,username,password,ip):
    now=int(time.time()); subjects=["user:"+username.lower(),"ip:"+ip]
    with transaction(path) as db:
        db.execute("DELETE FROM attempts WHERE at<?",(now-900,))
        for subject,limit in zip(subjects,[5,30]):
            if db.execute("SELECT COUNT(*) FROM attempts WHERE subject=?",(subject,)).fetchone()[0]>=limit: raise ValueError("Too many attempts. Try again in 15 minutes.")
        for subject in subjects: db.execute("INSERT INTO attempts VALUES(?,?)",(subject,now))
        row=db.execute("SELECT * FROM admins WHERE username=?",(username,)).fetchone()
    try: valid=HASHER.verify(row["password"] if row else DUMMY,password)
    except (VerificationError,InvalidHashError): valid=False
    if not valid or not row or not row["enabled"]: audit(path,username,"login",result="denied"); raise ValueError("Incorrect username or password")
    token,csrf=secrets.token_urlsafe(48),secrets.token_urlsafe(32)
    with transaction(path) as db:
        db.execute("DELETE FROM attempts WHERE subject=?",(subjects[0],)); db.execute("DELETE FROM sessions WHERE expires_at<?",(now,)); db.execute("INSERT INTO sessions VALUES(?,?,?,?)",(digest(token),username,csrf,now+8*3600))
    audit(path,username,"login"); return token,csrf
def session(path,token):
    with transaction(path) as db: row=db.execute("SELECT a.username,a.permissions,a.owner,a.enabled,s.csrf FROM sessions s JOIN admins a ON s.username=a.username WHERE s.token=? AND s.expires_at>?",(digest(token),int(time.time()))).fetchone()
    if not row or not row["enabled"]: return None
    data=dict(row); data["permissions"]=sorted(PERMISSIONS) if data["owner"] else json.loads(data["permissions"]); return data
