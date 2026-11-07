#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.plosson.apple-notes-api"
LABEL_MB="com.plosson.apple-notes-api.menubar"
AGENTS_DIR="$HOME/Library/LaunchAgents"
ENV_FILE="$REPO_DIR/.env"
PLACEHOLDER="change-me-to-a-long-random-secret"

die() { echo "Error: $1" >&2; exit 1; }

# Prerequisites
for cmd in node openssl; do
  command -v "$cmd" &>/dev/null || die "$cmd not found in PATH"
done

# npm install if node_modules is missing
if [[ ! -d "$REPO_DIR/node_modules" ]]; then
  echo "Running npm install..."
  (cd "$REPO_DIR" && npm install --silent)
fi

# API key — generate if missing or still placeholder
if [[ ! -f "$ENV_FILE" ]] || grep -q "^NOTES_API_KEY=$PLACEHOLDER" "$ENV_FILE"; then
  API_KEY="$(openssl rand -hex 32)"
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  sed -i '' "s|$PLACEHOLDER|$API_KEY|" "$ENV_FILE"
  echo "Generated new API key."
else
  API_KEY="$(grep '^NOTES_API_KEY=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]')"
fi

PORT="$(grep '^NOTES_API_PORT=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
PORT="${PORT:-8787}"

# Keep the UI preference in .env so reinstalling preserves headless operation.
MENUBAR="$(grep '^NOTES_API_MENUBAR=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]' || true)"
MENUBAR="${MENUBAR:-true}"
case "$MENUBAR" in
  true|false) ;;
  *) die "NOTES_API_MENUBAR must be true or false" ;;
esac
TIMEOUT="$(grep '^NOTES_API_OSASCRIPT_TIMEOUT_MS=' "$ENV_FILE" | cut -d= -f2 | tr -d '[:space:]' || true)"
TIMEOUT="${TIMEOUT:-30000}"

if [[ "$MENUBAR" == true ]]; then
  command -v python3 &>/dev/null || die "python3 not found in PATH"
  VENV_DIR="$REPO_DIR/.venv-menubar"
  if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating Python venv for menu bar app..."
    python3 -m venv "$VENV_DIR"
  fi
  if ! "$VENV_DIR/bin/pip" show rumps &>/dev/null; then
    echo "Installing rumps..."
    "$VENV_DIR/bin/pip" install --quiet rumps
  fi
  PYTHON3_BIN="$VENV_DIR/bin/python3"
fi

NODE_BIN="$(command -v node)"

# Unload existing agents before overwriting plists
launchctl unload "$AGENTS_DIR/$LABEL.plist" 2>/dev/null || true
launchctl unload "$AGENTS_DIR/$LABEL_MB.plist" 2>/dev/null || true

mkdir -p "$AGENTS_DIR"

# Render plists to temp files, then move atomically
TMP_SERVER="$(mktemp)"

sed \
  -e "s|__REPO_DIR__|$REPO_DIR|g" \
  -e "s|__NODE_BIN__|$NODE_BIN|g" \
  -e "s|__NOTES_API_KEY__|$API_KEY|g" \
  -e "s|__NOTES_API_PORT__|$PORT|g" \
  -e "s|__NOTES_API_OSASCRIPT_TIMEOUT_MS__|$TIMEOUT|g" \
  -e "s|__USER__|$(whoami)|g" \
  "$REPO_DIR/launchd/$LABEL.plist.example" \
  > "$TMP_SERVER"

mv "$TMP_SERVER" "$AGENTS_DIR/$LABEL.plist"
chmod 600 "$AGENTS_DIR/$LABEL.plist"
launchctl load "$AGENTS_DIR/$LABEL.plist"

if [[ "$MENUBAR" == true ]]; then
  TMP_MB="$(mktemp)"
  sed \
    -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__PYTHON3_BIN__|$PYTHON3_BIN|g" \
    -e "s|__NOTES_API_PORT__|$PORT|g" \
    -e "s|__USER__|$(whoami)|g" \
    "$REPO_DIR/launchd/$LABEL_MB.plist.example" > "$TMP_MB"
  mv "$TMP_MB" "$AGENTS_DIR/$LABEL_MB.plist"
  launchctl load "$AGENTS_DIR/$LABEL_MB.plist"
else
  # Remove the old login agent as well as stopping the running helper.
  rm -f "$AGENTS_DIR/$LABEL_MB.plist"
  echo "Menu bar helper disabled (no menu bar or Dock icon)."
fi

echo ""
echo "apple-notes-api installed and running on port $PORT"
echo ""
echo "Your API key (copy this to your agents):"
echo ""
echo "  $API_KEY"
echo ""
echo "Optional: to return which checklist items are ticked, give Full Disk Access to"
echo ""
echo "  $(realpath "$NODE_BIN" 2>/dev/null || echo "$NODE_BIN")"
echo ""
echo "in System Settings > Privacy & Security > Full Disk Access, then restart the server."
echo ""
