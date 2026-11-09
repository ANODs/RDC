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

qlmanage -t -s 1024 -o "$work" "$root/design/icon.svg" >/dev/null 2>&1
master="$work/icon.svg.png"
[ -f "$master" ] || { echo "make_icons: Quick Look did not render design/icon.svg" >&2; exit 1; }

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
