module Arcana
  module Auth
    # A user — currently used as a principal for API key ownership.
    # Password auth is reserved for v2; for now `password_hash` is nil.
    struct User
      property id : Int64
      property email : String
      property name : String?
      property password_hash : String?
      property created_at : Time

      def initialize(@id, @email, @name, @password_hash, @created_at)
      end

      def self.create(email : String, name : String? = nil) : User
        db = Arcana::DB.connection!
        row = db.query_one(
          "INSERT INTO users (email, name) VALUES ($1, $2) " \
          "RETURNING id, email, name, password_hash, created_at",
          email, name,
          as: {Int64, String, String?, String?, Time},
        )
        new(*row)
      end

      def self.find(id : Int64) : User?
        row = Arcana::DB.connection!.query_one?(
          "SELECT id, email, name, password_hash, created_at FROM users WHERE id = $1",
          id,
          as: {Int64, String, String?, String?, Time},
        )
        row ? new(*row) : nil
      end

      def self.find_by_email(email : String) : User?
        row = Arcana::DB.connection!.query_one?(
          "SELECT id, email, name, password_hash, created_at FROM users WHERE email = $1",
          email,
          as: {Int64, String, String?, String?, Time},
        )
        row ? new(*row) : nil
      end

      def self.list : Array(User)
        result = [] of User
        Arcana::DB.connection!.query(
          "SELECT id, email, name, password_hash, created_at FROM users ORDER BY id"
        ) do |rs|
          rs.each do
            result << new(
              rs.read(Int64), rs.read(String),
              rs.read(String?), rs.read(String?), rs.read(Time),
            )
          end
        end
        result
      end
    end
  end
end
