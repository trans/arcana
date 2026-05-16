# Arcana Auth — Operator Recipe

End-to-end walkthrough for enabling bearer-token auth on an Arcana server.
Assumes you're on the packaged install (`/etc/arcana/arcana.env`,
systemd unit `arcana.service`). For non-packaged setups, substitute your
own env-file and process supervisor.

Prerequisites:
- arcana >= 0.19.0
- Postgres installed locally (or reachable)

---

## 1. Initialize Postgres (once)

Easiest path: run the interactive helper.

```sh
sudo arcana-init-db
```

This does the following, idempotently:
- Starts the Postgres cluster (initializes the data dir if empty).
- Creates the `arcana` database and role with a generated password.
- Writes `ARCANA_DATABASE_URL=...` into `/etc/arcana/arcana.env`.
- Runs `arcana-admin migrate` to create the auth tables.
- Optionally creates a platform admin key.

Re-runs are safe — existing pieces are detected and skipped.

If you'd rather do it manually:

```sh
sudo -u postgres createuser arcana --pwprompt
sudo -u postgres createdb arcana --owner=arcana
echo 'ARCANA_DATABASE_URL=postgres://arcana:PASSWORD@localhost/arcana' \
  | sudo tee -a /etc/arcana/arcana.env
sudo arcana-admin migrate
```

---

## 2. Create an org (optional but recommended)

Keys can be scoped to an org or left unscoped (platform admin). For
anything beyond break-glass, prefer scoped keys.

```sh
sudo arcana-admin org create acme "Acme Corp"
sudo arcana-admin user create alice@acme.example --name "Alice"
sudo arcana-admin member add alice@acme.example acme owner
```

The org's `slug` (here `acme`) is what you pass to `--org` when minting
keys.

---

## 3. Mint an API key

```sh
sudo arcana-admin key create "Alice's CLI" --org acme
```

Output:

```
Created API key:
  id     = 1
  org    = acme
  prefix = ak_a1b2c3d4
  scope  = full

  SECRET (shown once, store this somewhere safe):
    ak_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8
```

**The secret is shown exactly once.** Only the prefix and a SHA-256
hash are stored. If you lose it, revoke and create a new one.

For a platform admin key (no org binding, full access):

```sh
sudo arcana-admin key create "Platform admin"
```

---

## 4. Turn enforcement on

Edit the systemd drop-in:

```sh
sudo systemctl edit arcana
```

Add:

```ini
[Service]
Environment=ARCANA_AUTH_REQUIRED=1
```

Restart:

```sh
sudo systemctl restart arcana
```

Look for this line in `journalctl -u arcana`:

```
  Auth:      ENFORCED (bearer token)
```

If you see `FATAL: ARCANA_AUTH_REQUIRED=1 requires ARCANA_DATABASE_URL to be set`,
step 1 didn't write the URL into `/etc/arcana/arcana.env`. Check that file.

---

## 5. Test it

Without a token — expect 401:

```sh
curl -i http://127.0.0.1:19118/directory
# HTTP/1.1 401 Unauthorized
# WWW-Authenticate: Bearer
# {"error":"unauthorized"}
```

With a token — expect 200:

```sh
curl -H "Authorization: Bearer ak_a1b2c3d4..." \
  http://127.0.0.1:19118/directory
```

`/health` stays open without a token (for liveness probes /
monitoring):

```sh
curl http://127.0.0.1:19118/health
# {"status":"ok",...}
```

---

## 6. Configure clients

### MCP bridge (Claude Code, etc.)

Set `ARCANA_API_KEY` in your MCP server config's environment:

```json
{
  "arcana": {
    "command": "arcana-mcp",
    "env": {
      "ARCANA_API_KEY": "ak_a1b2c3d4..."
    }
  }
}
```

`arcana-mcp` forwards it as `Authorization: Bearer` on every call.

### WebSocket clients (arcana-core `Client`)

WebSocket clients need to send `Authorization: Bearer ak_...` as a
header on the upgrade request. As of arcana 0.19.0, server-side
enforcement is in place; client-side support in `arcana-core` lands
when those clients need it.

For now, if you have a WebSocket client that can't send custom
headers on upgrade, keep auth disabled, or use the REST endpoints
(which support headers normally).

---

## Common operations

List active and revoked keys for an org:

```sh
sudo arcana-admin key list --org acme
```

Revoke a key by prefix:

```sh
sudo arcana-admin key revoke ak_a1b2c3d4
```

Revocation is immediate — the next request with that key returns 401.

### Rotation

There's no in-place rotation today. The pattern is:
1. Mint a new key (`key create`).
2. Update the client(s) to use the new secret.
3. Revoke the old key (`key revoke <prefix>`).

---

## Troubleshooting

**`FATAL: ARCANA_AUTH_REQUIRED=1 requires ARCANA_DATABASE_URL to be set`**
The env file doesn't have `ARCANA_DATABASE_URL`. Run `sudo arcana-init-db`
or add the URL by hand to `/etc/arcana/arcana.env`.

**`{"error":"unauthorized"}` with what looks like a valid key**
- Check the key isn't revoked: `arcana-admin key list --org <slug>` and
  look at `revoked_at`.
- Check the prefix matches: the first 11 chars of your secret should
  match a row in the table.
- Check the header is `Authorization: Bearer ak_...` exactly (case
  matters for "Bearer"; no quoting around the secret).

**Auth failures aren't showing in events**
They're recorded as `type=auth.failed` with
`metadata.transport=rest|websocket`. Query:

```sh
curl -H "Authorization: Bearer ak_..." \
  'http://127.0.0.1:19118/events?type=auth.failed&limit=20'
```

(You'll need a valid key to query — chicken-and-egg if you've locked
yourself out. Use the platform admin key for that.)

**Server starts but every request 401s with what should be a valid key**
Verify the server can actually reach Postgres:

```sh
sudo -u arcana psql "$(grep ^ARCANA_DATABASE_URL /etc/arcana/arcana.env | cut -d= -f2-)" -c '\dt'
```

If that fails, the server can't verify keys against the api_keys table.

---

## What's not in this release

- **Per-org isolation** — every authenticated caller currently sees the
  same shared bus / directory. Multi-tenant isolation (org A can't see
  org B's agents) is stage 3.
- **Scoped permissions** — the `scope` column on `api_keys` is
  recorded but not yet enforced. Every valid key has full access.
- **Key rotation as a single command** — currently a three-step
  process (create new, switch clients, revoke old).
- **Rate limits / quotas** — none, anywhere. Bring your own front-door
  if you need them.
