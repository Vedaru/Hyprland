#!/usr/bin/env bash
#
# rebuild-hyprbuntu.sh -- rebuild the Hyprland fork on the CI runner and
# republish the `hyprbuntu` bundle to the Forgejo generic registry.
#
# This replaces the old job's dependency on ansible/vendored/publish.sh in the
# chezmoi repo. That script tars the *live* /usr/local and /usr trees, so it
# only means anything on the machine it runs on -- which is not where CI runs.
# Here the bundle is produced from this repository instead:
#
#   * the 16 dependency packages (aquamarine, hyprutils, hyprlang, hyprcursor,
#     hyprgraphics, hyprwire, hyprtoolkit, hyprwayland-scanner,
#     hyprland-protocols, wayland, wayland-protocols, re2, Lua, cpptrace,
#     libdwarf, zstd) are already built and published, so they are taken from
#     the *current* bundle, byte for byte, rather than rebuilt;
#   * only Hyprland is built, from this checkout, against those packages.
#
# Why that is enough, and why no github.com is needed: Hyprland's CMakeLists
# resolves hyprland-protocols through pkg-config first and only falls back to
# the github submodule when it is missing (CMakeLists.txt:532), and the same
# holds for udis86 (:41). The extracted bundle provides both, so the three
# github submodules stay unused and the job works on a runner with no proxy.
#
# Everything is staged in / and nothing outside the container is touched: the
# bundle's .pc and cmake config files hardcode their install prefix, so the
# packages have to sit at their real paths for CMake to link against them.
# That is why the container check below is a hard failure and not a warning.
set -uo pipefail

VER="0.56.2-vedaru1"
OWNER="Vedaru"
URL="https://git.vedaru.cn"
PKG="hyprbuntu"
SRC="${SRC:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
NEWROOT="/tmp/hyprbuntu-new"      # DESTDIR for the Hyprland install
WORK="/tmp/hyprbuntu-work"        # tarball + metadata

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

TOKEN="${FORGEJO_TOKEN:-}"
[ -n "$TOKEN" ] || die "FORGEJO_TOKEN is not set"

# ---------------------------------------------------------------------------
# 0. This job installs into / -- it must be a container.
# ---------------------------------------------------------------------------
if grep -qaE 'docker|containerd|kubepods|podman|libpod' /proc/1/cgroup /proc/self/mountinfo 2>/dev/null; then
  say "container: yes (pid1=$(cat /proc/1/comm 2>/dev/null))"
else
  die "not running in a container (pid1=$(cat /proc/1/comm 2>/dev/null)); installing into / would overwrite the host, refusing"
fi

say "distro: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
say "user: $(id -un) uid=$(id -u)  cpus: $(nproc 2>/dev/null || echo ?)  src: $SRC"

# ---------------------------------------------------------------------------
# 1. Toolchain. The runner image is minimal (no zstd, which is what killed the
#    previous job), so everything the build needs is installed here.
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null; then
  say "== installing the build toolchain (apt) =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build pkg-config git curl ca-certificates \
    file zstd xz-utils \
    libxkbcommon-dev uuid-dev libcairo2-dev libpango1.0-dev libpixman-1-dev \
    libxcursor-dev libdrm-dev libinput-dev libeis-dev libgbm-dev \
    libglib2.0-dev libmuparser-dev liblcms2-dev glslang-dev \
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    libseat-dev libdisplay-info-dev libliftoff-dev libudev-dev \
    libtomlplusplus-dev libwayland-dev libxcb1-dev libxcb-composite0-dev \
    libxcb-ewmh-dev libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-render-util0-dev \
    libxcb-res0-dev libxcb-xinput-dev libxcb-xkb-dev libxkbcommon-x11-dev \
    libpam0g-dev libsystemd-dev libgbm-dev liblua5.4-dev \
    || die "apt-get install failed"
else
  die "no apt-get on this runner ($(command -v apk pacman dnf 2>/dev/null || echo 'no package manager')); this script only supports apt-based images"
fi

for t in cmake ninja pkg-config tar zstd curl python3; do
  command -v "$t" >/dev/null || die "$t still missing after install"
done
say "cmake: $(cmake --version | head -1)"

# ---------------------------------------------------------------------------
# 2. The 16 dependency packages, taken from the bundle that is already
#    published. File paths under the generic registry are readable without a
#    token, but the token is sent anyway so a private owner would work too.
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
tarball_name="$PKG-$VER.tar.zst"
say "== fetching the current bundle ($tarball_name) =="
code=$(curl -4 -sS -o "$WORK/$tarball_name" -w '%{http_code}' -m 600 \
       -H "Authorization: token $TOKEN" \
       "$URL/api/packages/$OWNER/generic/$PKG/$VER/$tarball_name?cb=$RANDOM") || die "download failed"
[ "$code" = "200" ] || die "bundle download -> HTTP $code"
say "  ok $(stat -c '%s' "$WORK/$tarball_name") bytes"

# Extracted at / , not in a staging dir: the .pc / cmake configs inside hardcode
# /usr/local and /usr as their prefix, so the packages must live at those exact
# paths or CMake links against nothing.
( cd / && tar --zstd -xf "$WORK/$tarball_name" ) || die "extracting the bundle failed"
[ -e /usr/local/bin/Hyprland ] || say "  note: /usr/local/bin/Hyprland not in the bundle (Hyprland may install to /usr/bin)"

# The file set of the previous bundle, kept so the new tarball holds exactly
# those files plus whatever the new Hyprland install adds.
code=$(curl -4 -sS -o "$WORK/old-MANIFEST.tsv" -w '%{http_code}' -m 300 \
       -H "Authorization: token $TOKEN" \
       "$URL/api/packages/$OWNER/generic/$PKG/$VER/MANIFEST.tsv?cb=$RANDOM") || true
if [ "$code" = "200" ]; then
  say "  previous MANIFEST.tsv: $(grep -c . "$WORK/old-MANIFEST.tsv") entries"
else
  say "  note: previous MANIFEST.tsv -> HTTP ${code:-none}; the new file set will be the install output only"
  : > "$WORK/old-MANIFEST.tsv"
fi

# ---------------------------------------------------------------------------
# 3. Build Hyprland from this checkout, against the extracted packages.
# ---------------------------------------------------------------------------
say "== configuring Hyprland =="
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
cmake -S "$SRC" -B /tmp/hyprland-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_INSTALL_LIBDIR=lib \
      -DCMAKE_PREFIX_PATH="/usr/local;/usr" \
      -DBUILD_TESTING=OFF \
      || die "cmake configure failed"

say "== building Hyprland =="
cmake --build /tmp/hyprland-build -j"$(nproc)" || die "build failed"

# ---------------------------------------------------------------------------
# 4. Install into a DESTDIR first, so the exact set of files this build
#    produces is known before anything is written over the bundle.
# ---------------------------------------------------------------------------
rm -rf "$NEWROOT"
DESTDIR="$NEWROOT" cmake --install /tmp/hyprland-build || die "install failed"
( cd "$NEWROOT" && find . \( -type f -o -type l \) ) > "$WORK/new-files-rel.txt" \
  || die "listing the install output failed"
say "== installed $(grep -c . "$WORK/new-files-rel.txt") files =="
[ -s "$WORK/new-files-rel.txt" ] || die "the install produced no files"
cp -a "$NEWROOT/." / || die "overlaying the new Hyprland onto the bundle failed"

# ---------------------------------------------------------------------------
# 5. File list = previous bundle + the new install, deduplicated.
# ---------------------------------------------------------------------------
awk -F'\t' 'NR>1 && $6 != "" { print $6 }' "$WORK/old-MANIFEST.tsv" > "$WORK/old-paths.txt"
sed 's|^\./||' "$WORK/new-files-rel.txt" > "$WORK/new-paths.txt"
cat "$WORK/old-paths.txt" "$WORK/new-paths.txt" | awk 'NF' | LC_ALL=C sort -u \
  > "$WORK/paths.txt" || die "building the file list failed"
count=$(grep -c . "$WORK/paths.txt")
say "== bundle file list: $count paths =="
[ "$count" -gt 0 ] || die "the file list is empty"

# Every path must now exist (a package that dropped a file would otherwise
# silently vanish from the bundle).
missing=0
while IFS= read -r p; do
  [ -e "/$p" ] || [ -L "/$p" ] || { say "  missing after install: /$p"; missing=$((missing + 1)); }
done < "$WORK/paths.txt"
[ "$missing" -eq 0 ] || die "$missing paths in the list do not exist"

# ---------------------------------------------------------------------------
# 6. Tarball + MANIFEST.tsv + SHA256SUMS.
# ---------------------------------------------------------------------------
say "== packing =="
mkdir -p "$WORK/$PKG-$VER"
out="$WORK/$PKG-$VER/$tarball_name"

# type  mode  size  sha256  owner:group  path  (same shape the previous bundle
# used, so anything reading MANIFEST.tsv keeps working)
manifest="$WORK/$PKG-$VER/MANIFEST.tsv"
printf 'type\tmode\tsize\tsha256\towner:group\tpath\n' > "$manifest"
while IFS= read -r p; do
  f="/$p"
  if [ -L "$f" ]; then
    type="symlink -> $(readlink "$f")"; size=0
    sum=$(printf '%s' "$(readlink "$f")" | sha256sum | cut -d' ' -f1)
  elif [ -f "$f" ]; then
    type="file"; size="$(stat -c '%s' "$f")"
    sum="$(sha256sum "$f" | cut -d' ' -f1)"
  else
    type="other"; size=0; sum="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$type" "$(stat -c '%a' "$f")" "$size" \
    "$sum" "$(stat -c '%u:%g' "$f")" "$p" >> "$manifest"
done < "$WORK/paths.txt"

( cd / && tar --zstd -cf "$out" --no-recursion -T "$WORK/paths.txt" ) \
  || die "tar failed"
( cd "$WORK/$PKG-$VER" && sha256sum "$(basename "$out")" MANIFEST.tsv > SHA256SUMS ) \
  || die "sha256sum failed"
say "  $tarball_name: $(stat -c '%s' "$out") bytes"

# ---------------------------------------------------------------------------
# 7. Publish. The registry is immutable per version, so a 409 means the file is
#    already there and is replaced with a DELETE-then-PUT.
# ---------------------------------------------------------------------------
upload() {
  local file="$1" always="${2:-false}" name code
  name="$(basename "$file")"
  local url="$URL/api/packages/$OWNER/generic/$PKG/$VER/$name"
  code=$(curl -4 -sS -o /tmp/upload.out -w '%{http_code}' -m 900 -X PUT \
              -H "Authorization: token $TOKEN" --upload-file "$file" "$url") || true
  if [ "$code" = "409" ]; then
    curl -4 -sS -o /dev/null -X DELETE -H "Authorization: token $TOKEN" "$url" || true
    code=$(curl -4 -sS -o /tmp/upload.out -w '%{http_code}' -m 900 -X PUT \
                -H "Authorization: token $TOKEN" --upload-file "$file" "$url") || true
  fi
  # Cloudflare answers any body over ~100 MB with 413 before Forgejo sees it.
  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    say "  FAIL $name -> HTTP $code"; sed 's/^/    /' /tmp/upload.out 2>/dev/null; return 1
  fi
  say "  ok   $name ($(stat -c '%s' "$file") bytes, HTTP $code)"
}

say "== publishing $PKG $VER =="
upload "$out" || die "the bundle upload failed"
upload "$WORK/$PKG-$VER/MANIFEST.tsv" always || die "MANIFEST.tsv upload failed"
upload "$WORK/$PKG-$VER/SHA256SUMS" always || die "SHA256SUMS upload failed"

# ---------------------------------------------------------------------------
# 8. Keep one version: the one just published. Every other version of the
#    `hyprbuntu` package is removed, enumerated from the registry rather than
#    from a list of known versions, because the point is to find the ones
#    nobody remembers.
# ---------------------------------------------------------------------------
say "== pruning older versions =="
listing="$WORK/packages.json"
curl -4 -fsSL -H "Authorization: token $TOKEN" \
     "$URL/api/v1/packages/$OWNER?type=generic&q=$PKG&limit=50" -o "$listing" \
     || die "could not list the registry"
versions=$(python3 - "$listing" "$PKG" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])):
    if p["name"] == sys.argv[2]:
        print(p["version"])
PY
) || die "could not parse the registry listing"
kept=0
for v in $versions; do
  if [ "$v" = "$VER" ]; then
    say "  keep   $PKG $v"; kept=$((kept + 1))
  else
    code=$(curl -4 -sS -o /dev/null -w '%{http_code}' -X DELETE \
                -H "Authorization: token $TOKEN" \
                "$URL/api/v1/packages/$OWNER/generic/$PKG/$v")
    say "  delete $PKG $v -> HTTP $code"
  fi
done
[ "$kept" -eq 1 ] || die "the published version was not found in the listing; refusing to report success"
say "done."
