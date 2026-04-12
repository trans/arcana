# Arcana Deployment Guide

## Overview

Arcana runs as a system service under a dedicated `arcana` user. The service
listens on port 19118 (configurable) and persists state to disk on graceful
shutdown. Your personal user is added to the `arcana` group so you can deploy
updates, read state files, and edit the environment without root.

## Layout

```
/home/arcana/
  bin/arcana           # server binary
  .arcana/
    state.json         # snapshot: listings, mailbox messages, frozen, tokens
    directory.json     # legacy listing file (auto-migrated on first run)
  .env                 # API keys and env overrides (mode 640, group-readable)

/etc/systemd/system/
  arcana.service       # systemd unit file
```

## Prerequisites

- Crystal >= 1.19.1 (for building from source)
- systemd
- sudo access (for one-time install)

## Install

Build and run the install script:

```sh
cd ~/Projects/arcana
shards build
sudo contrib/systemd/install.sh
```

Or use the Justfile recipe (does both):

```sh
just install
```

The install script:

1. Creates the `arcana` system user with home `/home/arcana` and no login shell.
2. Adds your user to the `arcana` group for no-sudo file access.
3. Creates `/home/arcana/bin/` (setgid, group-writable) and `/home/arcana/.arcana/`.
4. Deploys the compiled binary.
5. Migrates existing state from `~/.arcana/` if present.
6. Creates a stub `.env` file with API key placeholders.
7. Installs the systemd unit and runs `daemon-reload`.

Everything is idempotent — safe to re-run.

## Configuration

### API keys

Edit `/home/arcana/.env` (group-writable, no sudo needed once you're in the
`arcana` group):

```sh
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GOOGLE_API_KEY=...
XAI_API_KEY=...
DEEPSEEK_API_KEY=...
RUNWARE_API_KEY=...
VOYAGE_API_KEY=...
ELEVENLABS_API_KEY=...
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `ARCANA_HOST` | `127.0.0.1` | Bind address |
| `ARCANA_PORT` | `19118` | Bind port |
| `ARCANA_STATE_DIR` | `/home/arcana/.arcana` | Directory for state files |

Set these in `/home/arcana/.env` to override.

## Start the service

```sh
# Stop any manually-running arcana first (to free port 19118)
sudo systemctl enable --now arcana.service
```

If you weren't already in the `arcana` group, activate it in your current shell:

```sh
newgrp arcana
```

Or log out and back in.

## Common operations

### Check status

```sh
systemctl status arcana
```

### View logs

```sh
journalctl -u arcana -f          # follow live
journalctl -u arcana --since today
```

### Stop / restart

```sh
sudo systemctl stop arcana       # saves snapshot, then stops
sudo systemctl restart arcana    # saves snapshot, restarts with fresh state load
```

`stop` sends SIGTERM, which triggers the snapshot save handler. The service
has 15 seconds to write state before systemd force-kills it.

### Deploy a new binary

After making changes and rebuilding:

```sh
just deploy                      # builds + copies binary (no sudo)
sudo systemctl restart arcana    # picks up the new binary
```

Or manually:

```sh
shards build
cp bin/arcana /home/arcana/bin/arcana
sudo systemctl restart arcana
```

No sudo needed for the copy because `/home/arcana/bin/` is group-writable.

### Fresh start (wipe state)

```sh
sudo systemctl stop arcana
rm /home/arcana/.arcana/state.json
sudo systemctl start arcana      # starts with no prior state
```

Or pass `--fresh` by overriding ExecStart temporarily:

```sh
sudo systemctl stop arcana
sudo systemd-run --unit=arcana-fresh --uid=arcana \
  /home/arcana/bin/arcana --fresh
```

## Persistence

State is saved to `/home/arcana/.arcana/state.json` on graceful shutdown
(SIGTERM or SIGINT). On startup, the snapshot is loaded and all directory
listings, pending mailbox messages, frozen messages, and auth tokens are
restored.

**What survives restart:** directory listings, pending messages, frozen
messages with frozen_by metadata, mailbox auth tokens.

**What does not survive restart:** pub/sub subscriptions (clients re-subscribe
on reconnect), active WebSocket connections, busy status, in-flight
expectations.

**Hard crash (kill -9, OOM, power loss):** loses everything since the last
clean shutdown. The snapshot is only written on graceful stop. This is a
conscious trade-off for simplicity.

## Security

The systemd unit includes hardening directives:

- `NoNewPrivileges` — no SUID/SGID escalation.
- `ProtectSystem=strict` — filesystem is read-only except for explicit paths.
- `ReadWritePaths=/home/arcana` — only the arcana home is writable.
- `ProtectHome=read-only` — other users' homes are invisible.
- `PrivateTmp`, `PrivateDevices` — isolated /tmp, no device access.

The `.env` file is mode 640 (owner + group read), so API keys are readable
by the `arcana` service and anyone in the `arcana` group, but not world-readable.

**Auth tokens** are per-address shared secrets chosen by agents at registration
time. They protect mailbox access but are not encrypted on disk. Do not expose
port 19118 beyond localhost without additional transport security.

## MCP bridge

The MCP bridge (`arcana-mcp`) runs as your user (spawned by Claude Code via
`.mcp.json`), not as the `arcana` service user. It connects to the service
over TCP on localhost:19118. No special configuration is needed — just ensure
the service is running before starting Claude Code.

## Uninstall

```sh
sudo systemctl disable --now arcana.service
sudo rm /etc/systemd/system/arcana.service
sudo systemctl daemon-reload
sudo userdel -r arcana           # removes user and /home/arcana
```
