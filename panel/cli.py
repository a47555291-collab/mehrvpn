import argparse
import getpass
import json
import os
from .auth import init_auth, hash_password, audit
from .core import transaction, valid_name, PERMISSIONS

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["owner", "reset-password"])
    parser.add_argument("--username", default="admin")
    args = parser.parse_args()
    name = valid_name(args.username)
    path = os.environ.get("MEHRVPN_DB", "/var/lib/mehrvpn/panel.db")
    init_auth(path)
    password = getpass.getpass("Password (at least 12 characters): ")
    if password != getpass.getpass("Repeat password: "):
        raise SystemExit("Passwords do not match")
    hashed = hash_password(password)
    with transaction(path) as db:
        if args.command == "owner":
            if db.execute("SELECT 1 FROM admins WHERE owner=1").fetchone():
                raise SystemExit("An owner already exists. Use reset-password if needed.")
            db.execute("INSERT INTO admins(username,password,permissions,owner) VALUES(?,?,?,1)", (name, hashed, json.dumps(sorted(PERMISSIONS))))
        else:
            if db.execute("UPDATE admins SET password=? WHERE username=?", (hashed, name)).rowcount != 1:
                raise SystemExit("Administrator not found")
            db.execute("DELETE FROM sessions WHERE username=?", (name,))
    audit(path, "local-console", args.command, name)
    print("Account saved.")

if __name__ == "__main__":
    main()
