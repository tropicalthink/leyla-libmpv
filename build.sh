#!/usr/bin/env bash
# Builds the LGPL libmpv the Leyla desktop app ships (README.md): mpv
# configured -Dgpl=false on an FFmpeg configured without --enable-gpl,
# --enable-nonfree or --enable-version3, every other library inside it
# LGPL-compatible, all from the pins in sources.lock.
#
#   ./build.sh tag                 # the tag this recipe builds
#   ./build.sh fetch               # download + check every source
#   ./build.sh build [linux|windows]...   # default: both
#   ./build.sh source              # the source archive
#   ./build.sh all                 # fetch, both builds, source
#   ./build.sh images              # leyla-libmpv(-source):<tag>, local
#   ./build.sh ensure              # push them unless the registry has them
#   ./build.sh install <linux|windows> <dir>
#                                             # the built library into <dir>,
#                                             # from out/ or the registry
#   ./build.sh check <file> [seek-seconds [mpv-option=value...]]
#                                             # play it through the Linux build
#
# Run it with Docker (5 to 10 minutes a platform, held to
# $LIBMPV_BUILD_JOBS cores). Output goes to
# $LIBMPV_BUILD_DIR/out/<tag>/:
#
#   linux-x86_64/   lib/libmpv.so.2 (+ libmpv.so, pkgconfig/mpv.pc), include/mpv, BUILDINFO
#   windows-x64/    libmpv-2.dll, libmpv.dll.a, include/mpv, BUILDINFO
#   leyla-libmpv-<tag>-source.tar.xz   every source as fetched, this recipe,
#                                      both BUILDINFOs: the LGPL's offer
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="${CI_REGISTRY:-localhost:5000}"
WORK="${LIBMPV_BUILD_DIR:-$HOME/leyla-build/libmpv-lgpl}"
JOBS="${LIBMPV_BUILD_JOBS:-6}"

pin() { awk -F'|' -v n="$1" '$1==n {print $2}' "$here/sources.lock"; }

# The pins and the recipe, not their prose: a comment edit names no new build.
tag() {
  local hash
  hash="$(for f in sources.lock Dockerfile inside.sh; do grep -v '^ *#' "$here/$f"; done \
    | sha256sum | cut -c1-12)"
  echo "$(pin mpv)-ffmpeg$(pin ffmpeg)-$hash"
}

platform_dir() {
  case "$1" in
    linux) echo linux-x86_64 ;;
    windows) echo windows-x64 ;;
    *) echo "unknown platform $1 (linux or windows)" >&2; exit 2 ;;
  esac
}

fetch() {
  local dl="$WORK/src"
  mkdir -p "$dl/angle-headers"
  cp "$here/sources.lock" "$dl/sources.lock"
  local kind name version url sum
  while IFS='|' read -r kind name version url sum; do
    case "$kind" in
      ''|'#'*) continue ;;
      git)
        # git|name|version|repository|commit
        local pname="$name" ver="$version" repo="$url" commit="$sum"
        if [ "$(git -C "$dl/$pname" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
          rm -rf "$dl/$pname"
          git -c advice.detachedHead=false clone -q --branch "v$ver" --recurse-submodules "$repo" "$dl/$pname"
        fi
        [ "$(git -C "$dl/$pname" rev-parse HEAD)" = "$commit" ] \
          || { echo "$pname v$ver is not commit $commit" >&2; exit 1; }
        ;;
      hdr)
        # name=path in include/, version=url, url=sha256
        local file="$dl/angle-headers/$name"
        mkdir -p "$(dirname "$file")"
        [ -f "$file" ] || curl -fsSL "$version" -o "$file"
        echo "$url  $file" | sha256sum -c --quiet \
          || { echo "checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
        ;;
      *)
        # kind=name name=version version=url url=sha256
        local ext="${version##*.tar.}"
        local file="$dl/$kind-$name.tar.$ext"
        [ -f "$file" ] || curl -fsSL "$version" -o "$file"
        echo "$url  $file" | sha256sum -c --quiet \
          || { echo "checksum mismatch: $file" >&2; rm -f "$file"; exit 1; }
        ;;
    esac
  done < "$here/sources.lock"
  echo "sources checked in $dl"
}

build() {
  local t out
  t="$(tag)"
  out="$WORK/out/$t"
  mkdir -p "$out"
  for platform in "${@:-linux windows}"; do
    for p in $platform; do
      platform_dir "$p" >/dev/null
      docker build -q --target "$p" -t "leyla-libmpv-builder:$p" "$here"
      docker run --rm --cpus "$JOBS" -e LIBMPV_BUILD_JOBS="$JOBS" \
        -v "$WORK/src:/src:ro" -v "$out:/out" "leyla-libmpv-builder:$p" "$p"
      rm -rf "$out/$(platform_dir "$p")"
      mv "$out/$p" "$out/$(platform_dir "$p")"
    done
  done
}

source_archive() {
  local t out stage
  t="$(tag)"
  out="$WORK/out/$t"
  stage="$(mktemp -d)"
  local root="$stage/leyla-libmpv-$t-source"
  mkdir -p "$root/recipe" "$root/src"
  cp -a "$WORK/src/." "$root/src/"
  find "$root" -name .git -prune -exec rm -rf {} +
  cp "$here"/{README.md,sources.lock,Dockerfile,inside.sh,build.sh,check.c} "$root/recipe/"
  for p in linux-x86_64 windows-x64; do
    [ -f "$out/$p/BUILDINFO" ] && cp "$out/$p/BUILDINFO" "$root/BUILDINFO-$p.md"
  done
  cat > "$root/README" <<EOF
Leyla's LGPL libmpv $t: the complete corresponding source.

src/      every source exactly as build.sh fetched it (sources.lock has
          each URL and SHA-256), libplacebo at its pinned commit
recipe/   the build: README.md, build.sh, inside.sh, Dockerfile
BUILDINFO-*.md  what each build ran and produced

Rebuild with Docker, from this folder:
  LIBMPV_BUILD_DIR=\$PWD recipe/build.sh build linux windows
EOF
  tar -C "$stage" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cJf "$out/leyla-libmpv-$t-source.tar.xz" "leyla-libmpv-$t-source"
  rm -rf "$stage"
  ls -l "$out/leyla-libmpv-$t-source.tar.xz"
}

image_names() { local t; t="$(tag)"; echo "$REGISTRY/tropicalthink/leyla-libmpv:$t $REGISTRY/tropicalthink/leyla-libmpv-source:$t"; }

images() {
  local t out bin src
  t="$(tag)"; out="$WORK/out/$t"
  read -r bin src <<<"$(image_names)"
  for p in linux-x86_64 windows-x64; do
    [ -d "$out/$p" ] || { echo "no $out/$p: run build first" >&2; exit 1; }
  done
  [ -f "$out/leyla-libmpv-$t-source.tar.xz" ] || source_archive
  printf 'FROM scratch\nCOPY linux-x86_64 /linux-x86_64\nCOPY windows-x64 /windows-x64\n' \
    | docker build -q -t "$bin" -f - "$out"
  printf 'FROM scratch\nCOPY leyla-libmpv-%s-source.tar.xz /\n' "$t" \
    | docker build -q -t "$src" -f - "$out"
  echo "$bin"; echo "$src"
}

in_registry() { docker manifest inspect --insecure "$1" >/dev/null 2>&1; }

ensure() {
  local name
  for name in $(image_names); do
    if in_registry "$name"; then echo "$name: in the registry"; continue; fi
    docker image inspect "$name" >/dev/null 2>&1 \
      || { echo "$name: neither in the registry nor built here (./README.md)" >&2; exit 1; }
    docker push "$name"
  done
}

install_into() { # <linux|windows> <dir>
  local p dir t bin cid
  p="$(platform_dir "$1")"; dir="$2"; t="$(tag)"
  rm -rf "$dir"; mkdir -p "$dir"
  if [ -d "$WORK/out/$t/$p" ]; then
    cp -a "$WORK/out/$t/$p/." "$dir/"
  else
    read -r bin _ <<<"$(image_names)"
    docker pull -q "$bin" >/dev/null
    cid="$(docker create "$bin" /none)"
    docker cp "$cid:/$p/." "$dir/"
    docker rm -f "$cid" >/dev/null
  fi
  echo "$t" > "$dir/TAG"
  echo "libmpv $t ($p) in $dir"
}

# Plays <file> through the Linux build in its builder image (check.c): the
# decoders, DTS-HD MA's output format and the A/V offset after a seek.
check_file() { # <file> [seek-seconds [option=value...]]
  local file dir out
  file="$(readlink -f "$1")"; dir="$(dirname "$file")"
  out="$WORK/out/$(tag)/linux-x86_64"
  [ -f "$out/lib/libmpv.so.2" ] || { echo "no Linux build in $out" >&2; exit 1; }
  docker run --rm --entrypoint sh -v "$out:/libmpv:ro" -v "$here/check.c:/check.c:ro" \
    -v "$dir:/media:ro" "leyla-libmpv-builder:linux" -c \
    "gcc -O1 -o /tmp/check /check.c -I/libmpv/include -L/libmpv/lib -lmpv -Wl,-rpath,/libmpv/lib \
     && /tmp/check \"/media/$(basename "$file")\" ${2:-600} ${*:3}"
}

case "${1:-}" in
  tag) tag ;;
  fetch) fetch ;;
  build) shift; build "$@" ;;
  source) source_archive ;;
  all) fetch; build linux windows; source_archive ;;
  images) images ;;
  ensure) ensure ;;
  install) install_into "${2:?linux or windows}" "${3:?directory}" ;;
  check) shift; check_file "${1:?file}" "${@:2}" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 2 ;;
esac
