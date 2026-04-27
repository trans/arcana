module Arcana
  module Auth
    # User's role in an org.
    enum Role
      Owner
      Admin
      Member

      def self.parse(s : String) : self
        case s.downcase
        when "owner"  then Owner
        when "admin"  then Admin
        when "member" then Member
        else raise Error.new("invalid role: #{s.inspect}")
        end
      end
    end

    struct Membership
      property id : Int64
      property user_id : Int64
      property org_id : Int64
      property role : Role
      property created_at : Time

      def initialize(@id, @user_id, @org_id, @role, @created_at)
      end

      def self.create(user_id : Int64, org_id : Int64, role : Role) : Membership
        db = Arcana::DB.connection!
        row = db.query_one(
          "INSERT INTO memberships (user_id, org_id, role) VALUES ($1, $2, $3) " \
          "RETURNING id, user_id, org_id, role, created_at",
          user_id, org_id, role.to_s.downcase,
          as: {Int64, Int64, Int64, String, Time},
        )
        new(row[0], row[1], row[2], Role.parse(row[3]), row[4])
      end

      def self.for_user(user_id : Int64) : Array(Membership)
        result = [] of Membership
        Arcana::DB.connection!.query(
          "SELECT id, user_id, org_id, role, created_at FROM memberships " \
          "WHERE user_id = $1 ORDER BY id",
          user_id,
        ) do |rs|
          rs.each do
            result << new(
              rs.read(Int64), rs.read(Int64), rs.read(Int64),
              Role.parse(rs.read(String)), rs.read(Time),
            )
          end
        end
        result
      end

      def self.for_org(org_id : Int64) : Array(Membership)
        result = [] of Membership
        Arcana::DB.connection!.query(
          "SELECT id, user_id, org_id, role, created_at FROM memberships " \
          "WHERE org_id = $1 ORDER BY id",
          org_id,
        ) do |rs|
          rs.each do
            result << new(
              rs.read(Int64), rs.read(Int64), rs.read(Int64),
              Role.parse(rs.read(String)), rs.read(Time),
            )
          end
        end
        result
      end
    end
  end
end
