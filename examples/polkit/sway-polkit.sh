#!/usr/bin/env bash
# Requires swaymsg, jq and pkill. Start Keywisp with --signal-control first.
# Usage: bash examples/polkit/sway-polkit.sh [app_id_or_class_regex]
# IPC: https://github.com/swaywm/sway/blob/master/sway/sway-ipc.7.scd
set -euo pipefail

pattern=${1:-polkit|policykit}

# The initial tick triggers a query after the subscription is active.
swaymsg -m -r -t subscribe '["window", "workspace", "tick"]' |
    jq --unbuffered -r 'select(.first == true or .change != null) | true' |
    (
        previous=
        while IFS= read -r event; do
            paused=$(swaymsg -r -t get_tree | jq -r --arg pattern "$pattern" '
                any(recurse(.nodes[]?, .floating_nodes[]?);
                    .focused and
                    ((.app_id // .window_properties.class // "") | test($pattern; "i")))
            ')
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
