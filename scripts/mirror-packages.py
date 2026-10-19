#!/usr/bin/env python3
"""Mirror packages/ to apps.zombie.digital/downloads/packages/ over SFTP.

Uses the same credential env file and host-key policy as the apps'
Publish-Linux.py scripts (SSH_HOST, SSH_USER, SSH_PORT, SSH_PASSWORD; the host
must already be in ~/.ssh/known_hosts). Each file is uploaded under a temporary
name and renamed into place; packages and hashed metadata go first, the signed
index files (repomd.xml, InRelease, *.db) last, and files that are no longer in
packages/ are removed only after that, so clients never see an index that names
a missing file.

Usage: scripts/mirror-packages.py --env-file ~/git/zombie-digital/.env.raspi
"""
import argparse
import hashlib
from pathlib import Path
import posixpath
import stat
import uuid

ROOT = Path(__file__).resolve().parents[1]
LOCAL = ROOT / "packages"
INDEX_NAMES = {"repomd.xml", "repomd.xml.asc", "InRelease", "Release", "Release.gpg"}


def is_index(rel):
    name = posixpath.basename(rel)
    return name in INDEX_NAMES or ".db" in name or ".files" in name


def credentials(env_file):
    if env_file.is_symlink() or not env_file.is_file() or env_file.stat().st_size > 16384:
        raise SystemExit("Supply a regular credential env file of at most 16 KiB")
    values = {}
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key not in {"SSH_HOST", "SSH_USER", "SSH_PORT", "SSH_PASSWORD"}:
            continue
        if not sep or key in values:
            raise SystemExit("Invalid SSH configuration")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    if not values.get("SSH_HOST") or not values.get("SSH_USER"):
        raise SystemExit("SSH host and user are required")
    values.setdefault("SSH_PORT", "22")
    return values


def remote_files(sftp, root):
    found = {}
    def walk(path, rel):
        try:
            entries = sftp.listdir_attr(path)
        except FileNotFoundError:
            return
        for e in entries:
            child_rel = posixpath.join(rel, e.filename) if rel else e.filename
            if stat.S_ISDIR(e.st_mode):
                walk(posixpath.join(path, e.filename), child_rel)
            elif not e.filename.startswith(".upload-"):
                found[child_rel] = e.st_size
    walk(root, "")
    return found


def makedirs(sftp, path):
    parts = []
    while True:
        try:
            sftp.stat(path)
            break
        except FileNotFoundError:
            parts.append(path)
            path = posixpath.dirname(path)
    for p in reversed(parts):
        sftp.mkdir(p, 0o755)


def upload(sftp, local, remote):
    makedirs(sftp, posixpath.dirname(remote))
    temp = posixpath.join(posixpath.dirname(remote), f".upload-{uuid.uuid4().hex}")
    sftp.put(str(local), temp)
    if sftp.stat(temp).st_size != local.stat().st_size:
        sftp.remove(temp)
        raise SystemExit(f"size mismatch after upload: {remote}")
    sftp.chmod(temp, 0o644)
    sftp.posix_rename(temp, remote)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--remote-root", default="/mnt/data/sites/apps/public/downloads/packages")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = args.remote_root
    if not root.startswith("/") or root == "/" or posixpath.normpath(root) != root:
        raise SystemExit("Remote root must be a normalized absolute directory")

    local = {p.relative_to(LOCAL).as_posix(): p for p in sorted(LOCAL.rglob("*")) if p.is_file()}
    creds = credentials(args.env_file)
    import paramiko
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    client.set_missing_host_key_policy(paramiko.RejectPolicy())
    password = creds.get("SSH_PASSWORD") or None
    client.connect(hostname=creds["SSH_HOST"], port=int(creds["SSH_PORT"]), username=creds["SSH_USER"],
                   password=password, timeout=10, banner_timeout=10, auth_timeout=10,
                   allow_agent=not password, look_for_keys=not password)
    try:
        sftp = client.open_sftp()
        remote = remote_files(sftp, root)
        changed = [rel for rel, path in local.items()
                   if is_index(rel) or remote.get(rel) != path.stat().st_size]
        stale = sorted(set(remote) - set(local))
        ordered = [r for r in changed if not is_index(r)] + \
                  sorted((r for r in changed if is_index(r)),
                         key=lambda r: (r.endswith("repomd.xml") or r.endswith("InRelease"), r))
        for rel in ordered:
            print(("would upload " if args.dry_run else "upload ") + rel)
            if not args.dry_run:
                upload(sftp, local[rel], posixpath.join(root, rel))
        for rel in stale:
            print(("would remove " if args.dry_run else "remove ") + rel)
            if not args.dry_run:
                sftp.remove(posixpath.join(root, rel))
        print(f"mirror: {len(ordered)} uploaded, {len(stale)} removed, {len(local)} files")
    finally:
        client.close()


if __name__ == "__main__":
    main()
