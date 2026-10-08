# Pause on polkit windows

These scripts pause Keywisp while a matching authentication window is focused
and resume when focus leaves it. They send `SIGUSR1` / `SIGUSR2` to all Keywisp
instances owned by the current user.

| WM | Script | Matches | Dependencies |
| --- | --- | --- | --- |
| niri | [niri-polkit.sh](niri-polkit.sh) | `app_id` | `niri`, `jq`, `pkill` |
| Hyprland | [hyprland-polkit.sh](hyprland-polkit.sh) | `class` | `hyprctl`, `socat`, `jq`, `pkill` |
| Sway | [sway-polkit.sh](sway-polkit.sh) | `app_id` or XWayland `class` | `swaymsg`, `jq`, `pkill` |

## Usage

Start Keywisp with signal control enabled:

```sh
keywisp -c
```

From another terminal in the same desktop session, run the script for your WM
(paths below are relative to the repository root):

```sh
bash examples/polkit/niri-polkit.sh
# Or:
bash examples/polkit/hyprland-polkit.sh
bash examples/polkit/sway-polkit.sh
```

All targeted Keywisp instances must use `-c` / `--signal-control`; otherwise,
these signals normally terminate them.

## Matching

The default regex is `polkit|policykit`, matched without case sensitivity.
Pass a different regex as the first argument:

```sh
bash examples/polkit/niri-polkit.sh 'polkit|policykit|org\.example\.AuthAgent'
```

Use `niri msg --json windows`, `hyprctl -j clients`, or `swaymsg -r -t get_tree`
while the authentication window is open to check its identifier.
