# The demo host App Review pairs with: Herdr, sshd and `bleat`, on Fly.
# See Demo/README.md. Everything a paired device can reach is disposable:
# the home directory is rebuilt at every boot and holds no secret.
FROM debian:bookworm-slim

ARG BLEAT_VERSION=1.0.1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server ca-certificates curl python3 iptables util-linux procps \
      htop less vim-tiny git qrencode tini \
 && rm -rf /var/lib/apt/lists/*

# Both installers check their downloads against published checksums.
RUN curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/local/bin sh \
 && curl -fsSL https://raw.githubusercontent.com/partofinc/bleat-apple/main/Scripts/install.sh \
      | BLEAT_VERSION=$BLEAT_VERSION BLEAT_INSTALL_DIR=/usr/local/bin sh \
 && herdr --version && bleat --version

# Key-only logins, one account, no root.
RUN useradd --create-home --shell /bin/bash demo \
 && passwd --lock demo \
 && mkdir -p /run/sshd
COPY sshd_config /etc/ssh/sshd_config
COPY limits.conf /etc/security/limits.d/demo.conf

COPY project /opt/demo/project
COPY entrypoint.sh populate.sh pair-server.py /opt/demo/
RUN chmod 755 /opt/demo/entrypoint.sh /opt/demo/populate.sh /opt/demo/pair-server.py

EXPOSE 22 8080
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/opt/demo/entrypoint.sh"]
