#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
image="${1:?specify an image with Bash and Python 3}"
state=$(mktemp -d)
mkdir "$state/crontabs"
trap 'rm -rf "$state"' EXIT HUP INT TERM
docker run --rm --read-only --network none --cap-drop ALL \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$base/tests,dst=/tests,readonly" \
    --mount "type=bind,src=$base/net/usr/bin/wifi_schedule.sh,dst=/usr/bin/wifi_schedule.sh,readonly" \
    --mount "type=bind,src=$base/net/usr/share/wifischedule,dst=/usr/share/wifischedule,readonly" \
    --mount "type=bind,src=$base/tests/mock-command.py,dst=/usr/libexec/wifischedule-rfkill,readonly" \
    --mount "type=bind,src=$state,dst=/state" \
    --mount "type=bind,src=$state/crontabs,dst=/etc/crontabs" \
    --entrypoint python3 "$image" /tests/dispatch.py
