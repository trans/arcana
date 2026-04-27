-- Initial identity / org schema for arcana 0.18.0.
--
-- Foundation for SaaS-style auth. All tables here are append-mostly;
-- soft-deletes (revoked_at, etc.) are preferred over destructive deletes
-- so audit history stays intact.

CREATE TABLE orgs (
  id          BIGSERIAL PRIMARY KEY,
  slug        TEXT NOT NULL UNIQUE CHECK (slug ~ '^[a-z][a-z0-9-]*$'),
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  -- Reserved for "system" / platform org (id = 1 by convention; admin keys live there).
  is_system   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE users (
  id            BIGSERIAL PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  name          TEXT,
  -- Password auth not yet implemented; column reserved for v2.
  password_hash TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE memberships (
  id          BIGSERIAL PRIMARY KEY,
  user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  org_id      BIGINT NOT NULL REFERENCES orgs(id)  ON DELETE CASCADE,
  role        TEXT   NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (user_id, org_id)
);

CREATE TABLE api_keys (
  id           BIGSERIAL PRIMARY KEY,
  -- org_id NULL only for the platform admin key (org-less, system-wide).
  org_id       BIGINT REFERENCES orgs(id) ON DELETE CASCADE,
  -- Public prefix, displayed in UIs/logs. e.g. "ak_abc123".
  prefix       TEXT NOT NULL UNIQUE,
  -- SHA-256 of the full secret. Full secret is never stored.
  hash         TEXT NOT NULL,
  -- Human-readable label.
  name         TEXT NOT NULL,
  -- Optional hint about scope. v1 = "full" (everything within the org).
  scope        TEXT NOT NULL DEFAULT 'full',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at TIMESTAMPTZ,
  revoked_at   TIMESTAMPTZ
);

CREATE INDEX api_keys_org_id_idx ON api_keys (org_id);
CREATE INDEX api_keys_prefix_active_idx ON api_keys (prefix) WHERE revoked_at IS NULL;
