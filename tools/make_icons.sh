#!/bin/sh
# Renders design/icon.svg into every icon the project ships (macOS only: it uses Quick Look,
# sips, iconutil and Python with Pillow):
#   macos/RDC.icns             the app icon
#   windows/rdc.ico            the icon of RDC.exe and its window
#   mcpb/icon.png              the MCP bundle for Claude Desktop (512 px)
#   plugins/rdc/assets/icon.png  the Claude Code and Codex plugins (512 px)
#   web/icon.png               the viewer's favicon and home-screen icon (192 px)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Render at 1024 px with a transparent background. Headless Chrome does that; Quick Look paints
# the corners white, so without Chrome the plate's rounded shape is cut out afterwards.
master="$work/icon.png"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ -x "$chrome" ]; then
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$master" "file://$root/design/icon.svg" >/dev/null 2>&1 || true
fi
if [ ! -f "$master" ]; then
  qlmanage -t -s 1024 -o "$work" "$root/design/icon.svg" >/dev/null 2>&1
  [ -f "$work/icon.svg.png" ] || { echo "make_icons: neither Chrome nor Quick Look rendered design/icon.svg" >&2; exit 1; }
  python3 - "$work/icon.svg.png" "$master" <<'EOF'
# Cut the plate (x 64..960, corner radius 204 — the same numbers as in icon.svg) out of the white.
import sys
from PIL import Image, ImageDraw
src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")
k = 4
mask = Image.new("L", (1024 * k, 1024 * k), 0)
ImageDraw.Draw(mask).rounded_rectangle((64 * k, 64 * k, 960 * k, 960 * k), radius=204 * k, fill=255)
im.putalpha(mask.resize((1024, 1024), Image.LANCZOS))
im.save(out)
EOF
fi

shrink() { # size out
  sips -z "$1" "$1" "$master" --out "$2" >/dev/null
}

mkdir -p "$root/mcpb" "$root/plugins/rdc/assets" "$root/web"
shrink 512 "$root/mcpb/icon.png"
cp "$root/mcpb/icon.png" "$root/plugins/rdc/assets/icon.png"
shrink 192 "$root/web/icon.png"

# macOS: an iconset with every size and its @2x, then iconutil.
set="$work/RDC.iconset"
mkdir -p "$set"
for s in 16 32 128 256 512; do
  shrink "$s" "$set/icon_${s}x${s}.png"
  shrink $((s * 2)) "$set/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$set" -o "$root/macos/RDC.icns"

# Windows: one .ico with the sizes Explorer and the title bar use (PNG-compressed entries).
python3 - "$master" "$root/windows/rdc.ico" <<'EOF'
import sys
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
Image.open(src).save(out, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
EOF

ls -la "$root/macos/RDC.icns" "$root/windows/rdc.ico" "$root/mcpb/icon.png" "$root/plugins/rdc/assets/icon.png" "$root/web/icon.png"
