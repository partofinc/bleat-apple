#!/bin/bash
# Boots the demo host. Runs as root; everything a visitor can touch runs as
# `demo`, and nothing `demo` can kill takes the machine down. Fails closed: if
# the outbound block or the size limits cannot be put in place, the machine
# does not come up, because a paired device has a full shell here.
# The reasoning: docs/demo-host.md.
set -euo pipefail

log() { echo "demo: $*"; }

# --- The name the app shows for this host; a Fly machine is named by its id.
hostname bleat-demo
grep -q bleat-demo /etc/hosts || echo "127.0.1.1 bleat-demo" >> /etc/hosts

# --- The host key, kept across deploys on the volume.
mkdir -p /data/ssh
if [[ ! -f /data/ssh/ssh_host_ed25519_key ]]; then
    ssh-keygen -q -t ed25519 -N '' -f /data/ssh/ssh_host_ed25519_key
    log "made a new host key"
fi
chmod 600 /data/ssh/ssh_host_ed25519_key

# --- Everything `demo` can write has a fixed size, and the home is a fresh
# filesystem at every boot: no pairing, file or process outlives a restart.
rm -f /data/home.img
truncate -s 512M /data/home.img
mkfs.ext4 -q -F /data/home.img
mkdir -p /home/demo
mount -o loop,nosuid,nodev /data/home.img /home/demo
mount -t tmpfs -o size=64m,mode=1777,nosuid,nodev tmpfs /tmp
mount -t tmpfs -o size=16m,mode=1777,nosuid,nodev tmpfs /var/tmp
mount -o remount,size=16m /dev/shm
mkdir -p /home/demo/.ssh /home/demo/projects
cp -a /etc/skel/. /home/demo/
cp -a /opt/demo/project /home/demo/projects/web-app
touch /home/demo/.ssh/authorized_keys
chmod 700 /home/demo/.ssh
chmod 600 /home/demo/.ssh/authorized_keys
chown -R demo:demo /home/demo
log "home, /tmp, /var/tmp and /dev/shm size-limited"

# --- No new outbound connections from this machine at all; replies to
# inbound SSH and HTTP are ESTABLISHED and pass. Not even DNS: port 53 open to
# any address is a way out, and nothing here resolves a name once it is up.
# Whole-machine because Fly's kernel has no `owner` match ("Extension owner
# revision 0 not supported").
for table in iptables ip6tables; do
    $table -F OUTPUT
    $table -A OUTPUT -o lo -j ACCEPT
    $table -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $table -A OUTPUT -j REJECT
done
log "outbound blocked"

# --- sshd. Logins get limits.conf through pam_limits.
/usr/sbin/sshd -D -e &
sshd_pid=$!

# --- herdr, as demo, with the same limits applied to the server itself:
# panes are its children, not SSH logins, so pam_limits never reaches them.
# demo can stop it (it is theirs); it is then started again and refilled,
# instead of the machine restarting and unpairing everyone.
herdr_loop() {
    while true; do
        su - demo -c "ulimit -u 256 -n 4096 -f 1048576; \
            script -qfec 'stty cols 160 rows 48; exec herdr session attach demo' /dev/null" \
            >/dev/null 2>&1 &
        local client=$!
        su - demo -c "/opt/demo/populate.sh" || log "populate failed"
        wait "$client" || true
        log "herdr client exited; starting it again"
        sleep 2
    done
}
herdr_loop &

# --- The pairing page, as its own user: demo cannot kill it or read its
# environment, which holds the password. It runs `bleat pair` as demo
# through one sudo rule.
: "${DEMO_ENDPOINT:?}" "${DEMO_PASSWORD:?set it with: fly secrets set DEMO_PASSWORD=...}"
env -i HOME=/var/lib/pairpage USER=pairpage LOGNAME=pairpage SHELL=/bin/sh \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    DEMO_ENDPOINT="$DEMO_ENDPOINT" DEMO_PASSWORD="$DEMO_PASSWORD" \
    /usr/sbin/runuser -u pairpage -- python3 /opt/demo/pair-server.py &
pair_pid=$!

log "up: sshd $sshd_pid, pairing page $pair_pid"

# --- Restart daily, which resets the home directory and every pairing. Fly
# restarts the machine when this exits.
( sleep "${DEMO_RESET_SECONDS:-86400}"; log "daily reset"; kill -TERM $$ ) &

# Only what demo cannot touch ends the machine.
wait -n "$sshd_pid" "$pair_pid"
log "sshd or the pairing page exited; restarting the machine"
exit 1
