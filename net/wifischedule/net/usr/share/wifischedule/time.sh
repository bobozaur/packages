# Normalize the H:M format accepted by LuCI without shell octal arithmetic.
schedule_time_minutes()
{
    local hour="${1%:*}" minute="${1#*:}"
    case "$1" in *:*:*) return 1 ;; *:*) ;; *) return 1 ;; esac
    case "$hour:$minute" in *[!0-9:]*|:*|*:) return 1 ;; esac
    [ "${#hour}" -le 2 ] && [ "${#minute}" -le 2 ] || return 1
    hour="${hour#0}"; minute="${minute#0}"
    hour="${hour:-0}"; minute="${minute:-0}"
    [ "$hour" -lt 24 ] && [ "$minute" -lt 60 ] || return 1
    echo "$((hour * 60 + minute))"
}

# UCI stores English weekday names; cron and the window predicate use 0..6.
# The shift assigns an overnight stop to the day after its configured start.
schedule_weekdays()
{
    local offset="$1" day number result=""
    shift
    [ "$#" -gt 0 ] || return 1
    for day in "$@"; do
        case "$day" in
            Sunday) number=0 ;; Monday) number=1 ;; Tuesday) number=2 ;;
            Wednesday) number=3 ;; Thursday) number=4 ;; Friday) number=5 ;;
            Saturday) number=6 ;; *) return 1 ;;
        esac
        number=$(((number + offset) % 7))
        result="${result}${result:+,}${number}"
    done
    echo "$result"
}

# Inputs are normalized minutes and weekdays. Windows are [start, stop).
# Equal times describe a stop-only event, so they never grant an allow window.
schedule_window_active()
{
    local start="$1" stop="$2" days="$3" today="$4" now="$5" owner
    [ "$start" -ne "$stop" ] || return 1
    owner="$today"
    if [ "$start" -lt "$stop" ]; then
        [ "$now" -ge "$start" ] && [ "$now" -lt "$stop" ] || return 1
    elif [ "$now" -lt "$stop" ]; then
        owner=$(((today + 6) % 7))
    else
        [ "$now" -ge "$start" ] || return 1
    fi
    case ",$days," in *",$owner,"*) return 0 ;; esac
    return 1
}
