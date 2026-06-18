#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This bootstrap script must run inside Linux or WSL2."
  exit 1
fi

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

apt_get=(apt-get)
if [[ "$(id -u)" -ne 0 ]]; then
  apt_get=(sudo apt-get)
fi

"${apt_get[@]}" update
"${apt_get[@]}" install -y --no-install-recommends \
  ack \
  antlr3 \
  asciidoc \
  autoconf \
  automake \
  autopoint \
  bash \
  bc \
  binutils \
  bison \
  build-essential \
  bzip2 \
  ca-certificates \
  ccache \
  clang \
  cmake \
  cpio \
  curl \
  device-tree-compiler \
  dwarves \
  ecj \
  fastjar \
  file \
  flex \
  g++ \
  g++-multilib \
  gawk \
  gcc \
  gcc-multilib \
  genisoimage \
  gettext \
  git \
  gperf \
  haveged \
  help2man \
  intltool \
  libc6-dev-i386 \
  libelf-dev \
  libglib2.0-dev \
  libgmp3-dev \
  libltdl-dev \
  libmpc-dev \
  libmpfr-dev \
  libncurses-dev \
  libpython3-dev \
  libreadline-dev \
  libssl-dev \
  libtool \
  libzstd-dev \
  lld \
  llvm \
  lrzsz \
  mkisofs \
  msmtp \
  nano \
  ninja-build \
  p7zip \
  p7zip-full \
  patch \
  pkgconf \
  python3 \
  python3-docutils \
  python3-pip \
  python3-ply \
  python3-setuptools \
  qemu-utils \
  re2c \
  rsync \
  scons \
  squashfs-tools \
  subversion \
  swig \
  tar \
  texinfo \
  uglifyjs \
  unzip \
  upx-ucl \
  vim \
  wget \
  xmlto \
  xxd \
  zlib1g-dev \
  zstd
