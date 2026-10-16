# The demo host App Review pairs with: Herdr, sshd and `bleat`, on Fly.
# See Demo/README.md. Everything a paired device can reach is disposable:
# the home directory is rebuilt at every boot and holds no secret.
FROM debian:bookworm-slim

ARG BLEAT_VERSION=1.0.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl python3 iptables util-linux procps \
      htop less vim-tiny git qrencode tini sudo e2fsprogs \
 && rm -rf /var/lib/apt/lists/*

# Both pinned and checked against checksums. herdr is pinned because
# populate.sh reads its JSON; its installer only fetches the latest, so the
# release binary is fetched directly. Bump both together, after re-running
# populate.sh against the new herdr.
ARG HERDR_VERSION=0.9.5
ARG HERDR_SHA256=14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d
RUN curl -fsSL -o /usr/local/bin/herdr \
      https://github.com/herdrdev/herdr/releases/download/v$HERDR_VERSION/herdr-linux-x86_64 \
 && echo "$HERDR_SHA256  /usr/local/bin/herdr" | sha256sum -c - \
 && chmod 755 /usr/local/bin/herdr \
 && curl -fsSL https://raw.githubusercontent.com/partofinc/bleat-apple/main/Scripts/install.sh \
      | BLEAT_VERSION=$BLEAT_VERSION BLEAT_INSTALL_DIR=/usr/local/bin sh \
 && herdr --version && bleat --version

# Key-only logins, one account, no root. The pairing page runs as its own
# user, which demo cannot signal or inspect, and may run exactly one command
# as demo.
RUN useradd --create-home --shell /bin/bash demo \
 && passwd --lock demo \
 && useradd --system --home-dir /var/lib/pairpage --create-home --shell /usr/sbin/nologin pairpage \
 && echo 'pairpage ALL=(demo) NOPASSWD: /usr/local/bin/bleat pair *' > /etc/sudoers.d/pairpage \
 && chmod 440 /etc/sudoers.d/pairpage \
 && visudo -cf /etc/sudoers.d/pairpage \
 && mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY limits.conf /etc/security/limits.d/demo.conf

COPY project /opt/demo/project
COPY entrypoint.sh populate.sh pair-server.py /opt/demo/
RUN chmod 755 /opt/demo/entrypoint.sh /opt/demo/populate.sh /opt/demo/pair-server.py

EXPOSE 22 8080
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/opt/demo/entrypoint.sh"]
