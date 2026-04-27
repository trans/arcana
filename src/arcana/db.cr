require "db"
require "pg"

module Arcana
  # Connection management for the Postgres-backed identity / org store.
  #
  # Configured via `ARCANA_DATABASE_URL`. Postgres is *opt-in* — when
  # the env var is unset, `Arcana::DB.connection` returns nil and
  # callers must handle that. This keeps current single-tenant
  # localhost users working without a database.
  #
  # Connection format:
  #   postgres://user:pass@host:port/dbname
  #
  # The underlying pool is provided by crystal-db (`crystal-pg` is the
  # Postgres driver shard). Default pool settings are fine for now;
  # tunables can be added later via env vars if needed.
  module DB
    @@db : ::DB::Database? = nil
    @@mutex = Mutex.new

    # Open the connection pool. Idempotent — repeated calls return the
    # same `DB::Database`. Returns nil if `ARCANA_DATABASE_URL` is unset.
    def self.connection : ::DB::Database?
      @@mutex.synchronize do
        return @@db if @@db
        url = ENV["ARCANA_DATABASE_URL"]?
        return nil if url.nil? || url.empty?
        @@db = ::DB.open(url)
      end
    end

    # Force the connection. Raises if `ARCANA_DATABASE_URL` is unset —
    # use this in code paths that require Postgres (admin CLI, auth
    # middleware), as opposed to opportunistic uses.
    def self.connection! : ::DB::Database
      connection || raise Error.new("ARCANA_DATABASE_URL is not set")
    end

    # Has Postgres been configured for this process?
    def self.enabled? : Bool
      url = ENV["ARCANA_DATABASE_URL"]?
      !(url.nil? || url.empty?)
    end

    # Close the pool. Mostly useful for tests and for graceful shutdown.
    def self.close
      @@mutex.synchronize do
        @@db.try &.close
        @@db = nil
      end
    end
  end
end
