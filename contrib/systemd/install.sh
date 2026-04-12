#!/bin/bash
# arcana systemd install — one-shot setup for the system service.
#
# Creates the `arcana` system user, deploys the binary, installs the unit
# file, and adds your current user to the arcana group so you can read
# state files and deploy updates without sudo.
#
# Usage:
#   sudo contrib/systemd/install.sh [your-username]
#
# If username is omitted, uses $SUDO_USER (the user who invoked sudo).

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: must run as root (use sudo)" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ADMIN_USER="${1:-${SUDO_USER:-}}"

if [ -z "$ADMIN_USER" ]; then
  echo "Error: no admin user specified and SUDO_USER is empty" >&2
  echo "Usage: sudo $0 <your-username>" >&2
  exit 1
fi

if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  echo "Error: user '$ADMIN_USER' does not exist" >&2
  exit 1
fi

if [ ! -x "$REPO_DIR/bin/arcana" ]; then
  echo "Error: $REPO_DIR/bin/arcana not found. Run 'shards build' first." >&2
  exit 1
fi

echo "==> Installing Arcana as a system service"
echo "    Repo:       $REPO_DIR"
echo "    Admin user: $ADMIN_USER (will be added to arcana group)"
echo

# 1. Create the arcana system user (idempotent).
if id arcana >/dev/null 2>&1; then
  echo "==> arcana user already exists, skipping creation"
else
  echo "==> Creating system user 'arcana'"
  useradd --system --create-home --home-dir /home/arcana \
          --shell /usr/sbin/nologin arcana
fi

# 2. Add admin user to arcana group (idempotent).
if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx arcana; then
  echo "==> $ADMIN_USER already in arcana group"
else
  echo "==> Adding $ADMIN_USER to arcana group"
  usermod -aG arcana "$ADMIN_USER"
  echo "    NOTE: log out and back in (or run 'newgrp arcana') for group to take effect"
fi

# 3. Create directory layout owned by arcana, group-readable.
echo "==> Setting up /home/arcana layout"
install -d -o arcana -g arcana -m 750 /home/arcana
install -d -o arcana -g arcana -m 2775 /home/arcana/bin       # setgid: new files inherit arcana group
install -d -o arcana -g arcana -m 2775 /home/arcana/.arcana   # state dir, group-readable

# 4. Deploy the binary.
echo "==> Installing binary to /home/arcana/bin/arcana"
install -o arcana -g arcana -m 755 "$REPO_DIR/bin/arcana" /home/arcana/bin/arcana

# 5. Migrate existing state from admin user's ~/.arcana if present.
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
if [ -f "$ADMIN_HOME/.arcana/state.json" ] && [ ! -f /home/arcana/.arcana/state.json ]; then
  echo "==> Migrating snapshot from $ADMIN_HOME/.arcana/state.json"
  cp "$ADMIN_HOME/.arcana/state.json" /home/arcana/.arcana/state.json
  chown arcana:arcana /home/arcana/.arcana/state.json
fi
if [ -f "$ADMIN_HOME/.arcana/directory.json" ] && [ ! -f /home/arcana/.arcana/directory.json ]; then
  echo "==> Migrating directory from $ADMIN_HOME/.arcana/directory.json"
  cp "$ADMIN_HOME/.arcana/directory.json" /home/arcana/.arcana/directory.json
  chown arcana:arcana /home/arcana/.arcana/directory.json
fi

# 6. Create empty .env if missing (admin can populate with API keys).
if [ ! -f /home/arcana/.env ]; then
  echo "==> Creating empty /home/arcana/.env (mode 640, group-readable)"
  install -o arcana -g arcana -m 640 /dev/null /home/arcana/.env
  cat > /home/arcana/.env <<'EOF'
# Arcana environment
# API keys for chat/image/tts/embed providers go here.
# This file is readable by the arcana group.
#
# OPENAI_API_KEY=sk-...
# ANTHROPIC_API_KEY=sk-ant-...
# GOOGLE_API_KEY=...
# XAI_API_KEY=...
# DEEPSEEK_API_KEY=...
# RUNWARE_API_KEY=...
# VOYAGE_API_KEY=...
# ELEVENLABS_API_KEY=...
EOF
  chown arcana:arcana /home/arcana/.env
  chmod 640 /home/arcana/.env
fi

# 7. Install the unit file.
echo "==> Installing systemd unit"
install -m 644 "$REPO_DIR/contrib/systemd/arcana.service" /etc/systemd/system/arcana.service
systemctl daemon-reload

echo
echo "==> Setup complete!"
echo
echo "Next steps:"
echo "  1. Edit /home/arcana/.env to add your API keys"
echo "  2. Stop any running 'bin/arcana' on port 19118"
echo "  3. Enable and start the service:"
echo "       sudo systemctl enable --now arcana.service"
echo "  4. Check status:"
echo "       systemctl status arcana"
echo "       journalctl -u arcana -f"
echo "  5. If you weren't already in the arcana group, log out and back in"
echo "     (or run 'newgrp arcana' in your current shell)"
