#!/bin/bash
# Runs the suite, rests, and runs it again: a pane that is busy, then done.
while true; do
    clear
    echo "Running tests…"
    python3 -m unittest discover -s tests -v 2>&1
    echo
    echo "Next run in 45 s"
    sleep 45
done
