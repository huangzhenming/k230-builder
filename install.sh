#!/bin/bash
# k230-builder installer
# Usage:
#   curl -fsSL https://www.kendryte.com/misc/install.sh | bash
#   curl -fsSL https://www.kendryte.com/misc/install.sh | bash -s -- --uninstall
#
# For GitHub users (no kendryte.com access):
#   curl -fsSL https://raw.githubusercontent.com/huangzhenming/k230-builder/main/install.sh | bash

set -e

# macOS sed requires backup extension, GNU sed doesn't
_sed_i() {
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i'' "$@"     # GNU
    else
        sed -i '.k230bak' "$@"  # macOS (BSD)
    fi
}

BIN_DIR="$HOME/.local/bin"
TARGET_FILE="$BIN_DIR/k230"
KENDRYTE_BASE="${KENDRYTE_INSTALL_URL:-https://www.kendryte.com/misc}"
SCRIPT_NAME="k230"

info()  { echo "[k230-install] $1"; }
warn()  { echo "[k230-install] ⚠️  $1"; }
error() { echo "[k230-install] ❌ $1" >&2; exit 1; }

get_latest_tag() {
    local tag
    tag=$(curl -fsSL \
        "https://api.github.com/repos/huangzhenming/k230-builder/releases/latest" \
        2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"v\?\([^"]*\)".*/\1/' | head -1)
    [ -n "$tag" ] && echo "$tag" || echo "main"
}

uninstall() {
    info "Removing $TARGET_FILE..."
    rm -f "$TARGET_FILE"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [ -f "$rc" ] && _sed_i '/# K230 SDK Builder Path/d;/^export PATH="\$HOME\/.local\/bin:\$PATH"$/d' "$rc"
    done
    rm -f "$HOME/.zshrc.k230bak" "$HOME/.bashrc.k230bak" "$HOME/.profile.k230bak" 2>/dev/null || true
    info "Uninstall complete."
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --uninstall) uninstall ;;
        --help|-h)
            echo "Usage:"
            echo "  curl -fsSL $KENDRYTE_BASE/install.sh | bash"
            echo "  curl -fsSL $KENDRYTE_BASE/install.sh | bash -s -- --uninstall"
            exit 0
            ;;
    esac
done

info "Installing k230-builder..."

if ! command -v docker > /dev/null 2>&1; then
    warn "Docker not found — install it before running k230."
    echo "  Ubuntu/Debian: sudo apt install docker.io"
    echo "  Guide: https://docs.docker.com/engine/install/"
    echo ""
fi

TAG=$(get_latest_tag)
KENDRYTE_URL="${KENDRYTE_BASE}/${SCRIPT_NAME}"
GITHUB_URL="https://raw.githubusercontent.com/huangzhenming/k230-builder/${TAG}/k230"
info "Latest version: $TAG"

mkdir -p "$BIN_DIR"

info "Downloading from kendryte.com..."
if curl -fsSL --connect-timeout 10 "${KENDRYTE_URL}" -o "$TARGET_FILE" 2>/dev/null; then
    info "Downloaded from kendryte.com"
elif curl -fsSL --connect-timeout 10 "$GITHUB_URL" -o "$TARGET_FILE" 2>/dev/null; then
    info "Downloaded from GitHub ($TAG)"
else
    error "Failed to download from all sources.\n  Tried: $KENDRYTE_URL\n  Tried: $GITHUB_URL"
fi
chmod +x "$TARGET_FILE"
SHELL_RC=""
case "${SHELL:-}" in
    */zsh)  SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    *)      SHELL_RC="$HOME/.profile" ;;
esac

if [ -n "$SHELL_RC" ] && [ -f "$SHELL_RC" ]; then
    if ! grep -q "K230 SDK Builder Path" "$SHELL_RC" 2>/dev/null; then
        cat >> "$SHELL_RC" <<'EOF'

# K230 SDK Builder Path
export PATH="$HOME/.local/bin:$PATH"
EOF
        info "Added PATH to $SHELL_RC — run: source $SHELL_RC"
    else
        info "$BIN_DIR is already in your PATH."
    fi
fi

echo ""
info "✅ Installed to $TARGET_FILE ($TAG)"
info "Run 'source ${SHELL_RC:-~/.bashrc}' then 'k230 help'"
