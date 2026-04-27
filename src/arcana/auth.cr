require "./auth/org"
require "./auth/user"
require "./auth/membership"
require "./auth/api_key"

module Arcana
  # Identity / org / API-key model. Postgres-backed (via Arcana::DB).
  #
  # Stage 1 (this release): models + admin CLI only. Server-side
  # auth enforcement comes in stage 2. Without ARCANA_DATABASE_URL,
  # this module is dormant; current single-tenant localhost behavior
  # is preserved.
  module Auth
    # Hash a full API key into the form stored in the database.
    # Constant-time comparison is the caller's responsibility.
    def self.hash_secret(secret : String) : String
      Digest::SHA256.hexdigest(secret)
    end
  end
end
