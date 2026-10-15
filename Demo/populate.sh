#!/bin/bash
# Fills the demo session with workspaces running real programs, so every screen
# of the app has something live in it. Runs as `demo` once the session is up.
#
# No AI agent runs here, deliberately: one needs an API key, and anyone who
# pairs has a shell that could read it. See Demo/README.md.
set -euo pipefail
export HERDR_SESSION=demo
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID 2>/dev/null || true

# The session's socket appears a moment after the client starts.
for _ in $(seq 1 60); do
    herdr workspace list >/dev/null 2>&1 && break
    sleep 0.5
done

workspace() {    # workspace <label> <cwd> → prints the root pane id
    herdr workspace create --label "$1" --cwd "$2" --no-focus |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'
}

web=~/projects/web-app
# A real server, and a client polling it, so the log moves.
pane=$(workspace "web-app" "$web")
herdr pane run "$pane" "python3 -m http.server 3000 --bind 127.0.0.1 --directory public"
pane=$(workspace "traffic" "$web")
herdr pane run "$pane" "./scripts/traffic.sh"

# A test suite that reruns, so a pane goes from busy to finished and back.
pane=$(workspace "tests" "$web")
herdr pane run "$pane" "./scripts/watch-tests.sh"

pane=$(workspace "system" ~)
herdr pane run "$pane" "htop"

# A shell at its prompt with something to look at, for typing.
pane=$(workspace "notes" "$web")
herdr pane run "$pane" "clear; cat WELCOME.txt"

echo "demo: populated $(herdr workspace list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["result"]["workspaces"]))') workspaces"
