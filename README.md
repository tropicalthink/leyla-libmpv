# leyla-libmpv

The libmpv that [Leyla](https://leyla.media)'s Windows and Linux apps play
video through, built from pinned releases as **LGPL-2.1-or-later** only
(no GPL, no nonfree code). This repository is the corresponding source offer
for that library: the build recipe and every pin and checksum.

## What is built

| | |
|---|---|
| mpv | `-Dgpl=false`: LGPL-2.1-or-later. Client library only (`-Dlibmpv=true -Dcplayer=false`), no Lua or JavaScript, no rubberband, no libarchive, Blu-ray, DVD or CD. |
| FFmpeg | 8.1.3, the version Leyla's server ffmpeg pins, configured without `--enable-gpl`, `--enable-nonfree` or `--enable-version3`, and with `--disable-autodetect` so every external library is one named in `inside.sh`. All decoders, demuxers, parsers, protocols and filters; no encoders but PNG and MJPEG, no muxers, no devices. Unpatched. |
| inside it | dav1d (BSD-2-Clause), libplacebo (LGPL-2.1-or-later, OpenGL only), libass (ISC), nv-codec-headers (MIT; NVDEC is loaded from the driver at run time). Windows also: FreeType (FTL), HarfBuzz (MIT), FriBidi (LGPL-2.1-or-later), zlib, ANGLE's EGL headers (BSD-3-Clause). Linux also: libdisplay-info (MIT). |
| from the system (Linux) | glibc, libstdc++, zlib, OpenSSL 3, FreeType, HarfBuzz, FriBidi, Fontconfig, libEGL, libdrm, libva, PulseAudio and ALSA client libraries: each is on any distribution that runs a GTK 3 app (`BUILDINFO` lists the exact `NEEDED` names and the newest glibc symbol). |
| from Windows | only system DLLs (`BUILDINFO` lists the imports). The ANGLE DLLs ship beside it.|

### DTS-HD MA and TrueHD

FFmpeg's `dca` decoder runs with its defaults, so a DTS-HD MA stream decodes
to its lossless layer (`s32p`), not the lossy core. TrueHD decodes in full.

## Building

With Docker:

```sh
./build.sh all        # fetch, Linux, Windows, source archive (5 to 10 minutes each)
./build.sh images     # leyla-libmpv:<tag> and leyla-libmpv-source:<tag>
./build.sh check <file> [seek-seconds]   # play a file through the Linux build
```

Output goes to `$LIBMPV_BUILD_DIR/out/<tag>/` (default
`~/leyla-build/libmpv-lgpl`): `linux-x86_64/` (`lib/libmpv.so.2`,
`lib/pkgconfig/mpv.pc`, `include/mpv/`), `windows-x64/` (`libmpv-2.dll`,
`libmpv.dll.a`, `include/mpv/`), each with a `BUILDINFO` recording every
configure line, mpv's feature summary and the LGPL proof read back from the
built file, and `leyla-libmpv-<tag>-source.tar.xz`. `TAG` names the
current build: mpv's and FFmpeg's versions plus a hash of `sources.lock`,
`Dockerfile` and `inside.sh`.

Every version and checksum is in `sources.lock`; `build.sh fetch` refuses a
download whose SHA-256 differs.

## Replacing the library

As the LGPL allows, build this recipe (or your own libmpv) and put the
result in place of the library beside the app: `lib/libmpv.so.2` on Linux,
`libmpv-2.dll` beside `leyla.exe` on Windows.

## The source offer

`leyla-libmpv-<tag>-source.tar.xz` holds every source tarball exactly as
fetched, libplacebo's tree with its submodules at the pinned commit, this
recipe and both `BUILDINFO` files. It is published with every Leyla release that
ships a desktop app, for example
<https://leyla.media/dl/v0.15.0/leyla-libmpv-0.41.0-ffmpeg8.1.3-b0708471d18c-source.tar.xz>
(SHA-256 `266a564e8c6a15051ff6e8fa2d511ff52a00363acba4668fbd6a7bcda21d2791`).

## Licence

LGPL-2.1-or-later (`LICENSE`). mpv, FFmpeg, libplacebo, dav1d, libass and
the rest keep their own licences, listed in `BUILDINFO`.
