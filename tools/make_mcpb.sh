#!/bin/sh
# Builds rdc-mcp.mcpb — the MCP bundle for Claude Desktop and Claude Code plugins: the
# manifest plus the rdc binaries for macOS (server/rdc) and Windows (server/rdc.exe).
#
#   tools/make_mcpb.sh <version> <out.mcpb> [--mac <rdc>] [--win <rdc.exe>]
#
# Locally: tools/make_mcpb.sh 0.3.0 zig-out/package/rdc-mcp.mcpb \
#            --mac zig-out/RDC.app/Contents/MacOS/rdc --win zig-out/package/RDC.exe
set -eu

version="$1"; out="$2"; shift 2
mac=""; win=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mac) mac="$2"; shift 2 ;;
    --win) win="$2"; shift 2 ;;
    *) echo "make_mcpb: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$mac$win" ] || { echo "make_mcpb: give --mac and/or --win" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/server"
sed "s/@VERSION@/$version/" "$root/mcpb/manifest.json" > "$work/manifest.json"
cp "$root/mcpb/icon.png" "$work/icon.png"
[ -z "$mac" ] || { cp "$mac" "$work/server/rdc"; chmod 755 "$work/server/rdc"; }
[ -z "$win" ] || cp "$win" "$work/server/rdc.exe"

case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
mkdir -p "$(dirname "$out")"
rm -f "$out"
if command -v zip >/dev/null 2>&1; then
  (cd "$work" && zip -qrX "$out" manifest.json icon.png server)
else
  python3 - "$work" "$out" <<'EOF'
import os, sys, zipfile
work, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, files in os.walk(work):
        for f in files:
            p = os.path.join(base, f)
            z.write(p, os.path.relpath(p, work))
EOF
fi
echo "make_mcpb: $out ($(wc -c < "$out" | tr -d ' ') bytes)"
