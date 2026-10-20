#!/usr/bin/env bash
# Add packages to the combined "joenilan apps" dnf and apt repositories under
# packages/, re-sign the repository metadata and commit (and push) the site.
#
#   packages/rpm/   RPM repository: signed packages, repodata + repomd.xml.asc
#   packages/deb/   apt repository: pool/ and dists/stable (InRelease, Release.gpg)
#   packages/arch/x86_64/  pacman repository: signed packages and joenilan-apps.db
#   packages/joenilan-apps.{asc,gpg,repo,sources,pacman.conf}: key and repository files
#
# Unsigned RPMs are signed here (rpmsign); Arch packages get detached .sig
# files; .deb packages are covered by the signed apt metadata. The pacman
# database is built with repo-add in an archlinux container (podman). The newest KEEP
# versions of each package stay. Signing asks for the key's passphrase through
# gpg-agent. Served by GitHub Pages at https://joenilan.github.io/packages/ and
# mirrored to https://apps.zombie.digital/downloads/packages/ by
# scripts/mirror-packages.py; the repository files list both.
#
# Usage: scripts/publish-packages.sh [--no-push] [package.rpm|.deb|.pkg.tar.zst ...]
#   With no packages, only regenerates and re-signs the metadata.
#   After pushing, the apps.zombie.digital mirror is refreshed with
#   scripts/mirror-packages.py using MIRROR_ENV_FILE (default
#   ~/git/zombie-digital/.env.raspi); set MIRROR_ENV_FILE= to skip it.
#
# Each app's own publish step calls this script (LinX: packaging/
# publish-repo.sh; Jawjack and Haiwire: scripts/Publish-Linux.py --publish).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO="$ROOT/packages"
KEY=${PACKAGES_SIGNING_KEY:-E72D6EE9C417012ECE280124E14B87807621D25D}
BASE_URL=https://joenilan.github.io/packages
MIRROR_URL=https://apps.zombie.digital/downloads/packages
KEEP=3
PUSH=1
FILES=()
for arg in "$@"; do
  case "$arg" in
    --no-push) PUSH=0 ;;
    *.rpm|*.deb|*.pkg.tar.zst) FILES+=("$(realpath "$arg")") ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

die() { echo "publish-packages: $*" >&2; exit 1; }
command -v createrepo_c >/dev/null || die "createrepo_c is not installed (sudo dnf install createrepo_c)"
gpg --list-secret-keys "$KEY" >/dev/null 2>&1 || die "signing key $KEY is not available"

mkdir -p "$REPO/rpm" "$REPO/deb/pool/main" "$REPO/arch/x86_64"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || die "no such file: $f"
  case "$f" in
    *.rpm)
      cp "$f" "$REPO/rpm/"
      dest="$REPO/rpm/$(basename "$f")"
      if ! rpm -qp --qf '%{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}%{OPENPGP:pgpsig}\n' "$dest" 2>/dev/null \
          | grep -qi "${KEY: -16}"; then
        rpmsign --addsign --define "_gpg_name $KEY" "$dest" >/dev/null
      fi
      ;;
    *.pkg.tar.zst)
      cp "$f" "$REPO/arch/x86_64/"
      dest="$REPO/arch/x86_64/$(basename "$f")"
      gpg --batch --yes -u "$KEY" --detach-sign -o "$dest.sig" "$dest"
      ;;
    *.deb)
      name=$(basename "$f"); name=${name%%_*}
      mkdir -p "$REPO/deb/pool/main/${name:0:1}/$name"
      cp "$f" "$REPO/deb/pool/main/${name:0:1}/$name/"
      ;;
  esac
done

# Keep the newest KEEP versions of each package, ordered the way dnf, apt and
# pacman order them: 0.1.0~preview.30 (RPM/deb) and 0.1.0preview.30 (Arch) sort
# before 0.1.0, so a final release is never pruned in favour of its previews.
python3 -I - "$REPO" "$KEEP" <<'EOF'
import functools, os, re, sys
repo, keep = sys.argv[1], int(sys.argv[2])

def vercmp(a, b, pacman=False):
    """rpmvercmp (tilde sorts first); pacman=True: vercmp (trailing letters sort
    first, tilde is a plain separator)."""
    separators = r"^[^A-Za-z0-9]+" if pacman else r"^[^A-Za-z0-9~]+"
    while (a and b) if pacman else (a or b):
        a = re.sub(separators, "", a)
        b = re.sub(separators, "", b)
        if a.startswith("~") or b.startswith("~"):
            if not (a.startswith("~") and b.startswith("~")):
                return -1 if a.startswith("~") else 1
            a, b = a[1:], b[1:]
            continue
        if not a or not b:
            break
        pattern = r"^\d+" if a[0].isdigit() else r"^[A-Za-z]+"
        x, y = re.match(pattern, a), re.match(pattern, b)
        if not y:
            return 1 if a[0].isdigit() else -1
        a, b = a[x.end():], b[y.end():]
        x, y = x.group(), y.group()
        if x[0].isdigit():
            x, y = int(x), int(y)
        if x != y:
            return -1 if x < y else 1
    if not a and not b:
        return 0
    if pacman:
        return -1 if (not a and not b[0].isalpha()) or a[:1].isalpha() else 1
    return 1 if a else -1

def full_cmp(pacman):
    def cmp(x, y):  # "version-release"
        (xv, _, xr), (yv, _, yr) = x[0].rpartition("-"), y[0].rpartition("-")
        return vercmp(xv, yv, pacman) or vercmp(xr, yr, pacman)
    return cmp

groups = {}
for dirpath, _, files in os.walk(repo):
    for f in files:
        m = re.match(r"(.+?)-(\d[^-]*-[^-]+)\.\w+\.rpm$", f) if f.endswith(".rpm") else \
            re.match(r"([^_]+)_([^_]+)_\w+\.deb$", f) if f.endswith(".deb") else \
            re.match(r"(.+)-([^-]+-[^-]+)-\w+\.pkg\.tar\.zst$", f) if f.endswith(".pkg.tar.zst") else None
        if m:
            groups.setdefault((dirpath, m[1]), []).append((m[2], f))
for (dirpath, name), items in groups.items():
    items.sort(key=functools.cmp_to_key(full_cmp(items[0][1].endswith(".pkg.tar.zst"))))
    for _, f in items[:-keep]:
        for path in (os.path.join(dirpath, f), os.path.join(dirpath, f + ".sig")):
            if os.path.exists(path):
                os.remove(path)
        print(f"pruned {f}")
EOF

# ---- keys and repository definitions ----------------------------------------
touch "$ROOT/.nojekyll"
gpg --armor --export "$KEY" > "$REPO/joenilan-apps.asc"
gpg --export "$KEY" > "$REPO/joenilan-apps.gpg"
cat > "$REPO/joenilan-apps.repo" <<EOF
[joenilan-apps]
name=joenilan apps
baseurl=$BASE_URL/rpm
        $MIRROR_URL/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$BASE_URL/joenilan-apps.asc
       $MIRROR_URL/joenilan-apps.asc
EOF
cat > "$REPO/joenilan-apps.sources" <<EOF
Types: deb
URIs: $BASE_URL/deb $MIRROR_URL/deb
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/joenilan-apps-archive-keyring.gpg
EOF

# ---- RPM repository ----------------------------------------------------------
createrepo_c -q --update "$REPO/rpm"
gpg --batch --yes -u "$KEY" --detach-sign --armor -o "$REPO/rpm/repodata/repomd.xml.asc" "$REPO/rpm/repodata/repomd.xml"

# ---- apt repository ----------------------------------------------------------
python3 -I - "$REPO/deb" <<'EOF'
import gzip, hashlib, io, lzma, os, sys, tarfile, time

root = sys.argv[1]
dist = os.path.join(root, "dists", "stable")
binary = os.path.join(dist, "main", "binary-amd64")
os.makedirs(binary, exist_ok=True)

def ar_members(path):
    data = open(path, "rb").read()
    assert data[:8] == b"!<arch>\n", path
    pos = 8
    while pos + 60 <= len(data):
        header = data[pos:pos + 60]
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        yield name, data[pos + 60:pos + 60 + size]
        pos += 60 + size + (size & 1)

def control(path):
    for name, body in ar_members(path):
        if name.startswith("control.tar"):
            if name.endswith(".xz"):
                body = lzma.decompress(body)
            elif name.endswith(".gz"):
                body = gzip.decompress(body)
            elif name.endswith(".zst"):
                from compression import zstd
                body = zstd.decompress(body)
            with tarfile.open(fileobj=io.BytesIO(body)) as tar:
                member = next(m for m in tar.getmembers() if m.name.lstrip("./") == "control")
                return tar.extractfile(member).read().decode().strip()
    raise SystemExit(f"no control file in {path}")

stanzas = []
for dirpath, _, files in sorted(os.walk(os.path.join(root, "pool"))):
    for f in sorted(files):
        if not f.endswith(".deb"):
            continue
        path = os.path.join(dirpath, f)
        blob = open(path, "rb").read()
        stanzas.append(control(path) + "\n" + "\n".join([
            f"Filename: {os.path.relpath(path, root)}",
            f"Size: {len(blob)}",
            f"MD5sum: {hashlib.md5(blob).hexdigest()}",
            f"SHA1: {hashlib.sha1(blob).hexdigest()}",
            f"SHA256: {hashlib.sha256(blob).hexdigest()}",
        ]))
packages = ("\n\n".join(stanzas) + "\n").encode() if stanzas else b""
open(os.path.join(binary, "Packages"), "wb").write(packages)
with gzip.GzipFile(os.path.join(binary, "Packages.gz"), "wb", mtime=0) as g:
    g.write(packages)

files = []
for name in ("main/binary-amd64/Packages", "main/binary-amd64/Packages.gz"):
    blob = open(os.path.join(dist, name), "rb").read()
    files.append((name, len(blob), hashlib.md5(blob).hexdigest(), hashlib.sha256(blob).hexdigest()))
release = [
    "Origin: joenilan apps",
    "Label: joenilan apps",
    "Suite: stable",
    "Codename: stable",
    "Architectures: amd64",
    "Components: main",
    "Description: Apps by joenilan (DreadedZombie)",
    "Date: " + time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime()),
    "MD5Sum:",
    *[f" {md5} {size} {name}" for name, size, md5, _ in files],
    "SHA256:",
    *[f" {sha} {size} {name}" for name, size, _, sha in files],
]
open(os.path.join(dist, "Release"), "w").write("\n".join(release) + "\n")
print(f"apt: {len(stanzas)} package(s)")
EOF
gpg --batch --yes -u "$KEY" --clearsign -o "$REPO/deb/dists/stable/InRelease" "$REPO/deb/dists/stable/Release"
gpg --batch --yes -u "$KEY" --detach-sign --armor -o "$REPO/deb/dists/stable/Release.gpg" "$REPO/deb/dists/stable/Release"

# ---- pacman repository ---------------------------------------------------------
cat > "$REPO/joenilan-apps.pacman.conf" <<EOF
[joenilan-apps]
SigLevel = Required
Server = $BASE_URL/arch/\$arch
Server = $MIRROR_URL/arch/\$arch
EOF
ARCH_DIR="$REPO/arch/x86_64"
# repo-add keeps the last version given for a name: oldest first (sort -V),
# so 0.1.11 wins over 0.1.9.
rm -f "$ARCH_DIR"/joenilan-apps.{db,files}*
if compgen -G "$ARCH_DIR/*.pkg.tar.zst" >/dev/null; then
  podman run --rm --security-opt label=disable -v "$ARCH_DIR":/repo docker.io/library/archlinux:latest \
    bash -c 'mapfile -t pkgs < <(printf "%s\n" /repo/*.pkg.tar.zst | sort -V); repo-add -q /repo/joenilan-apps.db.tar.gz "${pkgs[@]}"'
  # Plain copies instead of repo-add's symlinks (served as files everywhere).
  for name in db files; do
    rm -f "$ARCH_DIR/joenilan-apps.$name"
    cp "$ARCH_DIR/joenilan-apps.$name.tar.gz" "$ARCH_DIR/joenilan-apps.$name"
    for f in "$ARCH_DIR/joenilan-apps.$name" "$ARCH_DIR/joenilan-apps.$name.tar.gz"; do
      gpg --batch --yes -u "$KEY" --detach-sign -o "$f.sig" "$f"
    done
  done
  rm -f "$ARCH_DIR"/*.old "$ARCH_DIR"/*.old.sig
fi

cd "$ROOT"
git add -A
if git diff --cached --quiet; then
  echo "publish-packages: nothing changed"
else
  git commit -q -m "Packages: ${FILES[*]##*/}"
  echo "publish-packages: committed $(git rev-parse --short HEAD)"
fi
[ "$PUSH" = 1 ] || exit 0
git push -q origin HEAD
echo "publish-packages: pushed; $BASE_URL/"
MIRROR_ENV_FILE=${MIRROR_ENV_FILE-$HOME/git/zombie-digital/.env.raspi}
if [ -n "$MIRROR_ENV_FILE" ]; then
  python3 "$ROOT/scripts/mirror-packages.py" --env-file "$MIRROR_ENV_FILE"
  echo "publish-packages: mirrored; $MIRROR_URL/"
fi
