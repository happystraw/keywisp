# Keywisp

A small Wayland keystroke visualizer.

<https://github.com/user-attachments/assets/32ab35d2-0721-4a75-8d24-0e5caefdb480>

## Dependencies

- Zig 0.16.0
- a Wayland compositor with `wlr-layer-shell-unstable-v1`.

System dependencies:

- cairo
- libinput
- pango
- udev
- wayland
- xkbcommon

Build-only dependency:

- `wayland-protocols` — needed to generate the `xdg-shell` protocol bindings at build time, not required at runtime.

## Install

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

This installs Keywisp as `~/.local/bin/keywisp`. Make sure `~/.local/bin` is in
your `PATH`.

## Input permissions

Keywisp needs read access to the input devices on `seat0`. On systems using an
`input` group, add your user to it and then log out and back in:

```sh
sudo usermod -aG input "$USER"
```

## Usage

Start the overlay with:

```sh
keywisp
```

Pointer buttons and scroll events are optional. Enable them with `-B` and `-S`:

```sh
keywisp -B -S
```

Keywisp includes four themes:

| Theme        | Appearance                                    |
| ------------ | --------------------------------------------- |
| `dark`       | Dark panel (default)                          |
| `light`      | Light panel                                   |
| `wisp-dark`  | Transparent panel with dark floating keycaps  |
| `wisp-light` | Transparent panel with light floating keycaps |

Select a theme with, for example:

```sh
keywisp --theme wisp-dark
```

Command-line options can override theme colors and adjust the position, font,
spacing, and other appearance settings.

Example:

```sh
keywisp --theme wisp-dark \
  --position top \
  --margin 32 \
  --max-width 720 \
  --font "Sans Bold 18" \
  --text-color FFFFFFFF
```

Run the following command for all available options:

```sh
keywisp --help
```

### Waybar integration

Keywisp can run in `--stdout` mode and be used as a Waybar `custom` module.
Each keystroke line is printed to stdout and picked up by the bar. An example
configuration is provided in [`examples/waybar-config.jsonc`](examples/waybar-config.jsonc):

![waybar.png](https://github.com/user-attachments/assets/f60e2ef8-37d6-4bb1-8d0e-f557423d1576)

```jsonc
"custom/keywisp": {
  "exec": "keywisp --stdout --stdout-history 5 --stdout-emit-clear -t 2000",
  "format": "󰌌  {}",
  "hide-empty-text": true,
  "restart-interval": 3,
  "tooltip": false
}
```

## Acknowledgments

Keywisp was inspired by [DreamMaoMao/wshowkeys](https://github.com/DreamMaoMao/wshowkeys).

## License

Keywisp is available under the [MIT License](LICENSE).
