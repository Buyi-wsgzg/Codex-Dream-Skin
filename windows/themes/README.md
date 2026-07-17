# Windows theme packs

Each subdirectory is a self-contained theme pack. The current Windows runtime keeps the upstream managed theme store, CDP identity checks, pause support, and hot reload behavior, then layers the selected pack's optional CSS and copy over the shared adaptive base.

## Included themes

- `arina` — 桥本有菜 · 玫瑰粉, using the rose/cream layout modeled after `docs/images/gallery/skin-01.jpg`.
- `fiona` — 薛凯琪 · 梦幻紫, preserving the original purple Fiona layout and crop.

Switch interactively or by id:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-theme.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-theme.ps1 -Theme arina
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\switch-theme.ps1 -Theme fiona
```

Install also creates `Codex Dream Skin - Switch Theme` on the desktop and Start menu. When the injector watcher is running, switching updates the current Codex window without restarting it. Otherwise the selected theme becomes active on the next Dream Skin launch.

## Add a theme

Copy an existing directory and keep every referenced asset inside it:

```text
themes/my-theme/
  theme.json
  theme.css
  theme.png
```

Minimal manifest shape:

```json
{
  "schemaVersion": 1,
  "id": "my-theme",
  "name": "My Theme",
  "version": "1.0.0",
  "image": "theme.png",
  "css": "theme.css",
  "appearance": "light",
  "layout": "classic",
  "art": {
    "focusX": 0.72,
    "focusY": 0.45,
    "safeArea": "left",
    "taskMode": "off"
  },
  "palette": {
    "accent": "#C96F82"
  },
  "desktopSettings": {
    "appearanceLightCodeThemeId": "\"codex\"",
    "appearanceLightChromeTheme": "{ accent = \"#C96F82\", contrast = 64, ink = \"#4B252D\", opaqueWindows = true, surface = \"#FFF8F6\" }"
  },
  "copy": {
    "brandIcon": "✦",
    "brandTitle": "My Codex Theme",
    "brandSubtitle": "Codex Dream Skin",
    "signature": "Make something wonderful",
    "tagline": "A short home-screen subtitle",
    "polaroidCaption": "A short caption"
  }
}
```

Requirements:

- `id` uses 1–80 ASCII letters, digits, `.`, `_`, or `-` and starts with a letter or digit.
- Image assets must be PNG, JPEG, or WebP, no larger than 16 MiB, 16384 px on either side, or 50 MP total.
- Optional CSS must be strict UTF-8, use a relative `.css` path, remain inside the pack, and be no larger than 512 KiB.
- `layout: "classic"` enables the decorative brand, signature, ribbon, polaroid, and per-theme complete CSS layout. `layout: "adaptive"` uses the shared upstream image-responsive layout.
- `desktopSettings` may change only the allowlisted light code theme and light chrome theme. It never forces the user's `appearanceTheme`.
- Use `var(--dream-art)`, `var(--dream-tagline)`, and `var(--dream-polaroid-caption)` from theme CSS.
- Runtime images must be UI-free backgrounds. Files under `docs/images/gallery/` are preview composites, not importable backgrounds.
