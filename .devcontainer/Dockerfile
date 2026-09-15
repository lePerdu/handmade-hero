FROM alpine:3.23

ARG ODIN_VERSION=dev-2026-09
ARG ODIN_ARCH=amd64
RUN wget -O- https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-${ODIN_ARCH}-${ODIN_VERSION}.tar.gz \
    | tar x -zv -C /usr/local/ \
    && ln -sv /usr/local/odin-linux-*/odin /usr/local/bin/odin

RUN apk add --no-cache \
    git openssh-client \
    make clang-extra-tools \
    nodejs npm \
    wayland-dev wayland-libs-cursor wayland-libs-egl libxkbcommon \
    alsa-lib pipewire-alsa

ARG USERNAME=devcontainer
ARG UID=1000
ARG GID=1000
RUN addgroup -g $GID $USERNAME && \
    adduser -u $UID -G $USERNAME -D $USERNAME
