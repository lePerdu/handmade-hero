FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential clang unzip wget git openssh-client \
        nodejs npm \
        wayland-protocols wayland-utils \
        pipewire-alsa \
    && rm -rf /var/lib/apt/lists/*

ARG ODIN_VERSION=dev-2026-09
ARG ODIN_ARCH=amd64
RUN wget -O- https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-${ODIN_ARCH}-${ODIN_VERSION}.tar.gz \
    | tar x -zv -C /usr/local/ \
    && ln -sv /usr/local/odin-linux-*/odin /usr/local/bin/odin

ARG OLS_VERSION=2026-08
ARG OLS_ARCH=x86_64
RUN wget https://github.com/DanielGavin/ols/releases/download/dev-${OLS_VERSION}/ols-${OLS_ARCH}-unknown-linux-gnu.zip \
    && unzip ols-${OLS_ARCH}-unknown-linux-gnu.zip -d /usr/local/ols \
    && ln -sv /usr/local/ols/ols-${OLS_ARCH}-unknown-linux-gnu /usr/local/bin/ols \
    && ln -sv /usr/local/ols/odinfmt-${OLS_ARCH}-unknown-linux-gnu /usr/local/bin/odinfmt

ARG USERNAME=devcontainer
ARG UID=1000
ARG GID=1000
RUN useradd -mUu $UID -s /bin/bash $USERNAME
