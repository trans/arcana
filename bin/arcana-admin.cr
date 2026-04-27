require "../src/arcana"

# arcana-admin — bootstrap and manage the Postgres-backed identity store.
#
# Doesn't talk to the running server. Operates directly on the database
# via ARCANA_DATABASE_URL, so you can use it before/while the server is
# running.

USAGE = <<-USAGE
  arcana-admin — manage the Arcana identity / org / api-key store

  Setup:
    ARCANA_DATABASE_URL=postgres://user:pass@host:port/dbname

  Commands:
    migrate                                 Apply any pending migrations.
    org create <slug> <name> [--system]     Create an org. --system flags it
                                            as the platform org (id=1 by
                                            convention; admin keys live here).
    org list                                List all orgs.
    user create <email> [--name <name>]     Create a user.
    user list                               List all users.
    member add <user_email> <org_slug> <role>
                                            Add a user to an org. role =
                                            owner | admin | member.
    member list <org_slug>                  List members of an org.
    key create <name> [--org <slug>] [--scope <s>]
                                            Create an API key. --org omitted
                                            = platform admin key (org_id NULL).
                                            Prints the secret ONCE.
    key list [--org <slug>]                 List keys (active + revoked).
    key revoke <prefix>                     Revoke an active key by prefix.

  Examples:
    arcana-admin migrate
    arcana-admin org create acme "Acme Corp"
    arcana-admin user create alice@acme.example --name Alice
    arcana-admin member add alice@acme.example acme owner
    arcana-admin key create "Alice's CLI" --org acme
    arcana-admin key create "Platform admin" --scope admin
USAGE

def die(msg : String, code : Int32 = 1) : NoReturn
  STDERR.puts msg
  exit code
end

def require_args(args : Array(String), n : Int32, usage : String)
  die("#{usage}\n\n(#{n} positional argument#{n == 1 ? "" : "s"} required)") if args.size < n
end

# --- Flag parsing helpers ---

def flag_value(args : Array(String), flag : String) : String?
  i = args.index(flag)
  return nil unless i
  raise "missing value for #{flag}" unless i + 1 < args.size
  v = args[i + 1]
  args.delete_at(i, 2)
  v
end

def flag_bool(args : Array(String), flag : String) : Bool
  i = args.index(flag)
  return false unless i
  args.delete_at(i)
  true
end

# --- Commands ---

def cmd_migrate
  applied = Arcana::DB::Migrate.run
  if applied.empty?
    puts "No pending migrations."
  else
    applied.each { |f| puts "Applied #{f}" }
  end
end

def cmd_org_create(args : Array(String))
  is_system = flag_bool(args, "--system")
  require_args(args, 2, "Usage: arcana-admin org create <slug> <name> [--system]")
  slug = args[0]
  name = args[1..].join(" ")
  org = Arcana::Auth::Org.create(slug, name, is_system)
  puts "Created org id=#{org.id} slug=#{org.slug.inspect} name=#{org.name.inspect}#{org.is_system ? " (system)" : ""}"
end

def cmd_org_list
  orgs = Arcana::Auth::Org.list
  if orgs.empty?
    puts "(no orgs)"
  else
    orgs.each do |o|
      puts "%6d  %-24s  %s%s" % [o.id, o.slug, o.name, o.is_system ? "  [system]" : ""]
    end
  end
end

def cmd_user_create(args : Array(String))
  name = flag_value(args, "--name")
  require_args(args, 1, "Usage: arcana-admin user create <email> [--name <name>]")
  user = Arcana::Auth::User.create(args[0], name)
  puts "Created user id=#{user.id} email=#{user.email.inspect}"
end

def cmd_user_list
  users = Arcana::Auth::User.list
  if users.empty?
    puts "(no users)"
  else
    users.each do |u|
      puts "%6d  %-32s  %s" % [u.id, u.email, u.name || "—"]
    end
  end
end

def cmd_member_add(args : Array(String))
  require_args(args, 3, "Usage: arcana-admin member add <user_email> <org_slug> <role>")
  user = Arcana::Auth::User.find_by_email(args[0]) || die("no such user: #{args[0]}")
  org = Arcana::Auth::Org.find_by_slug(args[1]) || die("no such org: #{args[1]}")
  role = Arcana::Auth::Role.parse(args[2])
  m = Arcana::Auth::Membership.create(user.id, org.id, role)
  puts "Added user #{user.email} to org #{org.slug} as #{role}"
  puts "  membership id=#{m.id}"
end

def cmd_member_list(args : Array(String))
  require_args(args, 1, "Usage: arcana-admin member list <org_slug>")
  org = Arcana::Auth::Org.find_by_slug(args[0]) || die("no such org: #{args[0]}")
  members = Arcana::Auth::Membership.for_org(org.id)
  if members.empty?
    puts "(no members in #{org.slug})"
  else
    members.each do |m|
      user = Arcana::Auth::User.find(m.user_id)
      email = user.try(&.email) || "?"
      puts "%-32s  %s" % [email, m.role.to_s.downcase]
    end
  end
end

def cmd_key_create(args : Array(String))
  org_slug = flag_value(args, "--org")
  scope = flag_value(args, "--scope") || "full"
  require_args(args, 1, "Usage: arcana-admin key create <name> [--org <slug>] [--scope <s>]")
  name = args.join(" ")

  org_id = if org_slug
             org = Arcana::Auth::Org.find_by_slug(org_slug) || die("no such org: #{org_slug}")
             org.id
           else
             nil # platform admin key
           end

  key, secret = Arcana::Auth::ApiKey.create(name: name, org_id: org_id, scope: scope)
  puts "Created API key:"
  puts "  id     = #{key.id}"
  puts "  org    = #{org_slug || "(platform admin)"}"
  puts "  prefix = #{key.prefix}"
  puts "  scope  = #{key.scope}"
  puts ""
  puts "  SECRET (shown once, store this somewhere safe):"
  puts "    #{secret}"
end

def cmd_key_list(args : Array(String))
  org_slug = flag_value(args, "--org")
  if org_slug
    org = Arcana::Auth::Org.find_by_slug(org_slug) || die("no such org: #{org_slug}")
    keys = Arcana::Auth::ApiKey.list_for_org(org.id)
    label = "org #{org_slug}"
  else
    # All keys with org_id IS NULL = platform admin keys
    keys = [] of Arcana::Auth::ApiKey
    Arcana::DB.connection!.query(
      "SELECT id, org_id, prefix, hash, name, scope, created_at, last_used_at, revoked_at " \
      "FROM api_keys WHERE org_id IS NULL ORDER BY id"
    ) do |rs|
      rs.each do
        keys << Arcana::Auth::ApiKey.new(
          rs.read(Int64), rs.read(Int64?), rs.read(String),
          rs.read(String), rs.read(String), rs.read(String),
          rs.read(Time), rs.read(Time?), rs.read(Time?),
        )
      end
    end
    label = "platform admin"
  end

  if keys.empty?
    puts "(no keys for #{label})"
    return
  end

  keys.each do |k|
    status = k.revoked? ? "revoked" : "active"
    used = k.last_used_at.try(&.to_rfc3339) || "never"
    puts "%-12s  %-6s  %-20s  used: %s" % [k.prefix, status, k.name, used]
  end
end

def cmd_key_revoke(args : Array(String))
  require_args(args, 1, "Usage: arcana-admin key revoke <prefix>")
  prefix = args[0]
  key = Arcana::Auth::ApiKey.find_by_prefix(prefix) || die("no active key with prefix: #{prefix}")
  key.revoke
  puts "Revoked key #{prefix} (#{key.name})"
end

# --- Dispatch ---

args = ARGV.dup

if args.empty? || args.first?.in?({"-h", "--help", "help"})
  puts USAGE
  exit 0
end

unless Arcana::DB.enabled?
  die("ARCANA_DATABASE_URL is not set. Configure it to point at your Postgres instance.")
end

cmd = args.shift

begin
  case cmd
  when "migrate"
    cmd_migrate
  when "org"
    sub = args.shift? || die("Usage: arcana-admin org <create|list> ...")
    case sub
    when "create" then cmd_org_create(args)
    when "list"   then cmd_org_list
    else               die("unknown subcommand: org #{sub}")
    end
  when "user"
    sub = args.shift? || die("Usage: arcana-admin user <create|list> ...")
    case sub
    when "create" then cmd_user_create(args)
    when "list"   then cmd_user_list
    else               die("unknown subcommand: user #{sub}")
    end
  when "member"
    sub = args.shift? || die("Usage: arcana-admin member <add|list> ...")
    case sub
    when "add"  then cmd_member_add(args)
    when "list" then cmd_member_list(args)
    else             die("unknown subcommand: member #{sub}")
    end
  when "key"
    sub = args.shift? || die("Usage: arcana-admin key <create|list|revoke> ...")
    case sub
    when "create" then cmd_key_create(args)
    when "list"   then cmd_key_list(args)
    when "revoke" then cmd_key_revoke(args)
    else               die("unknown subcommand: key #{sub}")
    end
  else
    die("unknown command: #{cmd}\n\n#{USAGE}")
  end
rescue ex : Arcana::Error
  die("error: #{ex.message}")
ensure
  Arcana::DB.close
end
