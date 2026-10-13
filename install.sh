#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.local/bin"
TARGET="$TARGET_DIR/peek"

chmod +x "$SCRIPT_DIR/peeker.sh"
mkdir -p "$TARGET_DIR"
ln -sf "$SCRIPT_DIR/peeker.sh" "$TARGET"

# lets `peek update` find its way back here even if the ln -s above
# silently fell back to a plain copy (happens on windows w/o symlink privilege/dev Mode)
echo "$SCRIPT_DIR" > "$TARGET_DIR/.peek-repo"

echo "Installed: $TARGET -> $SCRIPT_DIR/peeker.sh"

case ":$PATH:" in
    *":$TARGET_DIR:"*)
        echo "Done. Run 'peek' from anywhere."
        ;;
    *)
        echo
        echo "$TARGET_DIR is not on your PATH yet. Add this to your ~/.bashrc or ~/.zshrc:"
        echo
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo
        echo "Then restart your shell (or 'source' that file) and run 'peek'."
        ;;
esac
