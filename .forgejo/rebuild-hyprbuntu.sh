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
# Where the registry is. The default is the public name, but the Hyprland job
# runs *on* the Forgejo server, in a container sharing its network namespace,
# so the workflow points this at http://127.0.0.1:3000 there. The tarball is
# ~60 MB, and putting it out through the Cloudflare edge and back to the same
# host is what answered 524 in run 207 -- after the replace-DELETE had already
# removed the previous bundle. Over loopback there is no edge to time out.
URL="${FORGEJO_URL:-https://git.vedaru.cn}"
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
#
#    This list is meant to be the machine's. Its source of truth is the
#    `install_hyprwm_package Hyprland` block in dot_local/bin/
#    executable_setup-hyprbuntu.sh, which names the apt packages the laptop's
#    own Hyprland build uses; everything else in the block below is the
#    toolchain plus the pkg-config deps CMakeLists.txt's `deps` call requires.
#    When that block changes, diff it against this one.
#
#    Eight entries are easy to leave out because the build only mentions them
#    indirectly, and each was a separate failed run before it was added:
#
#      * libglaze-dev. Without it find_package(glaze) is QUIET-false and
#        CMakeLists.txt:136 falls into FetchContent, which clones
#        github.com/stephenberry/glaze.git -- the one host this repo exists to
#        avoid, and one this runner cannot reach at all. The build would stop
#        there, but only after trying the network. glaze is header-only and,
#        on the machine, a plain system package outside the bundle, so CI has
#        to install it too.
#
#      * libabsl-dev. The bundle ships its own re2 under /usr/lib/x86_64-linux-gnu
#        (re2.pc, the headers, libre2.so), and that re2.pc's `Requires:` line
#        names fifteen absl_* modules. Those .pc files are not in the bundle --
#        on the machine they come from libabsl-dev -- so pkg-config stops at
#        "Package 'absl_absl_check', required by 're2', not found" and
#        CMakeLists.txt:269 fails the whole `deps` call. Same shape as
#        libglaze-dev: a plain system package that the bundle's own pkg-config
#        metadata depends on and the bundle does not contain. The machine runs
#        20260107.0-4, and ubuntu:26.04 carries that same version.
#
#      * glslang-tools. glslang-dev ships the CMake config, and that config
#        eagerly checks that the imported target glslang::glslang-standalone
#        resolves to a file that exists. The file is /usr/bin/glslang, which
#        lives in glslang-tools, and glslang-dev does not depend on it
#        (Depends: spirv-tools-dev only). Without it find_package(glslang)
#        fails with "references the file /usr/bin/glslang ... but this file
#        does not exist" and configure stops.
#
#      * libudis86-dev. Two reasons it has to be the apt package rather than
#        the in-tree submodule. One, the submodule points at github.com, so
#        the clone leaves subprojects/udis86 an empty directory and CMake's
#        fallback add_subdirectory() dies on the missing CMakeLists.txt. Two,
#        the machine links Hyprland against the shared libudis86 (pkg-config
#        finds 1.7.2 there), so installing the same package keeps the CI
#        binary's linkage identical to the one the bundle was made from,
#        instead of silently switching it to a static copy. Version
#        0+20221013-1.1build1 is what 26.04 carries: the machine's version.
#
#      * libre2-11 and libpugixml1v5, the two *runtime* halves of libraries
#        whose build files the bundle ships. The bundle has re2's dev files
#        (re2.pc, the headers, the cmake config) and a lib symlink
#        /usr/lib/x86_64-linux-gnu/libre2.so -> libre2.so.11, but no
#        libre2.so.11 itself, so that symlink dangles and every ELF linked
#        against re2 fails to start. On the machine the .so comes from apt
#        (libre2-11) while the dev files come from the vendored src build --
#        setup-hyprbuntu.sh builds re2 from source because 26.04's libre2-dev
#        is too old -- so apt has to supply just the runtime here too.
#        The scanners (hyprwayland-scanner, hyprwire-scanner, both run by the
#        build before ninja compiles anything) need libpugixml.so.1 the same
#        way: the bundle carries the scanner binaries but not pugixml.
#
#      * librsvg2-2, libzip5, libheif1, libjpeg-turbo8, libjxl0.11 and
#        libwebp7. The six runtimes that the bundle's own libhyprcursor.so and
#        libhyprgraphics.so record as DT_NEEDED while leaving their symbols
#        undefined: hyprcursor calls zip_* and rsvg_*, hyprgraphics calls Jxl*,
#        WebP* and the jpeg/heif entry points. When the output is an executable
#        rather than a shared library, ld does not by default tolerate
#        undefined symbols in the shared libraries on the link line
#        (--no-allow-shlib-undefined is the default for executables), so the
#        final link of Hyprland dies with "undefined
#        reference to `JxlDecoderProcessInput@JXL_0'" even though every one of
#        Hyprland's own objects compiled. None of these six is a file the
#        bundle ships -- it carries hyprcursor and hyprgraphics themselves,
#        not what they link against -- so, like re2 and pugixml above, apt has
#        to supply them. On the machine they arrive transitively through the
#        -dev packages the hyprcursor and hyprgraphics blocks install
#        (librsvg2-dev, libzip-dev, libheif-dev, libjpeg-dev, libjxl-dev,
#        libwebp-dev -- setup-hyprbuntu.sh:479-492); CI names the runtime
#        halves directly, because CI builds none of these from source and the
#        link resolves against the sonames, not the dev symlinks.
#
#        libmagic.so.1 is the seventh DT_NEEDED of libhyprgraphics.so and
#        needs no entry: `file` is already in the list below, and libmagic1t64
#        is its dependency (the 64-bit-time_t name for libmagic1).
#
#      * gcc-16 and g++-16, not the default compilers. 26.04's default is GCC
#        15, whose libstdc++ has no std::ranges::starts_with (C++23, added in
#        libstdc++ with GCC 16), so the build dies on
#        src/helpers/MiscFunctions.cpp:841 -- 'starts_with' is not a member of
#        'std::ranges'. This is not a CI-only quirk: setup-hyprbuntu.sh:594
#        builds the machine's own Hyprland with `CC=gcc-16 CXX=g++-16` for
#        exactly this reason. Building with 15 would not merely fail, it would
#        produce a different binary from the one this bundle is meant to be.
#
#      * liblua5.5-dev, not liblua5.4-dev. CMakeLists.txt:291 searches
#        `lua55 lua5.5 ... lua>=5.5 lua<5.6`, so a 5.4 package satisfies none
#        of them. The machine runs liblua5.5-dev (its lua.pc reports 5.5.0).
#
#    libxcb-render0-dev is deliberately absent: it is a dependency of
#    libcairo2-dev (also below), so it arrives transitively, which is also how
#    the machine gets it.
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null; then
  say "== installing the build toolchain (apt) =="
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build pkg-config git curl ca-certificates \
    gcc-16 g++-16 \
    file zstd xz-utils \
    libxkbcommon-dev uuid-dev libcairo2-dev libpango1.0-dev libpixman-1-dev \
    libxcursor-dev libdrm-dev libinput-dev libeis-dev libgbm-dev \
    libglib2.0-dev libmuparser-dev liblcms2-dev glslang-dev glslang-tools \
    libglaze-dev \
    libabsl-dev \
    libre2-11 libpugixml1v5 \
    librsvg2-2 libzip5 libheif1 libjpeg-turbo8 libjxl0.11 libwebp7 \
    libgl1-mesa-dev libegl1-mesa-dev libgles2-mesa-dev \
    libseat-dev libdisplay-info-dev libliftoff-dev libudev-dev \
    libudis86-dev \
    libtomlplusplus-dev libwayland-dev libxcb1-dev libxcb-composite0-dev \
    libxcb-ewmh-dev libxcb-icccm4-dev libxcb-keysyms1-dev libxcb-render-util0-dev \
    libxcb-res0-dev libxcb-xfixes0-dev libxcb-errors-dev \
    libxcb-xinput-dev libxcb-xkb-dev libxkbcommon-x11-dev \
    libpam0g-dev libsystemd-dev libgbm-dev liblua5.5-dev \
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
# /usr/local, not /usr: the bundle already has the Hyprland binary at
# /usr/local/bin/Hyprland and nowhere else (its assets are under
# /usr/local/share/{hypr,wayland-sessions}). A /usr-prefix install would write
# /usr/bin/Hyprland and leave the old /usr/local/bin/Hyprland in place, and
# since /usr/local/bin precedes /usr/bin in PATH that stale binary would be the
# one that runs -- the rebuilt one would never be used.
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
cmake -S "$SRC" -B /tmp/hyprland-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=gcc-16 \
      -DCMAKE_CXX_COMPILER=g++-16 \
      -DCMAKE_INSTALL_PREFIX=/usr/local \
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
  local file="$1" name attempt code del
  name="$(basename "$file")"
  local url="$URL/api/packages/$OWNER/generic/$PKG/$VER/$name"
  # Retried: the tunnel drops transfers (curl reports 000) and the edge in
  # front of Forgejo answers 502 in bursts, most often on the tarball. A 409
  # that follows a successful DELETE is the same class -- the file is still
  # there regardless, so the whole replace is retried rather than reported.
  # The 520-524 range is Cloudflare's own: 524 is the one that cost run 207 its
  # upload, an origin timeout on the 60 MB PUT, and it arrives here rather than
  # from Forgejo, so it is retried with the rest.
  for attempt in 1 2 3 4 5; do
    code=$(curl -4 -sS -o /tmp/upload.out -w '%{http_code}' -m 900 -X PUT \
                -H "Authorization: token $TOKEN" --upload-file "$file" "$url") || true
    if [ "$code" = "409" ]; then
      # The registry is immutable per version, so the existing file has to go
      # first. The DELETE's own status is checked: one the edge dropped leaves
      # the file in place, and the PUT below then answers 409 again.
      del=$(curl -4 -sS -o /tmp/upload-del.out -w '%{http_code}' -m 300 -X DELETE \
                 -H "Authorization: token $TOKEN" "$url") || true
      if [ "$del" != "204" ] && [ "$del" != "200" ]; then
        say "  ... $name: replace DELETE -> HTTP $del, retry $attempt/5"
        sleep 2
        continue
      fi
      code=$(curl -4 -sS -o /tmp/upload.out -w '%{http_code}' -m 900 -X PUT \
                  -H "Authorization: token $TOKEN" --upload-file "$file" "$url") || true
    fi
    case "$code" in
      000|409|502|503|504|520|521|522|523|524)
        say "  ... $name: HTTP $code, retry $attempt/5"
        sleep 2
        ;;
      *) break ;;
    esac
  done
  # Cloudflare answers any body over ~100 MB with 413 before Forgejo sees it.
  if [ "$code" != "201" ] && [ "$code" != "200" ]; then
    say "  FAIL $name -> HTTP $code"; sed 's/^/    /' /tmp/upload.out 2>/dev/null; return 1
  fi
  say "  ok   $name ($(stat -c '%s' "$file") bytes, HTTP $code)"
}

say "== publishing $PKG $VER =="
upload "$out" || die "the bundle upload failed"
upload "$WORK/$PKG-$VER/MANIFEST.tsv" || die "MANIFEST.tsv upload failed"
upload "$WORK/$PKG-$VER/SHA256SUMS" || die "SHA256SUMS upload failed"

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
