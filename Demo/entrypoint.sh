#!/bin/bash
# Boots the demo host. Runs as root; everything a visitor can touch runs as
# `demo`. Fails closed: if the outbound block cannot be installed, the machine
# does not come up, because a paired device has a full shell here.
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

# --- A clean home at every boot: no pairing, file or process outlives a restart.
rm -rf /home/demo
mkdir -p /home/demo/.ssh /home/demo/projects
cp -a /etc/skel/. /home/demo/
cp -a /opt/demo/project /home/demo/projects/web-app
touch /home/demo/.ssh/authorized_keys
chmod 700 /home/demo/.ssh
chmod 600 /home/demo/.ssh/authorized_keys
chown -R demo:demo /home/demo

# --- No new outbound connections from this machine, DNS aside; replies to
# inbound SSH and HTTP are ESTABLISHED and pass. Whole-machine because Fly's
# kernel has no `owner` match (`-m owner`: "Extension owner revision 0 not
# supported"), and nothing here needs to dial out once it is running.
for table in iptables ip6tables; do
    $table -F OUTPUT
    $table -A OUTPUT -o lo -j ACCEPT
    $table -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    $table -A OUTPUT -p udp --dport 53 -j ACCEPT
    $table -A OUTPUT -p tcp --dport 53 -j ACCEPT
    $table -A OUTPUT -j REJECT
done
log "outbound blocked"

# --- sshd
/usr/sbin/sshd -D -e &
sshd_pid=$!

# --- A herdr session with a client holding it open, as docs/testing.md does
# for a scratch session: herdr needs a terminal to start one.
su - demo -c "script -qfec 'stty cols 160 rows 48; exec herdr session attach demo' /dev/null" \
    >/dev/null 2>&1 &
herdr_pid=$!

# --- Workspaces with real programs in them.
su - demo -c "/opt/demo/populate.sh"

# --- The pairing page.
# In the environment, not on a command line `ps` would show.
: "${DEMO_ENDPOINT:?}" "${DEMO_PASSWORD:?set it with: fly secrets set DEMO_PASSWORD=...}"
env -i HOME=/home/demo USER=demo LOGNAME=demo SHELL=/bin/bash \
    PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    DEMO_ENDPOINT="$DEMO_ENDPOINT" DEMO_PASSWORD="$DEMO_PASSWORD" \
    /usr/sbin/runuser -u demo -- python3 /opt/demo/pair-server.py &
pair_pid=$!

log "up: sshd $sshd_pid, herdr $herdr_pid, pairing page $pair_pid"

# --- Restart daily, which resets the home directory and every pairing. Fly
# restarts the machine when this exits.
( sleep "${DEMO_RESET_SECONDS:-86400}"; log "daily reset"; kill -TERM $$ ) &

wait -n "$sshd_pid" "$herdr_pid" "$pair_pid"
log "a service exited; restarting the machine"
exit 1
