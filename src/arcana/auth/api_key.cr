require "digest/sha256"

module Arcana
  module Auth
    # An API key. The full secret is shown exactly once (at creation
    # time) and never stored — only its SHA-256 hash and a public
    # prefix are persisted.
    #
    # Format: `ak_<32 random base36-ish chars>`
    #   prefix = first 11 characters (e.g. "ak_a1b2c3d4")
    #   hash   = SHA-256 of the full string
    #
    # `org_id` is nullable to allow a system-wide platform admin key.
    # All other keys are scoped to exactly one org.
    struct ApiKey
      PREFIX_LEN = 11

      property id : Int64
      property org_id : Int64?
      property prefix : String
      property hash : String
      property name : String
      property scope : String
      property created_at : Time
      property last_used_at : Time?
      property revoked_at : Time?

      def initialize(@id, @org_id, @prefix, @hash, @name, @scope,
                     @created_at, @last_used_at, @revoked_at)
      end

      # Create a new API key. Returns a tuple of {ApiKey, plaintext_secret}
      # — the plaintext is only available here, exactly once.
      def self.create(
        name : String,
        org_id : Int64? = nil,
        scope : String = "full",
      ) : {ApiKey, String}
        secret = generate_secret
        prefix = secret[0, PREFIX_LEN]
        hash = Auth.hash_secret(secret)

        db = Arcana::DB.connection!
        row = db.query_one(
          "INSERT INTO api_keys (org_id, prefix, hash, name, scope) " \
          "VALUES ($1, $2, $3, $4, $5) " \
          "RETURNING id, org_id, prefix, hash, name, scope, created_at, last_used_at, revoked_at",
          org_id, prefix, hash, name, scope,
          as: {Int64, Int64?, String, String, String, String, Time, Time?, Time?},
        )
        {new(*row), secret}
      end

      # Look up an active key by its prefix (the publicly visible part).
      def self.find_by_prefix(prefix : String) : ApiKey?
        row = Arcana::DB.connection!.query_one?(
          "SELECT id, org_id, prefix, hash, name, scope, created_at, last_used_at, revoked_at " \
          "FROM api_keys WHERE prefix = $1 AND revoked_at IS NULL",
          prefix,
          as: {Int64, Int64?, String, String, String, String, Time, Time?, Time?},
        )
        row ? new(*row) : nil
      end

      # Verify a presented secret. Returns the matching ApiKey or nil.
      # Does constant-time comparison of the hash.
      def self.verify(secret : String) : ApiKey?
        return nil if secret.size < PREFIX_LEN
        prefix = secret[0, PREFIX_LEN]
        key = find_by_prefix(prefix)
        return nil unless key
        return nil unless secure_eq(key.hash, Auth.hash_secret(secret))
        key
      end

      def self.list_for_org(org_id : Int64) : Array(ApiKey)
        result = [] of ApiKey
        Arcana::DB.connection!.query(
          "SELECT id, org_id, prefix, hash, name, scope, created_at, last_used_at, revoked_at " \
          "FROM api_keys WHERE org_id = $1 ORDER BY id",
          org_id,
        ) do |rs|
          rs.each do
            result << new(
              rs.read(Int64), rs.read(Int64?), rs.read(String),
              rs.read(String), rs.read(String), rs.read(String),
              rs.read(Time), rs.read(Time?), rs.read(Time?),
            )
          end
        end
        result
      end

      # Mark this key as used (updates last_used_at).
      def touch_used
        Arcana::DB.connection!.exec(
          "UPDATE api_keys SET last_used_at = NOW() WHERE id = $1", @id
        )
      end

      # Mark this key as revoked. Idempotent.
      def revoke
        Arcana::DB.connection!.exec(
          "UPDATE api_keys SET revoked_at = NOW() WHERE id = $1 AND revoked_at IS NULL",
          @id
        )
      end

      def revoked? : Bool
        !@revoked_at.nil?
      end

      # 32 chars of base-36 entropy after the "ak_" prefix.
      private def self.generate_secret : String
        chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        body = String.build(32) do |io|
          32.times { io << chars[Random::Secure.rand(chars.size)] }
        end
        "ak_#{body}"
      end

      # Constant-time string comparison.
      private def self.secure_eq(a : String, b : String) : Bool
        return false unless a.bytesize == b.bytesize
        result = 0_u8
        a.bytesize.times { |i| result |= a.byte_at(i) ^ b.byte_at(i) }
        result == 0_u8
      end
    end
  end
end
