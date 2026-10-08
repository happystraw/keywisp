#!/usr/bin/env bash
# Requires niri, jq and pkill. Start Keywisp with --signal-control first.
# Usage: bash examples/polkit/niri-polkit.sh [app_id_regex]
set -euo pipefail

pattern=${1:-polkit|policykit}

niri msg --json event-stream |
    jq --unbuffered -nr --arg pattern "$pattern" '
        foreach inputs as $event (
            {windows: null};
            if $event.WindowsChanged then
                .windows = $event.WindowsChanged.windows
            elif $event.WindowOpenedOrChanged then
                $event.WindowOpenedOrChanged.window as $window
                | if .windows != null then
                    .windows |= (
                        map(select(.id != $window.id)
                            | if $window.is_focused then .is_focused = false else . end)
                        + [$window]
                    )
                  else . end
            elif $event.WindowFocusChanged then
                $event.WindowFocusChanged.id as $id
                | if .windows != null then
                    .windows |= map(.is_focused = (.id == $id))
                  else . end
            elif $event.WindowClosed then
                if .windows != null then
                    .windows |= map(select(.id != $event.WindowClosed.id))
                else . end
            else . end;
            select(.windows != null)
            | any(.windows[];
                .is_focused and ((.app_id // "") | test($pattern; "i")))
        )
    ' |
    (
        previous=
        while IFS= read -r paused; do
            [[ $paused != "$previous" ]] || continue
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
                [[ $status == 1 ]] || exit "$status"
            fi
        done
    )
