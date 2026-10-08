#!/usr/bin/env bash
# Requires hyprctl, socat, jq and pkill. Start Keywisp with --signal-control first.
# Usage: bash examples/polkit/hyprland-polkit.sh [class_regex]
# IPC: https://wiki.hypr.land/IPC/
set -euo pipefail

pattern=${1:-polkit|policykit}
socket=${XDG_RUNTIME_DIR:?}/hypr/${HYPRLAND_INSTANCE_SIGNATURE:?}/.socket2.sock

sync_recording() {
    local paused signal status
    paused=$(hyprctl -j activewindow | jq -r --arg pattern "$pattern" '
        (.class // "") | test($pattern; "i")
    ')
    [[ $paused != "$previous" ]] || return 0
    if [[ $paused == true ]]; then
        signal=USR1
    else
        signal=USR2
    fi

    # Limit signals to this user's Keywisp instances.
    if pkill -"$signal" -u "$UID" -x keywisp; then
        previous=$paused
    else
        status=$?
        # No matching process is harmless; retry on the next event.
        [[ $status == 1 ]] || return "$status"
    fi
}

socat -U - "UNIX-CONNECT:$socket" |
    (
        previous=
        sync_recording
        while IFS= read -r event; do
            case ${event%%>>*} in
                activewindowv2|openwindow|closewindow|windowtitlev2|focusedmon|workspacev2|activespecial)
                    sync_recording
                    ;;
            esac
        done
    )
