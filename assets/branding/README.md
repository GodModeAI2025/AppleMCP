# LocalMCP app icon

`localmcp-icon.png` is the full-resolution raster master, created for LocalMCP with
OpenAI image generation on 12 September 2026. It uses an indigo tile and a bright
connection symbol with a cyan endpoint. Transparent padding preserves the rounded
silhouette in Finder and the Dock.

Run `script/build_app_icon.sh` on macOS to create the checked-in `AppIcon.icns`.
The icon contains 16, 32, 128, 256 and 512 point representations at 1× and 2×.
All three app assembly scripts include it. The release artifact check verifies
that the icon and its `CFBundleIconFile` metadata match the source.

These assets are distributed under the repository's Apache-2.0 license.
