#!/bin/ash
# shellcheck shell=dash

# Copyright (c) 2016, prpl Foundation
# Copyright  ANNO DOMINI  2024  Jan Chren ~rindeal  <dev.rindeal{a}gmail.com>
#
# Permission to use, copy, modify, and/or distribute this software for any purpose with or without
# fee is hereby granted, provided that the above copyright notice and this permission notice appear
# in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE
# INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
# FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
# ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# Author: Nils Koenig <openwrt@newk.it>

set -o pipefail

. /usr/share/wifischedule/time.sh


SCRIPT="$0"
PACKAGE="wifi_schedule"
GLOBAL="${PACKAGE}.@global[0]"
LOCKFILE="/tmp/${PACKAGE}.lock"
LOGGING=0 #default is off


# Converts the result of arithmetic expansion to a normal command return code
# Usage: if _arith_bool $(( 3*4 > 12 && foo <= bar )) ...
_arith_bool() { [ "$1" -ne 0 ] ;}

# Usage: if _uci_bool $(_uci_get_value "foo.bar") ...
_uci_bool() { [ "$1" -eq 1 ] ;}

# Usage: _join_by_char , foo bar baz
# Prints: `foo.bar,baz`
_join_by_char()
{
    local IFS
    IFS="$1"
    shift
    printf "%s" "$*"
}

## Usage: _log [emerg, alert, crit, err, warning, notice, info, debug] "Message ..."
_log()
{
    local severity="$1"
    shift
    _uci_bool "${LOGGING}" || return
    logger -t "${PACKAGE}" -p "user.${severity}" "$@"
}

_exit()
{
    exit "$1"
}

_uci_get_value_raw() { uci get "$1" 2> /dev/null ;}

_uci_get_value()
{
    _uci_get_value_raw "$1"
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        _log "notice" "Could not determine UCI value '$1'"
    fi
    return "${rc}"
}

_cfg_global_is_enabled() {
    local value
    value="$(_uci_get_value "${GLOBAL}.enabled")"
    _uci_bool "${value}"
}

_cfg_global_is_unload_modules_enabled()
{
    local unload_modules
    unload_modules="$(_uci_get_value_raw "${GLOBAL}.unload_modules")" || return 1
    _uci_bool "${unload_modules}"
}

# Prints: `entry1_name$'\n'entry2_name$'\n'...`
_cfg_list_entries()
{
    # Positional aliases can select a different entry after another is removed.
    uci -X show "${PACKAGE}" | awk -F= '$2 == "entry" { n = split($1, a, "."); print a[n] }'
}

_cfg_entry_is_enabled() {
    local entry="$1" value
    [ "$(_uci_get_value "${PACKAGE}.${entry}")" = entry ] || return 1
    value="$(_uci_get_value "${PACKAGE}.${entry}.enabled")" || return 1
    _uci_bool "${value}"
}

_cfg_entry_is_now_within_timewindow()
{
    local entry="$1" nowdow="$2" nowminutes="$3"
    local starttime stoptime daysofweek startminutes stopminutes days
    starttime=$(_uci_get_value "${PACKAGE}.${entry}.starttime") || return 1
    stoptime=$(_uci_get_value "${PACKAGE}.${entry}.stoptime") || return 1
    daysofweek=$(_uci_get_value "${PACKAGE}.${entry}.daysofweek") || return 1
    startminutes=$(schedule_time_minutes "$starttime") || return 1
    stopminutes=$(schedule_time_minutes "$stoptime") || return 1
    days=$(schedule_weekdays 0 $daysofweek) || return 1
    schedule_window_active "$startminutes" "$stopminutes" "$days" "$nowdow" "$nowminutes"
}

_cfg_can_wifi_run_now()
{
    local entry now nowdow nowminutes
    now=$(date '+%w %H:%M') || return 1
    nowdow="${now%% *}"
    nowminutes=$(schedule_time_minutes "${now#* }") || return 1
    for entry in $(_cfg_list_entries)
    do
        test -n "${entry}" || continue
        _cfg_entry_is_enabled "${entry}" || continue
        _cfg_entry_is_now_within_timewindow "${entry}" "$nowdow" "$nowminutes" && return 0
    done
    return 1
}

# crontab writes cron.update for the running daemon. Restarting its service
# from a cron job kills the job itself; starting after a file change may also
# replace the procd instance, so only start an absent daemon.
_cron_update() { service cron running >/dev/null 2>&1 || service cron start >/dev/null; }

# The privileged OpenWrt crontab is optional until first use. Read it completely
# before a write so a real read failure cannot replace existing jobs with empty input.
_crontab_read() { crontab -l 2>/dev/null || [ ! -e /etc/crontabs/root ]; }

_crontab_append_line()
{
    local current
    current=$(_crontab_read) || return
    { [ -z "$current" ] || printf '%s\n' "$current"
      printf '%s\n' "$(_join_by_char ' ' "$@")"
    } | crontab -
}

## Usage: _crontab_rm_script_entries_by_arg          # this removes all script entries
## Usage: _crontab_rm_script_entries_by_arg recheck  # this removes just entries with recheck argument
_crontab_rm_script_entries_by_arg()
{
    local current
    current=$(_crontab_read) || return
    # Compare literal command words, including anonymous UCI names containing
    # brackets. A nice prefix is permitted; comments and environment stay intact.
    { [ -z "$current" ] || printf '%s\n' "$current"; } |
    awk -v script="$SCRIPT" -v args="$*" -v count="$#" '
        BEGIN { split(args, wanted, " ") }
        {
            remove = 0
            if ($0 !~ /^[[:space:]]*(#|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=)/)
                for (i = 6; i <= NF; i++)
                    if ($i == script) {
                        matches = 1
                        for (j = 1; j <= count; j++)
                            if ($(i + j) != wanted[j]) matches = 0
                        if (matches) remove = 1
                    }
            if (!remove) print
        }' | crontab -
}

_crontab_add_from_cfg_entry()
{
    local entry="$1"
    local starttime stoptime daysofweek forcewifidown 
    starttime=$(    _uci_get_value "${PACKAGE}.${entry}.starttime" ) || return 1
    stoptime=$(     _uci_get_value "${PACKAGE}.${entry}.stoptime"  ) || return 1
    daysofweek=$(   _uci_get_value "${PACKAGE}.${entry}.daysofweek") || return 1
    forcewifidown=$(_uci_get_value "${PACKAGE}.${entry}.forcewifidown")
    
    local startminutes stopminutes fdow stopdow offset=0
    startminutes=$(schedule_time_minutes "$starttime") || return 1
    stopminutes=$(schedule_time_minutes "$stoptime") || return 1
    fdow=$(schedule_weekdays 0 $daysofweek) || return 1
    [ "$stopminutes" -ge "$startminutes" ] || offset=1
    stopdow=$(schedule_weekdays "$offset" $daysofweek) || return 1

    if [ "$startminutes" -ne "$stopminutes" ]; then
        _crontab_append_line "$((startminutes % 60)) $((startminutes / 60)) * * ${fdow} ${SCRIPT} start entry:${entry}" || return
    fi

    local stopmode="stop"
    if _uci_bool "${forcewifidown}" ; then
        stopmode="forcestop"
    fi

    _crontab_append_line "$((stopminutes % 60)) $((stopminutes / 60)) * * ${stopdow} ${SCRIPT} ${stopmode} entry:${entry}" || return

    return 0
}

_crontab_reset_from_cfg()
{
    local retries="" current
    if [ "$1" = preserve_rechecks ]; then
        # Explicit origins remain valid requests across an upgrade. The first
        # invocation revalidates named entries; unowned legacy retries are lost.
        current=$(_crontab_read) || return
        retries=$(printf '%s\n' "$current" | awk -v script="$SCRIPT" '
            $0 !~ /^[[:space:]]*(#|[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=)/ {
                if (NF >= 8 && $(NF - 2) == script && $(NF - 1) == "recheck" && ($NF == "manual" || $NF ~ /^entry:[^@]/))
                    print
            }')
    fi
    _crontab_rm_script_entries_by_arg || return
    if [ -n "$retries" ]; then
        _crontab_append_line "$retries" || return
    fi

    _cfg_global_is_enabled || return 0

    local entry
    for entry in $(_cfg_list_entries)
    do
        test -n "${entry}" || continue
        _cfg_entry_is_enabled "${entry}" || continue
        _crontab_add_from_cfg_entry "${entry}" || return
    done
}

# region: kernel module unload feature

get_module_list()
{
    local mod_list
    local _if
    for _if in $(_wifi_get_interfaces)
    do
        local mod mod_dep
        # trunk-ignore(shellcheck/SC2312)
        mod=$(basename "$(readlink -f "/sys/class/net/${_if}/device/driver")")
        mod_dep=$(modinfo "${mod}" | awk '$1 ~ /^depends:/ { print $2 }')
        mod_list=$(printf "%s\n%s,%s" "${mod_list}" "${mod}" "${mod_dep}" | sort -u)
    done
    # trunk-ignore(shellcheck/SC2250)
    echo "$mod_list" | tr ',' ' '
}

save_module_list_uci()
{
    local list
    list=$(get_module_list)
    uci set "${GLOBAL}.modules=${list}"
    uci commit "${PACKAGE}"
}

_unload_modules()
{
    local list retries
    list=$(_uci_get_value "${GLOBAL}.modules")
    retries=$(_uci_get_value "${GLOBAL}.modules_retries") || return 1
    _log "info" "unload_modules ${list} (retries: ${retries})"
    local i=0
    # trunk-ignore(shellcheck/SC2250)
    while _arith_bool $(( i < retries )) && test -n "$list"
    do
        : $(( i += 1 ))
        local mod
        local first=0
        for mod in ${list}
        do
            if [ "${first}" -eq 0 ]; then
                list=""
                first=1
            fi
            
            if ! rmmod "${mod}" >/dev/null 2>&1 ; then
                # trunk-ignore(shellcheck/SC2250)
                list="$list $mod"
            fi
        done
    done
}

_load_modules()
{
    local list retries
    list=$(   _uci_get_value "${GLOBAL}.modules") || return 1
    retries=$(_uci_get_value "${GLOBAL}.modules_retries") || return 1
    _log "info" "load_modules ${list} (retries: ${retries})"
    local i=0
    # trunk-ignore(shellcheck/SC2250)
    while _arith_bool $(( i < retries )) && test -n "$list"
    do
        : $(( i += 1 ))
        local mod
        local first=0
        for mod in ${list}
        do
            if [ "${first}" -eq 0 ]; then
                list=""
                first=1
            fi
            modprobe "${mod}" > /dev/null 2>&1
            rc=$?
            if [ "${rc}" -ne 255 ]; then
                # trunk-ignore(shellcheck/SC2250)
                list="$list $mod"
            fi
        done
    done
}

# endregion: kernel module unload feature

# Prints: `phy0-ap0$'\n'phy0-ap1$'\n'`
_wifi_get_interfaces() { iwinfo | awk '/[^[:alnum:]]ESSID[^[:alnum:]]/ { print $1 }' ;}

# Prints: `radio0$'\n'radio1$'\n'`
_wifi_get_devices() { uci show "wireless" | awk -F= '$2 == "wifi-device" { n = split($1, a, "."); print a[n] }' ;}

_wifi_rfkill_set_all_to()
{
    local status="$1"
    _arith_bool $(( status == 0 || status == 1 )) || return 1
    for radio in $(_wifi_get_devices)
    do
        uci set "wireless.${radio}.disabled=${status}" || return
    done
    uci commit wireless || return
    /sbin/wifi
}

_wifi_rfkill_unblock_all() { _wifi_rfkill_set_all_to 0 ;}
_wifi_rfkill_block_all()   { _wifi_rfkill_set_all_to 1 ;}

wifi_disable()
{
    _crontab_rm_script_entries_by_arg "recheck" || return
    _cron_update || return
    _wifi_rfkill_block_all || return
    if _cfg_global_is_unload_modules_enabled
    then
        _unload_modules
    fi
}

wifi_soft_disable()
{
    local origin="${1:-manual}"
    if ! command -v iwinfo >/dev/null 2>&1 ; then
        _log "info" "iwinfo not available, skipping"
        return 1
    fi

    local has_assoc=false
    local mac_filter='([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}'

    local ignore_stations ignore_stations_filter
    ignore_stations=$(_uci_get_value_raw "${GLOBAL}.ignore_stations")
    # shellcheck disable=SC2086
    ignore_stations_filter=$(_join_by_char "|" ${ignore_stations})

    # check if no stations are associated
    local _if
    for _if in $(_wifi_get_interfaces)
    do
        local stations ignored_stations
        stations=$(iwinfo "${_if}" assoclist | grep -o -E "${mac_filter}")
        if [ -n "${ignore_stations}" ]; then
            local all_stations="${stations}"
            # shellcheck disable=SC2086
            stations=$(printf "%s\n" ${stations} | grep -vwi -E "${ignore_stations_filter}")
            # shellcheck disable=SC2086
            ignored_stations="$(printf "%s\n" ${all_stations} ${stations} | sort | uniq -u)"
        fi

        test -n "${stations}" || continue

        has_assoc=true

        # shellcheck disable=SC2086
        _log "info" "Clients connected on '${_if}': $(_join_by_char ' ' ${stations})" || true
        if test -n "${ignored_stations}"
        then
        # shellcheck disable=SC2086
        _log "info" "Clients ignored on   '${_if}': $(_join_by_char ' ' ${ignored_stations})" || true
        fi
    done

    _crontab_rm_script_entries_by_arg "recheck" "$origin" || return

    if [ "${has_assoc}" = "false" ]
    then
        _log "notice" "No stations associated, disable wifi."
        wifi_disable || return
    else
        _log "notice" "Could not disable wifi due to associated stations, retrying..."
        local recheck_interval
        recheck_interval=$(_uci_get_value "${GLOBAL}.recheck_interval")
        if test -n "${recheck_interval}" && _arith_bool $(( recheck_interval > 0 )) ; then
            _crontab_append_line "*/${recheck_interval} * * * * /bin/nice -n 19 ${SCRIPT} recheck ${origin}" || return
        fi
    fi

    _cron_update
}

wifi_enable()
{
    _crontab_rm_script_entries_by_arg "recheck" || return
    _cron_update || return
    if _cfg_global_is_unload_modules_enabled
    then
        _load_modules
    fi
    _wifi_rfkill_unblock_all
}

wifi_startup()
{
    _cfg_global_is_enabled || return 0

    if _cfg_can_wifi_run_now
    then
        _log "notice" "enable wifi"
        wifi_enable
    else
        _log "notice" "disable wifi"
        wifi_disable
    fi
}

# Cron supplies an entry name; LuCI and standalone commands use manual control.
# An old cron verb never overrides current configuration or another allow window.
wifi_scheduled_action()
{
    local action="$1" origin="$2" entry force
    case "$origin" in
        entry:*) entry="${origin#entry:}" ;;
        *)
            # Queued pre-upgrade jobs lack an unambiguous entry identity.
            for action in start stop forcestop recheck; do
                _crontab_rm_script_entries_by_arg "$action" "$origin" || return
            done
            _cron_update
            return
            ;;
    esac
    if ! _cfg_global_is_enabled || ! _cfg_entry_is_enabled "$entry"; then
        _crontab_rm_script_entries_by_arg recheck "$origin" || return
        _cron_update
        return
    fi

    if _cfg_can_wifi_run_now; then
        if [ "$action" = start ]; then
            wifi_enable
        else
            _crontab_rm_script_entries_by_arg recheck "$origin" || return
            _cron_update
        fi
        return
    fi
    [ "$action" != start ] || return 0
    force=$(_uci_get_value "${PACKAGE}.${entry}.forcewifidown") || return 1
    if _uci_bool "$force"; then
        wifi_disable
    else
        wifi_soft_disable "$origin"
    fi
}

usage()
{
    echo "$0 cron|cron-only|start|startup|stop|forcestop|recheck|getmodules|savemodules|help"
    echo ""
    echo "    UCI Config File: /etc/config/${PACKAGE}"
    echo ""
    echo "    cron: Create cronjob entries."
    echo "    cron-only: Rebuild cron jobs without changing the current radio state."
    echo "    start: Start wifi."
    echo "    startup: Checks current timewindow and enables/disables WIFI accordingly."
    echo "    stop: Stop wifi gracefully, i.e. check if there are stations associated and if so keep retrying."
    echo "    forcestop: Stop wifi immediately."
    echo "    recheck: Recheck if wifi can be disabled now."
    echo "    getmodules: Returns a list of modules used by the wireless driver(s)"
    echo "    savemodules: Saves a list of automatic determined modules to UCI"
    echo "    help: This description."
    echo ""
}

# shellcheck disable=SC2317
_cleanup()
{
    lock -u "${LOCKFILE}"
}

###############################################################################
# MAIN
###############################################################################
main() {
    local status

    LOGGING=$(_uci_get_value "${GLOBAL}.logging") || _exit 1
    _log "info" "${SCRIPT}" "$@"
    lock "${LOCKFILE}" || _exit 1
    # Unlock exactly once, after acquisition. Keep the inode for queued owners.
    trap _cleanup EXIT
    trap '_exit 1' HUP INT TERM

    case "$1" in
        cron-only)
            _crontab_reset_from_cfg preserve_rechecks && _cron_update
            ;;
        cron)
            _crontab_reset_from_cfg && _cron_update && wifi_startup
            ;;
        start|stop|forcestop|recheck)
            if [ "$1" = recheck ] && [ -z "$2" ]; then
                # Old ownerless retries must not acquire manual authority.
                _crontab_rm_script_entries_by_arg recheck "" && _cron_update
            elif [ "${2:-manual}" != manual ]; then
                wifi_scheduled_action "$1" "$2"
            else
                case "$1" in
                    start) wifi_enable ;;
                    forcestop) wifi_disable ;;
                    stop|recheck) wifi_soft_disable manual ;;
                esac
            fi
            ;;
        startup) wifi_startup ;;
        getmodules) get_module_list ;;
        savemodules) save_module_list_uci ;;
        help|--help|-h|*) usage ;;
    esac

    status=$?
    _exit "$status"
}

main "${@}"
