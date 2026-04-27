require "json"

module Arcana
  module Auth
    # An organization — the unit of isolation for billing, quotas,
    # and (eventually) tenancy. Users belong to orgs via memberships.
    struct Org
      property id : Int64
      property slug : String
      property name : String
      property created_at : Time
      property is_system : Bool

      def initialize(@id, @slug, @name, @created_at, @is_system = false)
      end

      # Create a new org. Returns the created Org.
      # Slug must match `[a-z][a-z0-9-]*`.
      def self.create(slug : String, name : String, is_system : Bool = false) : Org
        db = Arcana::DB.connection!
        row = db.query_one(
          "INSERT INTO orgs (slug, name, is_system) VALUES ($1, $2, $3) " \
          "RETURNING id, slug, name, created_at, is_system",
          slug, name, is_system,
          as: {Int64, String, String, Time, Bool},
        )
        new(*row)
      end

      def self.find(id : Int64) : Org?
        row = Arcana::DB.connection!.query_one?(
          "SELECT id, slug, name, created_at, is_system FROM orgs WHERE id = $1",
          id,
          as: {Int64, String, String, Time, Bool},
        )
        row ? new(*row) : nil
      end

      def self.find_by_slug(slug : String) : Org?
        row = Arcana::DB.connection!.query_one?(
          "SELECT id, slug, name, created_at, is_system FROM orgs WHERE slug = $1",
          slug,
          as: {Int64, String, String, Time, Bool},
        )
        row ? new(*row) : nil
      end

      def self.list : Array(Org)
        result = [] of Org
        Arcana::DB.connection!.query(
          "SELECT id, slug, name, created_at, is_system FROM orgs ORDER BY id"
        ) do |rs|
          rs.each do
            result << new(
              rs.read(Int64), rs.read(String), rs.read(String),
              rs.read(Time), rs.read(Bool),
            )
          end
        end
        result
      end
    end
  end
end
