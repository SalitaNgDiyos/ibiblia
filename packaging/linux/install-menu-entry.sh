#!/bin/sh
# Adds The Bible Maker to your applications menu (for your user only).
# Run it again if you move this folder.
HERE=$(cd "$(dirname "$0")" && pwd)
BIN="$HERE/TheBibleMaker"
if [ ! -x "$BIN" ]; then
  BIN="$HERE/iBiblia"
fi
ICON="$HERE/TheBibleMaker.png"
if [ ! -f "$ICON" ]; then
  ICON="$HERE/iBiblia.png"
fi
mkdir -p "$HOME/.local/share/applications"
rm -f "$HOME/.local/share/applications/ibiblia.desktop"
cat > "$HOME/.local/share/applications/thebiblemaker.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=The Bible Maker
Comment=Bible translation, alignment, and publishing workstation
Exec="$BIN" %f
Icon=$ICON
Terminal=false
Categories=Education;Office;
MimeType=application/x-ibiblia-project;
EOF
chmod +x "$HOME/.local/share/applications/thebiblemaker.desktop"
echo "The Bible Maker was added to your applications menu."
