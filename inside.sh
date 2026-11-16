#!/usr/bin/env bash
# Runs inside the Dockerfile's `linux` or `windows` image (build.sh starts
# it): builds every dependency into a private prefix as a static library,
# then libmpv as one shared library with them inside, and checks that what
# came out is LGPL.
#
#   leyla-libmpv-inside <linux|windows>
#
# /src  the checked sources, read-only (build.sh fetch)
# /out  where <target>/ is written: the library, its headers, mpv.pc or
#       the import library, and BUILDINFO (every configure line and the
#       configure summaries, which go into the source archive too)
set -euo pipefail

target="${1:?linux or windows}"
jobs="${LIBMPV_BUILD_JOBS:-6}"
src=/src
work=/build
prefix=/build/prefix
out="/out/$target"
info="$out/BUILDINFO"

rm -rf "$work" "$out"
mkdir -p "$work" "$prefix" "$out"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"

log() { printf '\n## %s\n\n' "$*" | tee -a "$info"; }
record() { printf '%s\n' "$*" | tee -a "$info"; }

unpack() { # <name> <version>: the tarball build.sh fetched, into $work
  local tarball
  tarball="$(ls "$src/$1-$2".tar.*)"
  tar -C "$work" -xf "$tarball"
  local dir="$work/$1-$2"
  [ -d "$dir" ] || { echo "unpacked $tarball has no $1-$2/" >&2; exit 1; }
  printf '%s' "$dir"
}

version_of() { awk -F'|' -v n="$1" '$1==n {print $2} $1=="git" && $2==n {print $3}' "$src/sources.lock"; }

case "$target" in
  linux)
    host_flags=()
    meson_cross=()
    export CFLAGS="-O2 -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2"
    export CXXFLAGS="$CFLAGS"
    ;;
  windows)
    cross=x86_64-w64-mingw32
    cat > "$work/cross.txt" <<EOF
[binaries]
c = '$cross-gcc-win32'
cpp = '$cross-g++-win32'
ar = '$cross-ar'
strip = '$cross-strip'
windres = '$cross-windres'
dlltool = '$cross-dlltool'
nasm = 'nasm'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-O2']
cpp_args = ['-O2']
c_link_args = ['-static-libgcc']
cpp_link_args = ['-static-libgcc', '-static-libstdc++']

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    meson_cross=(--cross-file "$work/cross.txt")
    # Only what was built here: never the build machine's own libraries.
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac

{
  echo "# Leyla libmpv, $target"
  echo
  echo "Built $(date -u +%Y-%m-%dT%H:%MZ) in $(. /etc/os-release; echo "$PRETTY_NAME"),"
  echo "$(gcc --version | head -1); meson $(meson --version); ninja $(ninja --version)."
  [ "$target" = windows ] && echo "Cross compiler: $($cross-gcc-win32 --version | head -1)."
  echo
  echo "Sources (sources.lock):"
  grep -v '^#' "$src/sources.lock" | sed 's/^/    /'
} > "$info"

# Every static library's .pc lists what it needs as private; libmpv is
# one shared library, so those must be linked into it as well.
publicize_pc() {
  for pc in "$prefix"/lib/pkgconfig/*.pc; do
    sed -i -e 's/^Requires\.private:/Requires:/' "$pc"
    if grep -q '^Libs\.private:' "$pc"; then
      local private
      private="$(sed -n 's/^Libs\.private:\(.*\)$/\1/p' "$pc")"
      sed -i -e '/^Libs\.private:/d' -e "s|^Libs:\(.*\)$|Libs:\1 $private|" "$pc"
    fi
  done
}

meson_static() { # <srcdir> <options...>
  local dir="$1"; shift
  record "meson setup ${meson_cross[*]} --prefix=$prefix --libdir=lib --buildtype=release --default-library=static $*"
  meson setup "${meson_cross[@]}" "$dir/build" "$dir" --prefix="$prefix" --libdir=lib \
    --buildtype=release --default-library=static -Db_staticpic=true "$@"
  ninja -C "$dir/build" -j"$jobs"
  ninja -C "$dir/build" install
  publicize_pc
}

if [ "$target" = windows ]; then
  log "zlib $(version_of zlib)"
  dir="$(unpack zlib "$(version_of zlib)")"
  record "make -f win32/Makefile.gcc PREFIX=$cross- (static only)"
  make -C "$dir" -f win32/Makefile.gcc PREFIX="$cross-" CC="$cross-gcc-win32" -j"$jobs" libz.a
  install -D -m644 "$dir/libz.a" "$prefix/lib/libz.a"
  install -D -m644 "$dir/zlib.h" "$prefix/include/zlib.h"
  install -D -m644 "$dir/zconf.h" "$prefix/include/zconf.h"
  mkdir -p "$prefix/lib/pkgconfig"
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: zlib\nDescription: zlib\nVersion: %s\nLibs: -L${libdir} -lz\nCflags: -I${includedir}\n' \
    "$prefix" "$(version_of zlib)" > "$prefix/lib/pkgconfig/zlib.pc"

  log "FreeType $(version_of freetype)"
  dir="$(unpack freetype "$(version_of freetype)")"
  meson_static "$dir" -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled \
    -Dpng=disabled -Dzlib=system -Dtests=disabled

  log "FriBidi $(version_of fribidi)"
  dir="$(unpack fribidi "$(version_of fribidi)")"
  meson_static "$dir" -Ddocs=false -Dbin=false -Dtests=false

  log "HarfBuzz $(version_of harfbuzz)"
  dir="$(unpack harfbuzz "$(version_of harfbuzz)")"
  meson_static "$dir" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled \
    -Dcairo=disabled -Dchafa=disabled -Dicu=disabled -Dgraphite2=disabled \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dutilities=disabled \
    -Dbenchmark=disabled

  # mpv's egl-angle: the headers only; libEGL.dll is ANGLE's, loaded at
  # run time from beside the app.
  mkdir -p "$prefix/include"
  cp -r "$src/angle-headers/." "$prefix/include/"
fi

log "dav1d $(version_of dav1d)"
dir="$(unpack dav1d "$(version_of dav1d)")"
meson_static "$dir" -Denable_tools=false -Denable_tests=false -Denable_examples=false

log "libplacebo $(version_of libplacebo)"
cp -a "$src/libplacebo" "$work/libplacebo"
meson_static "$work/libplacebo" -Dvulkan=disabled -Dopengl=enabled -Dd3d11=disabled \
  -Dglslang=disabled -Dshaderc=disabled -Dlcms=disabled -Ddovi=enabled \
  -Dlibdovi=disabled -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false \
  -Dunwind=disabled -Dxxhash=disabled
# Its number formatting is C++ (convert.cc) and its .pc does not say so.
# Linux takes the system's libstdc++; the Windows DLL carries the static
# one, named as a file, or it would need libstdc++-6.dll beside it.
if [ "$target" = windows ]; then stdcxx='-l:libstdc++.a'; else stdcxx='-lstdc++'; fi
sed -i "s/^\(Libs:.*\)\$/\1 $stdcxx/" "$prefix/lib/pkgconfig/libplacebo.pc"

log "libass $(version_of libass)"
dir="$(unpack libass "$(version_of libass)")"
if [ "$target" = windows ]; then
  meson_static "$dir" -Dfontconfig=disabled -Ddirectwrite=enabled -Dasm=enabled \
    -Dlibunibreak=disabled -Dtest=disabled -Dcompare=disabled -Dprofile=disabled \
    -Dfuzz=disabled -Dcheckasm=disabled
else
  meson_static "$dir" -Dfontconfig=enabled -Dasm=enabled -Dlibunibreak=disabled \
    -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled \
    -Dcheckasm=disabled
fi

if [ "$target" = linux ]; then
  # mpv's DRM code, which its VAAPI decoding on Linux is built on, needs
  # it; bookworm has none.
  log "libdisplay-info $(version_of libdisplay-info)"
  dir="$(unpack libdisplay-info "$(version_of libdisplay-info)")"
  meson_static "$dir"
fi

log "nv-codec-headers $(version_of nv-codec-headers)"
dir="$(unpack nv-codec-headers "$(version_of nv-codec-headers)")"
make -C "$dir" PREFIX="$prefix" LIBDIR=lib install

log "FFmpeg $(version_of ffmpeg)"
dir="$(unpack ffmpeg "$(version_of ffmpeg)")"
# LGPL: no --enable-gpl, no --enable-nonfree, no --enable-version3, and
# nothing autodetected: every external library is named here. All
# decoders, demuxers, parsers, protocols and filters stay; encoders,
# muxers and devices go (libmpv plays, it does not record).
ffmpeg_flags=(
  --prefix="$prefix" --pkg-config-flags=--static
  --enable-static --disable-shared --enable-pic
  --disable-autodetect --disable-programs --disable-doc --disable-debug
  --disable-avdevice --disable-encoders --enable-encoder=png,mjpeg
  --disable-muxers --disable-indevs --disable-outdevs
  --enable-network --enable-zlib --enable-libdav1d
  --enable-ffnvcodec --enable-nvdec
  --extra-version=Leyla
)
if [ "$target" = windows ]; then
  ffmpeg_flags+=(
    --target-os=mingw32 --arch=x86_64 --cross-prefix="$cross-" --cc="$cross-gcc-win32"
    --cxx="$cross-g++-win32" --enable-w32threads --enable-schannel
    --enable-d3d11va --enable-d3d12va --enable-dxva2
  )
else
  ffmpeg_flags+=(--enable-pthreads --enable-openssl --enable-vaapi --enable-libdrm --enable-iconv)
fi
record "./configure ${ffmpeg_flags[*]}"
(cd "$dir" && ./configure "${ffmpeg_flags[@]}") > "$work/ffmpeg-configure.txt"
cat "$work/ffmpeg-configure.txt" >> "$info"
grep -q '^License: LGPL version 2.1 or later$' "$work/ffmpeg-configure.txt" \
  || { echo "FFmpeg is not configured LGPL" >&2; exit 1; }
make -C "$dir" -j"$jobs"
make -C "$dir" install
publicize_pc

log "mpv $(version_of mpv)"
dir="$(unpack mpv "$(version_of mpv)")"
mpv_flags=(
  -Dgpl=false -Dlibmpv=true -Dcplayer=false -Dtests=false -Dfuzzers=false
  -Dbuild-date=false -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
  -Dlua=disabled -Djavascript=disabled -Dlibarchive=disabled -Dlibbluray=disabled
  -Ddvdnav=disabled -Dcdda=disabled -Ddvbin=disabled -Duchardet=disabled
  -Drubberband=disabled -Dlcms2=disabled -Dzimg=disabled -Dvapoursynth=disabled
  -Djpeg=disabled -Dlibavdevice=disabled -Dcplugins=disabled -Dsdl2-audio=disabled
  -Dsdl2-video=disabled -Dsdl2-gamepad=disabled -Djack=disabled -Dopenal=disabled
  -Dsndio=disabled -Dpipewire=disabled -Dvulkan=disabled -Dshaderc=disabled
  -Dspirv-cross=disabled -Dcaca=disabled -Dsixel=disabled -Dvdpau=disabled
  -Dgl=enabled -Dplain-gl=enabled -Dcuda-hwaccel=enabled -Dcuda-interop=enabled
  -Dzlib=enabled
)
if [ "$target" = windows ]; then
  mpv_flags+=(
    -Dwin32-threads=enabled -Dwasapi=enabled -Dgl-win32=enabled -Dd3d-hwaccel=enabled
    -Dd3d11=disabled -Ddirect3d=disabled -Dgl-dxinterop=enabled -Diconv=disabled
    # D3D11 pictures handed to media_kit's ANGLE texture without a copy
    # (hwdec_d3d11egl); libEGL.dll is loaded at run time. Not mpv's own
    # ANGLE window (egl-angle-win32), which libmpv's render API never uses
    # and whose D3D9 path current ANGLE headers no longer declare; no D3D9.
    -Degl-angle=enabled -Degl-angle-lib=disabled -Degl-angle-win32=disabled
    -Dd3d9-hwaccel=disabled -Dgl-dxinterop-d3d9=disabled
  )
  # ANGLE's EGL headers sit in the prefix, where meson's cross build does
  # not look by itself.
  link=(-Dc_args="-O2 -I$prefix/include" -Dc_link_args="-static-libgcc -static-libstdc++ -static")
else
  mpv_flags+=(
    -Dx11=disabled -Dwayland=disabled -Dx11-clipboard=disabled -Dxv=disabled
    -Degl=enabled -Ddrm=enabled -Dgbm=disabled -Degl-drm=disabled -Degl-x11=disabled
    -Degl-wayland=disabled -Dgl-x11=disabled -Ddmabuf-wayland=disabled
    -Dvaapi=enabled -Dvaapi-drm=enabled -Dvaapi-x11=disabled -Dvaapi-wayland=disabled
    -Dpulse=enabled -Dalsa=enabled -Doss-audio=disabled -Diconv=enabled
  )
  # The static libraries inside stay private to libmpv: none of their
  # symbols are exported, so a second FFmpeg or FreeType in the process
  # (Flutter's GTK has its own) is never confused with them.
  link=(-Dc_link_args="-Wl,--exclude-libs,ALL -Wl,-z,relro,-z,now")
fi
record "meson setup ${meson_cross[*]} --prefix=$prefix --buildtype=release -Ddefault_library=shared -Dstrip=true ${mpv_flags[*]} ${link[*]}"
meson setup "${meson_cross[@]}" "$dir/build" "$dir" --prefix="$prefix" --libdir=lib \
  --buildtype=release -Ddefault_library=shared -Dstrip=true "${mpv_flags[@]}" "${link[@]}" \
  | tee "$work/mpv-configure.txt"
grep 'List of enabled features' "$work/mpv-configure.txt" >> "$info" || true
sed -n '/^mpv [0-9]/,$p' "$work/mpv-configure.txt" >> "$info" || true
ninja -C "$dir/build" -j"$jobs"
ninja -C "$dir/build" install

log "Result"
mkdir -p "$out/include"
cp -r "$prefix/include/mpv" "$out/include/"
if [ "$target" = windows ]; then
  cp "$prefix/bin/libmpv-2.dll" "$out/"
  cp "$prefix/lib/libmpv.dll.a" "$out/"
  "$cross-strip" --strip-unneeded "$out/libmpv-2.dll"
  record "Imports of libmpv-2.dll (all ship with Windows):"
  "$cross-objdump" -p "$out/libmpv-2.dll" | sed -n 's/^\tDLL Name: /    /p' | sort -u | tee -a "$info"
  if "$cross-objdump" -p "$out/libmpv-2.dll" | grep -qiE 'DLL Name: (lib|zlib)'; then
    echo "libmpv-2.dll imports a DLL that is not part of Windows" >&2; exit 1
  fi
  lib="$out/libmpv-2.dll"
else
  mkdir -p "$out/lib/pkgconfig"
  real="$(readlink -f "$prefix/lib/libmpv.so.2")"
  cp "$real" "$out/lib/libmpv.so.2"
  ln -s libmpv.so.2 "$out/lib/libmpv.so"
  strip --strip-unneeded "$out/lib/libmpv.so.2"
  cat > "$out/lib/pkgconfig/mpv.pc" <<EOF
prefix=\${pcfiledir}/../..
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mpv
Description: mpv media player client library (Leyla's LGPL build)
Version: $(sed -n 's/^Version: //p' "$prefix/lib/pkgconfig/mpv.pc")
Libs: -L\${libdir} -lmpv
Cflags: -I\${includedir}
EOF
  record "Shared libraries libmpv.so.2 needs (each from the system):"
  readelf -d "$out/lib/libmpv.so.2" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/    \1/p' | tee -a "$info"
  record "Newest glibc symbol version it needs:"
  objdump -T "$out/lib/libmpv.so.2" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 | sed 's/^/    /' | tee -a "$info"
  lib="$out/lib/libmpv.so.2"
fi

# The LGPL proof, read from the built library itself, not from what we
# asked configure for.
record "LGPL proof:"
strings "$lib" > "$work/strings.txt"
grep -- '--disable-autodetect' "$work/strings.txt" | sort -u | sed 's/^/    ffmpeg configuration: /' | tee -a "$info"
# avcodec_license() and the other libraries' return these, minus the prefix.
grep -oE 'lib[a-z]+ license: .*' "$work/strings.txt" | sort -u | sed 's/^/    /' | tee -a "$info"
grep -q 'libavcodec license: LGPL version 2.1 or later$' "$work/strings.txt" \
  || { echo "libavcodec does not say LGPL" >&2; exit 1; }
if grep -oE 'lib[a-z]+ license: .*' "$work/strings.txt" | grep -qv 'LGPL version 2.1 or later$'; then
  echo "a library inside is not LGPL 2.1 or later" >&2; exit 1
fi
if grep -qE -- '--enable-(gpl|nonfree|version3)' "$work/strings.txt"; then
  echo "an FFmpeg inside is GPL, nonfree or version3" >&2; exit 1
fi
grep -E "^ *gpl *: *(false|NO)|gpl.*false" "$work/mpv-configure.txt" | sed 's/^ */    mpv configure: /' | tee -a "$info" || true
sha256sum "$lib" | sed 's/^/    sha256 /' | tee -a "$info"
ls -l "$lib" | awk '{print "    bytes " $5}' | tee -a "$info"
