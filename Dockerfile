# The two toolchains Leyla's LGPL libmpv is built with (build.sh). Sources
# are never fetched in here: build.sh downloads and checks them, then
# mounts them read-only, so the image is only compilers and the system
# libraries the Linux build links against.

# Linux x86_64 on bookworm: glibc 2.36 is the newest symbol version the
# library can then need, and every distribution with GTK 3 (which Flutter
# needs) has the shared libraries named below.
FROM debian:bookworm@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858 AS linux
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config nasm python3 python3-venv git xz-utils ca-certificates file \
      libasound2-dev libpulse-dev libegl-dev libgl-dev libdrm-dev libva-dev libssl-dev \
      zlib1g-dev libfreetype-dev libharfbuzz-dev libfribidi-dev libfontconfig-dev hwdata \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/py && /opt/py/bin/pip install --no-cache-dir meson==1.12.1 ninja==1.13.2
ENV PATH=/opt/py/bin:$PATH
COPY inside.sh /usr/local/bin/leyla-libmpv-inside
ENTRYPOINT ["/usr/local/bin/leyla-libmpv-inside"]

# Windows x64 through mingw-w64 (win32 threads, so no winpthread DLL), on
# trixie for gcc 14 and mingw-w64 12. Everything ends up inside the one
# DLL; it needs only what ships with Windows.
FROM debian:trixie@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5 AS windows
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential pkg-config nasm python3 python3-venv git xz-utils ca-certificates file \
      gcc-mingw-w64-x86-64-win32 g++-mingw-w64-x86-64-win32 binutils-mingw-w64-x86-64 \
      mingw-w64-x86-64-dev mingw-w64-tools \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/py && /opt/py/bin/pip install --no-cache-dir meson==1.12.1 ninja==1.13.2
ENV PATH=/opt/py/bin:$PATH
COPY inside.sh /usr/local/bin/leyla-libmpv-inside
ENTRYPOINT ["/usr/local/bin/leyla-libmpv-inside"]
