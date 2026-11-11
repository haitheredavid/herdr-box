# herdr-box as a container: systemd as PID 1, sshd, and the system layer (apt,
# Docker, Tailscale, mise) baked in. The bootstrap still runs at every boot
# (herdr-box-bootstrap.service), the way it would on a dedicated machine, but only
# finds the system layer in place. Build context: the repo root.
#
# BASE is normally the dotfiles repo's linux/Dockerfile image (terraform builds it);
# a fresh /home volume starts with that image's home. Plain Ubuntu works too.
ARG BASE=ubuntu:24.04
FROM ${BASE}
USER root
WORKDIR /
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session \
        openssh-server sudo curl ca-certificates python3 iproute2 kmod \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable ssh.service \
    && systemctl mask systemd-firstboot.service getty@tty1.service
# Only what the system phase reads, so config edits don't rebuild this layer.
COPY bootstrap /opt/herdr-box/bootstrap
COPY config/mise.toml config/mise.amd64.toml /opt/herdr-box/config/
RUN bash /opt/herdr-box/bootstrap/bootstrap.sh --system && rm -rf /var/lib/apt/lists/*
COPY config /opt/herdr-box/config
COPY image/herdr-box-bootstrap.service /etc/systemd/system/
RUN systemctl enable herdr-box-bootstrap.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
