# EchoFrame build environment: Ubuntu 22.04 + CUDA 12.8.
#
# CUDA 12.8 rather than 13.x: only the CUDA 12 branch of CMakeLists.txt includes
# sm_61 (Pascal), which CUDA 13 dropped. No cuDNN -- nothing here links it.
#
# Build from the REPOSITORY ROOT (not docker/), because the image copies the
# vcpkg manifest out of the source tree:
#
#   docker build -t echoframe-dev:cuda12.8 -f docker/ubuntu22.04-cuda12.8.Dockerfile .
FROM nvidia/cuda:12.8.2-devel-ubuntu22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG FZF_VERSION=0.66.0

# Non-root user for bind-mounted builds. Defaults match the first regular user on
# a stock Ubuntu/WSL install, so build output in a mounted checkout is owned by
# you rather than root. Override with --build-arg EF_UID=$(id -u) if yours differ.
ARG EF_USER=ef
ARG EF_UID=1000
ARG EF_GID=1000

ENV VCPKG_ROOT=/opt/vcpkg
ENV VCPKG_DEFAULT_TRIPLET=x64-linux
ENV VCPKG_DEFAULT_BINARY_CACHE=/opt/vcpkg-cache
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH="${VCPKG_ROOT}:${CARGO_HOME}/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    fontconfig \
    git \
    libasound2 \
    libatk-bridge2.0-0 \
    libdbus-1-3 \
    libegl1 \
    libgl1 \
    libice6 \
    libnss3 \
    libopengl0 \
    libsm6 \
    libsndfile1 \
    libssl-dev \
    libx11-xcb1 \
    libxext6 \
    libxft2 \
    libxkbcommon-x11-0 \
    libxrender1 \
    libxtst6 \
    libxi6 \
    libxcb-cursor0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-randr0 \
    libxcb-render-util0 \
    libxcb-shape0 \
    libxcb-xfixes0 \
    libxcb-xinerama0 \
    libxcb-xinput0 \
    libxt6 \
    locales \
    ninja-build \
    pkg-config \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    sudo \
    tar \
    unzip \
    xauth \
    zip \
 && rm -rf /var/lib/apt/lists/*

# Shell tooling for distrobox sessions that inherit host dotfiles. fzf comes from
# upstream because Ubuntu 22.04's package predates `fzf --zsh`; the rest come from
# cargo because the packaged Rust is too old.
RUN curl -fsSL "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_amd64.tar.gz" \
      | tar -xz -C /usr/local/bin fzf \
 && curl https://sh.rustup.rs -sSf | sh -s -- -y --no-modify-path \
 && cargo install --root "${CARGO_HOME}" fd-find just lsd sheldon starship zellij zoxide \
 && rm -rf /root/.cache "${CARGO_HOME}/registry" "${RUSTUP_HOME}/downloads" "${RUSTUP_HOME}/tmp"

# Bootstrapped only: vcpkg runs in manifest mode, so anything installed into
# $VCPKG_ROOT/installed the classic way would be ignored.
RUN git clone --depth 1 https://github.com/microsoft/vcpkg.git "${VCPKG_ROOT}" \
 && "${VCPKG_ROOT}/bootstrap-vcpkg.sh" -disableMetrics \
 && mkdir -p "${VCPKG_DEFAULT_BINARY_CACHE}"

# Pre-build the manifest's dependencies into the binary cache so a later
# configure restores them instead of rebuilding hdf5/matio.
COPY echoframe/cpp/src/vcpkg.json /tmp/ef-manifest/vcpkg.json
RUN cd /tmp/ef-manifest \
 && "${VCPKG_ROOT}/vcpkg" install --triplet "${VCPKG_DEFAULT_TRIPLET}" \
 && rm -rf /tmp/ef-manifest \
 # Reclaim the space but KEEP the directories: vcpkg takes its run lock at
 # buildtrees/vcpkg-running.lock and fails to start if that directory is absent.
 && rm -rf "${VCPKG_ROOT}/buildtrees" "${VCPKG_ROOT}/downloads" "${VCPKG_ROOT}/packages" \
 && mkdir -p "${VCPKG_ROOT}/buildtrees" "${VCPKG_ROOT}/downloads" "${VCPKG_ROOT}/packages" \
 # Every one of these is written at configure time, by whichever user the
 # container runs as -- `--user ef`, a distrobox-mapped host user, or root.
 && chmod -R a+rwX "${VCPKG_ROOT}/buildtrees" "${VCPKG_ROOT}/downloads" \
                   "${VCPKG_ROOT}/packages" "${VCPKG_DEFAULT_BINARY_CACHE}"

# MathWorks ServiceHost (online licence validation) is a GTK app and fails with
# error 5202 without these; R2024a's bundled installer needs gtk2 as well.
#
# Kept as the last expensive layer: this is the list that actually changes, so
# adding a package costs one apt layer rather than a vcpkg and cargo rebuild.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgtk-3-0 \
    libgtk2.0-0 \
    libgbm1 \
    libcups2 \
 # Runtime, not just build: numpy/pytest for the tests, h5py for v7.3 .mat
 # files, matplotlib and scipy for the examples and read_BF/read_PDI.
    python3-numpy \
    python3-pytest \
    python3-h5py \
    python3-matplotlib \
    python3-scipy \
 && rm -rf /var/lib/apt/lists/*

# Last, so the layers above stay cached when UID/GID change. USER stays root --
# distrobox maps the host user itself; use `docker run --user ef` otherwise.
RUN if getent group "${EF_GID}" >/dev/null; then \
        groupmod -n "${EF_USER}" "$(getent group "${EF_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${EF_GID}" "${EF_USER}"; \
    fi \
 && if getent passwd "${EF_UID}" >/dev/null; then \
        usermod -l "${EF_USER}" -d "/home/${EF_USER}" -m -g "${EF_GID}" \
                "$(getent passwd "${EF_UID}" | cut -d: -f1)"; \
    else \
        useradd -m -u "${EF_UID}" -g "${EF_GID}" -s /bin/bash "${EF_USER}"; \
    fi \
 && echo "${EF_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${EF_USER}" \
 && chmod 0440 "/etc/sudoers.d/${EF_USER}"
