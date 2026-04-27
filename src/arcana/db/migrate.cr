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
            tx.connection.exec sql
            tx.connection.exec "INSERT INTO schema_migrations (filename) VALUES ($1)", file
          end

          applied << file
        end

        applied
      end

      # Default location: relative to the executable's project root.
      # Tests and the admin CLI can override.
      def self.default_dir : String
        # Look in CWD first (dev), then in install prefix (packaged).
        candidates = [
          File.join(Dir.current, "db", "migrations"),
          "/usr/share/arcana/db/migrations",
        ]
        candidates.each do |c|
          return c if Dir.exists?(c)
        end
        candidates.first # used in error messages
      end
    end
  end
end
