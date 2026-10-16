#!/bin/bash
# Fills the demo session with workspaces running real programs, so every screen
# of the app has something live in it. Runs as `demo` once the session is up.
#
# No AI agent runs here, deliberately: one needs an API key, and anyone who
# pairs has a shell that could read it. See docs/demo-host.md.
set -euo pipefail
export HERDR_SESSION=demo
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID 2>/dev/null || true

# The session's socket appears a moment after the client starts.
for _ in $(seq 1 60); do
    herdr workspace list >/dev/null 2>&1 && break
    sleep 0.5
done

# entrypoint.sh deletes the session before each start, so this normally finds
# it empty; the check keeps a second run from duplicating everything. Read into
# a variable first: `herdr … | grep -q` can fail under pipefail when grep exits
# on the match and herdr dies of SIGPIPE.
labels() {
    herdr workspace list | python3 -c 'import json,sys; print("\n".join(w["label"] for w in json.load(sys.stdin)["result"]["workspaces"]))'
}
existing=$(labels)
if grep -qx "web-app" <<<"$existing"; then
    echo "demo: already populated"
    exit 0
fi

workspace() {    # workspace <label> <cwd> → prints the root pane id
    herdr workspace create --label "$1" --cwd "$2" --no-focus |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'
}

# The app titles a pane by its terminal title, which a shell sets only at its
# prompt; a program started from it keeps whatever was set last. So each one
# names itself first.
run() {    # run <pane> <title> <command>
    herdr pane run "$1" "printf '\\033]0;%s\\007' '$2'; $3"
}

# The workspace herdr starts with.
first=$(herdr workspace list | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspaces"][0]["workspace_id"])')
herdr workspace rename "$first" home >/dev/null

web=~/projects/web-app
# A real server, and a client polling it, so the log moves.
pane=$(workspace "web-app" "$web")
run "$pane" "web server" "python3 -m http.server 3000 --bind 127.0.0.1 --directory public"
pane=$(workspace "traffic" "$web")
run "$pane" "traffic" "./scripts/traffic.sh"

# A test suite that reruns, so a pane goes from busy to finished and back.
pane=$(workspace "tests" "$web")
run "$pane" "test suite" "./scripts/watch-tests.sh"

pane=$(workspace "system" ~)
run "$pane" "htop" "htop"

# A shell at its prompt with something to look at, for typing.
pane=$(workspace "notes" "$web")
herdr pane run "$pane" "clear; cat WELCOME.txt"

# Read the host back rather than trust each reply.
expected=$'home\nweb-app\ntraffic\ntests\nsystem\nnotes'
actual=$(labels)
if [[ "$actual" != "$expected" ]]; then
    echo "demo: populated wrong: $(tr '\n' ' ' <<<"$actual")" >&2
    exit 1
fi
echo "demo: populated $(wc -l <<<"$actual" | tr -d ' ') workspaces"
