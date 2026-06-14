# ghostty-cursor-gravity

A custom shader for Ghostty / Zonvie that warps surrounding text around your cursor, simulating gravitational lensing. When the cursor jumps, a quadrupole gravitational wave ring radiates outward.

[Watch demo video](https://x.com/akiyosi_x/status/2065085789143453986/video/1)

## Setup

### Ghostty

Add to `~/.config/ghostty/config`:

```
custom-shader = /path/to/zonvie-cursor-gravity/cursor_gravity.glsl
custom-shader-animation = true
```

Use an absolute path. Reload with `Cmd + Shift + ,`.

### Zonvie

Add the shader to `[shaders].paths` in `config.toml`. Zonvie supplies the necessary cursor uniforms, so the shader works on both platforms without modification.

## Tuning

Adjust constants at the top of `cursor_gravity.glsl`:

| Constant | Default | Effect |
|---|---|---|
| `REST_MASS` | 0.032 | Lens strength. Displacement scales as θ_E² |
| `LENS_REACH` | 0.55 | How far the distortion reaches |
| `CORE_SIZE` | 0.45 | Tightness of the central distortion |
| `C_LIGHT` | 1.4 | Field propagation speed (screen heights/sec) |
| `TRANSIT` | 0.070 | Jump transition time (seconds) |
| `WAVE_AMP` | 0.0035 | Gravitational wave amplitude |

For details, see the comments in the shader file.

## Files

- `cursor_gravity.glsl` — the shader itself (a single self-contained file)

## Inspiration

This work was inspired by [ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole), which pioneered physics-based cursor visualization in terminal shaders.
