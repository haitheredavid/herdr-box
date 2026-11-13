# herdr-box as a container: systemd as PID 1, sshd, and the system layer (apt,
# Docker, Tailscale, mise) baked in. The bootstrap still runs at every boot
# (herdr-box-early.service for the host phase, herdr-box-bootstrap.service for the
# rest), the way it would on a dedicated machine, but only finds the system layer
# in place. Build context: the repo root. No box config goes into the image; the
# box's dir is mounted or uploaded at /opt/herdr-box/box at run time.
#
# Stages follow the bootstrap phases, and each COPYs only what its phase reads,
# so edits to the host/user phases or shared config don't rebuild packages/system.
# BASE is the only place the Ubuntu ref lives (Renovate pins and bumps the digest).
ARG BASE=ubuntu:24.04@sha256:2198e4c65076e9cb0b3d695219df667c0e3b0072da64ca3c2648aca17dcecaf5

FROM ${BASE} AS os
USER root
WORKDIR /
ARG DEBIAN_FRONTEND=noninteractive
# The stock ubuntu user would take uid 1000 from BOX_USER.
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session \
        openssh-server sudo curl ca-certificates gnupg python3 iproute2 kmod \
    && rm -rf /var/lib/apt/lists/* \
    && userdel -r ubuntu \
    && systemctl enable ssh.service \
    && systemctl mask systemd-firstboot.service getty@tty1.service

FROM os AS packages
ARG DEBIAN_FRONTEND=noninteractive
ARG EXTRA_APT_PACKAGES=""
COPY bootstrap/bootstrap.sh /opt/herdr-box/bootstrap/
COPY bootstrap/lib /opt/herdr-box/bootstrap/lib
COPY bootstrap/phases/10-packages.sh /opt/herdr-box/bootstrap/phases/
RUN EXTRA_APT_PACKAGES="${EXTRA_APT_PACKAGES}" bash /opt/herdr-box/bootstrap/bootstrap.sh --phases packages \
    && rm -rf /var/lib/apt/lists/*

FROM packages AS system
ARG DEBIAN_FRONTEND=noninteractive
COPY bootstrap/phases/20-system.sh /opt/herdr-box/bootstrap/phases/
COPY bootstrap/bin /opt/herdr-box/bootstrap/bin
COPY config/mise.toml config/mise.amd64.toml /opt/herdr-box/config/
RUN bash /opt/herdr-box/bootstrap/bootstrap.sh --phases system

FROM system AS box
ARG GIT_SHA=""
ARG BUILD_HASH=""
LABEL org.opencontainers.image.title="herdr-box" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      dev.herdr-box.build-hash="${BUILD_HASH}"
COPY bootstrap /opt/herdr-box/bootstrap
# Shared config only; per-box config never enters the image.
COPY config/mise.toml config/mise.amd64.toml config/tools.tsv config/checks.txt /opt/herdr-box/config/
COPY image/herdr-box-early.service image/herdr-box-bootstrap.service /etc/systemd/system/
# Host keys are made per box on the state volume (30-host); every container gets
# its own machine-id at boot.
RUN rm -f /etc/ssh/ssh_host_* \
    && : > /etc/machine-id \
    && systemctl enable herdr-box-early.service herdr-box-bootstrap.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
