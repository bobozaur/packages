#!/bin/sh
set -eu
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "${1:-$base/net/usr/share/wifischedule/time.sh}"

equal() { [ "$1" = "$2" ] || { echo "expected $1, got $2" >&2; exit 1; }; }
window() {
    expected="$1"; shift
    actual=1
    schedule_window_active "$@" && actual=0
    equal "$expected" "$actual"
}

equal 0 "$(schedule_time_minutes 0:0)"
equal 365 "$(schedule_time_minutes 6:5)"
equal 365 "$(schedule_time_minutes 06:05)"
equal 489 "$(schedule_time_minutes 08:09)"
equal 1439 "$(schedule_time_minutes 23:59)"
for invalid in '' 24:00 12:60 006:05 6:005 -1:30 6 6: 6:5:2 a:3; do
    if schedule_time_minutes "$invalid" >/dev/null 2>&1; then
        echo "accepted invalid time: $invalid" >&2; exit 1
    fi
done
equal 0,1,6 "$(schedule_weekdays 0 Sunday Monday Saturday)"
equal 1,2,0 "$(schedule_weekdays 1 Sunday Monday Saturday)"
if schedule_weekdays 0 NotMonday >/dev/null; then exit 1; fi
if schedule_weekdays 0 >/dev/null; then exit 1; fi

# Same-day boundaries and exact weekday ownership.
window 1 360 1320 1 1 359
window 0 360 1320 1 1 360
window 0 360 1320 1 1 1319
window 1 360 1320 1 1 1320
window 1 360 1320 1 2 720
# Overnight early hours belong to yesterday, including the weekly boundary.
window 0 1320 360 1 1 1320
window 0 1320 360 1 2 0
window 0 1320 360 1 2 359
window 1 1320 360 1 2 360
window 1 1320 360 1 1 300
window 0 1320 360 6 0 300
window 0 1320 360 0 1 300
window 1 1320 360 0 0 300
window 1 0 0 0,1,2,3,4,5,6 2 0
window 1 365 365 1 1 365
echo 'schedule time and weekday boundaries passed'
