# syntax=docker/dockerfile:1
#
# job-desktop: plain Debian 13 with a GNOME desktop. Nothing else is installed
# on purpose; I install what I need myself (Pi, OpenClaw, a Nextcloud client).
#
#   Web page (noVNC)   port 6080   no password, no login page
#   SSH                port 22     user "desktop", keys only, passwordless sudo
#
# Screen :1 is the machine's own, and by default has no desktop on it: Openbox
# and my start-up entries, nothing else. DESKTOP_SESSION_KIND=gnome brings the
# full GNOME desktop back (desktop/session). Each agent gets a screen of its
# own beside it, made with the "seat" command (desktop/seat explains it). The
# web page lists them all.
#
# THERE IS NO PASSWORD ON THE DESKTOP. Whoever can reach port 6080 has the
# whole machine. Only ever put it somewhere private (my tailnet).
#
# There is no systemd in here: a container has no init system. Things that
# install themselves as a systemd service will not start on their own.
#
# Where things are:
#   packages.txt   every package the image installs
#   desktop/       the start-up scripts, copied to /desktop in the image
#   config/        the few settings files, copied into /etc and the noVNC folder
#   test/          the check GitHub Actions runs before publishing the image
#
# Run it on its own (nothing is kept when the container is removed):
#   docker run -d --name job-desktop --shm-size=1g \
#     -p 127.0.0.1:6080:6080 -p 127.0.0.1:2222:22 \
#     -v ~/.ssh/id_ed25519.pub:/run/ssh-keys/authorized_keys:ro \
#     ghcr.io/dombarker99/job-desktop:main
#   then open http://localhost:6080  or  ssh -p 2222 desktop@localhost
#
# On the cluster the whole machine is kept on a volume, so anything installed
# later with apt survives a restart. /desktop/seed-machine explains how.
FROM debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY packages.txt /desktop/packages.txt
RUN apt-get update \
    && grep -Ev '^[[:space:]]*(#|$)' /desktop/packages.txt \
       | DEBIAN_FRONTEND=noninteractive xargs apt-get install -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* \
    && localedef -i en_US -f UTF-8 en_US.UTF-8 \
    # Installing the SSH server makes host keys. They must not be in a public
    # image, where everyone would share them; each machine makes its own at start.
    && rm -f /etc/ssh/ssh_host_*

# The one user. No password is set: SSH takes keys only and sudo asks for nothing.
RUN useradd --uid 1000 --user-group --create-home --shell /bin/bash desktop \
    && printf 'desktop ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/desktop \
    && chmod 0440 /etc/sudoers.d/desktop \
    && visudo --check \
    && install -d -m 1777 /tmp/.X11-unix /tmp/.ICE-unix

COPY --chmod=0755 desktop/entrypoint desktop/start-desktop desktop/session desktop/seed-machine desktop/healthcheck desktop/seat desktop/cua-mcp desktop/mailbox /desktop/
COPY desktop/system-bus.conf desktop/openbox-rc.xml /desktop/
COPY config/sshd.conf /etc/ssh/sshd_config.d/desktop.conf
COPY config/profile.sh /etc/profile.d/desktop.sh
COPY config/index.html /usr/share/novnc/index.html

# The same values are in config/profile.sh (login shells) and config/sshd.conf
# (commands run over SSH), so a program started from anywhere finds the desktop.
ENV LANG=en_US.UTF-8 \
    DISPLAY=:1 \
    XDG_RUNTIME_DIR=/tmp/desktop-runtime \
    XAUTHORITY=/tmp/desktop-runtime/Xauthority \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/tmp/desktop-runtime/system-bus \
    XDG_SESSION_TYPE=x11 XDG_SESSION_CLASS=user XDG_CURRENT_DESKTOP=GNOME \
    XDG_SESSION_DESKTOP=gnome DESKTOP_SESSION=gnome GNOME_SHELL_SESSION_MODE=user \
    LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe

LABEL org.opencontainers.image.title="job-desktop" \
      org.opencontainers.image.description="Plain Debian 13 with GNOME, noVNC without a password, and key-only SSH." \
      org.opencontainers.image.source="https://github.com/DomBarker99/job-desktop"

# Starts as root only to run the SSH server; the desktop itself runs as "desktop".
USER 0:0
WORKDIR /
EXPOSE 22 6080
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 CMD ["/desktop/healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/desktop/entrypoint"]
