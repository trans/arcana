module Arcana
  module DB
    # Tiny migration runner.
    #
    # Walks `db/migrations/*.sql` in lexicographic order, applies any
    # that haven't been recorded in the `schema_migrations` table, and
    # tracks them as applied. Each migration runs in a transaction.
    #
    # Filename convention: `<timestamp>_<description>.sql`, e.g.
    #   db/migrations/20260427_001_init_auth.sql
    #
    # The leading numeric prefix determines order. The full filename
    # is the unique key recorded in schema_migrations, so renames break
    # things — don't rename applied migrations.
    module Migrate
      # Record table that tracks which migrations have been applied.
      SCHEMA_TABLE_SQL = <<-SQL
        CREATE TABLE IF NOT EXISTS schema_migrations (
          filename     TEXT PRIMARY KEY,
          applied_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
      SQL

      # Apply any pending migrations from the given directory.
      # Returns the list of applied filenames (in order).
      def self.run(dir : String = default_dir) : Array(String)
        db = Arcana::DB.connection!
        applied = [] of String

        db.exec SCHEMA_TABLE_SQL

        already = Set(String).new
        db.query "SELECT filename FROM schema_migrations" do |rs|
          rs.each { already << rs.read(String) }
        end

        files = Dir.entries(dir).select(&.ends_with?(".sql")).sort

        files.each do |file|
          next if already.includes?(file)
          path = File.join(dir, file)
          sql = File.read(path)

          db.transaction do |tx|
            split_statements(sql).each do |stmt|
              tx.connection.exec stmt
            end
            tx.connection.exec "INSERT INTO schema_migrations (filename) VALUES ($1)", file
          end

          applied << file
        end

        applied
      end

      # crystal-pg's exec uses the extended-query protocol, which permits
      # only one statement per call. Migration files routinely have several
      # (a CREATE TABLE plus its indexes, etc.), so we split on `;` and run
      # each non-empty statement separately. SQL strings inside our
      # migrations don't contain `;`, and dollar-quoted blocks aren't used
      # — if either changes, this needs a real parser.
      private def self.split_statements(sql : String) : Array(String)
        sql.split(';').map(&.strip).reject(&.empty?)
      end

      # Default location for migration files. Prefer the install prefix
      # (`/usr/share/arcana/db/migrations`) so packaged runs work from any
      # CWD. Fall back to a CWD-relative path only when running inside a
      # source checkout (detected via shard.yml).
      def self.default_dir : String
        prefix = "/usr/share/arcana/db/migrations"
        return prefix if Dir.exists?(prefix)

        local = File.join(Dir.current, "db", "migrations")
        return local if File.exists?(File.join(Dir.current, "shard.yml")) && Dir.exists?(local)

        prefix # used in error messages
      end
    end
  end
end
