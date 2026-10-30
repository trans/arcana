require "digest/sha256"
require "json"
require "yaml"
require "./agent_config"

module Arcana
  # Arcana as a machine's mail carrier (the dot-ai spec's Mail, in the
  # user's `dot.ai` repository): what dot-ai's local carrier does, through
  # the same files and locks (the spec's "The carrier's files"), so either
  # can be the machine's carrier and a change between them moves nothing.
  # Agents keep using `dot-ai mail`, which hands the carrier's part to
  # `arcana mail`.
  #
  # Which carrier a machine has is git config's `ai.carrier`: `arcana`
  # makes Arcana the carrier; under any other (`local`, dot-ai itself, the
  # default) Arcana stays out of mail. Each run reads it afresh.
  #
  # What it prints matches dot-ai line for line, so dot.ai's tests
  # (`tests/dot-ai.sh`, with `CARRIER=arcana`) check both carriers. Where it
  # names a command, it names dot-ai's when dot-ai is installed (`dot_ai`),
  # and its own otherwise: Arcana never needs dot-ai.
  #
  # Where it goes further: a message for an address no project on this
  # machine has goes over the Arcana bus (`bus_sender`), to an agent
  # registered there.
  module Mail
    # This carrier's name: `ai.carrier`'s value for it, and what `Via:`
    # and `Sent: … via` say.
    NAME = "arcana"

    # How far below a search root a project may sit.
    MAX_DEPTH = 4

    HEADER     = /\A(?:By|Held|Re|Sent|Id|Post): /
    OUTBOUND   = /\A[0-9]{8}-[0-9]{6}Z-[@#].*\.md\z/
    AGENT      = /\A@[a-z][a-z0-9-]*\z/
    TOPIC_NAME = /\A[a-z][a-z0-9-]*(?:\.[a-z][a-z0-9-]*)*\z/
    POST_FILE  = /\A[0-9]+-.*\.md\z/

    # A lock older than this is a crashed run's.
    STALE_LOCK = 2.minutes

    # -- The setting ----------------------------------------------------------

    def self.git_config(key : String, all : Bool = false, path : Bool = false) : Array(String)
      args = ["config", all ? "--get-all" : "--get"]
      args << "--type=path" if path
      args << key
      output = IO::Memory.new
      status = Process.run("git", args, output: output, error: Process::Redirect::Close)
      return [] of String unless status.success?
      output.to_s.lines.map(&.chomp).reject(&.empty?)
    rescue
      [] of String
    end

    # The machine's carrier, `local` when unset.
    def self.carrier : String
      git_config("ai.carrier").last?.try(&.strip.presence) || "local"
    end

    # Whether Arcana is this machine's carrier.
    def self.carrier? : Bool
      carrier == NAME
    end

    def self.ai_paths : Array(String)
      git_config("ai.path", all: true, path: true)
    end

    # -- dot-ai ---------------------------------------------------------------

    # dot-ai's command, below a version of its Claude Code or Codex plugin,
    # or below their home for a skill installed by hand.
    DOT_AI_SCRIPT = File.join("skills", "dot-ai", "scripts", "dot-ai")

    # Claude Code's and Codex's homes, where dot-ai is installed for them.
    private def self.agent_homes : Array(String)
      home = Path.home.to_s
      [ENV["CLAUDE_CONFIG_DIR"]?.presence || File.join(home, ".claude"),
       ENV["CODEX_HOME"]?.presence || File.join(home, ".codex")]
    end

    # How an agent runs dot-ai (0.5 or later), for what Arcana tells it:
    # `dot-ai` when it's on the PATH (`dot-ai install`), else the newest
    # copy the dot-ai plugin installed for Claude Code or Codex, or one
    # installed by hand as a skill, run with `sh`. Nil when there's none,
    # and Arcana names its own commands instead.
    def self.dot_ai : String?
      return "dot-ai" if Process.find_executable("dot-ai")
      best = nil
      newest = [] of Int32
      agent_homes.each do |home|
        cache = File.join(home, "plugins", "cache", "dot-ai", "dot-ai")
        next unless Dir.exists?(cache)
        Dir.each_child(cache) do |v|
          next unless v.matches?(/\A\d+\.\d+\.\d+\z/)
          script = File.join(cache, v, DOT_AI_SCRIPT)
          version = v.split('.').map(&.to_i)
          if File.file?(script) && (best.nil? || (version <=> newest) > 0)
            best, newest = script, version
          end
        end
      end
      best ||= agent_homes.map { |h| File.join(h, DOT_AI_SCRIPT) }.find { |s| File.file?(s) }
      best.try { |s| %(sh "#{s}") }
    rescue File::Error
      nil
    end

    # Whether dot-ai is installed at all, in any version: `dot_ai`, or an
    # older one (dot-ai-mail) installed for Claude Code or Codex. Without
    # it, nothing but Arcana carries mail between projects.
    def self.dot_ai? : Bool
      return true if dot_ai
      agent_homes.any? do |h|
        Dir.exists?(File.join(h, "plugins", "cache", "dot-ai", "dot-ai")) || Dir.exists?(File.join(h, "skills", "dot-ai"))
      end
    end

    # -- Projects and addresses -----------------------------------------------

    # The project at or above `dir`: the nearest directory, `dir` included,
    # holding `.ai/` (through a link, too). Nil when there's none.
    def self.project_root(dir : String) : String?
      d = File.realpath(dir) rescue return nil
      loop do
        return d if Dir.exists?(File.join(d, ".ai"))
        return nil if d == "/"
        d = File.dirname(d)
      end
    end

    # A project's address: `@` plus its config's handle, or its
    # directory's name folded (`AgentConfig`). Nil when the config can't
    # be read or its handle isn't one.
    def self.address_of(dir : String) : String?
      handle = AgentConfig.load(dir).handle
      handle if handle.matches?(AGENT)
    rescue AgentConfig::Error
      nil
    end

    # Where to look for projects: `ai.path`, else the outermost project
    # enclosing `root`'s, else `root`'s parent directory.
    def self.search_roots(root : String) : Array(String)
      paths = ai_paths
      return paths unless paths.empty?
      outer = nil
      d = File.dirname(root)
      loop do
        outer = d if Dir.exists?(File.join(d, ".ai"))
        break if d == "/"
        d = File.dirname(d)
      end
      [outer || File.dirname(root)]
    end

    # Every project under the search roots, as {address, directory},
    # sorted by directory; the address is nil when the project's handle
    # can't be read. Symbolic links aren't followed, and hidden
    # directories and `node_modules/` aren't searched. A root that doesn't
    # exist is reported to `warn`.
    def self.scan(root : String, warn : IO? = nil) : Array({String?, String})
      dirs = [] of String
      search_roots(root).each do |r|
        real = File.realpath(r) rescue nil
        unless real && Dir.exists?(real)
          warn.try &.puts("arcana mail: ai.path: no such directory: #{r}")
          next
        end
        walk(real, 1, dirs)
      end
      dirs.uniq.sort.map { |d| {address_of(d), d} }
    end

    # Adds to `found` each directory holding `.ai/` among `dir`'s entries,
    # which are `depth` levels below a search root, and below them.
    private def self.walk(dir : String, depth : Int32, found : Array(String)) : Nil
      Dir.each_child(dir) do |name|
        path = File.join(dir, name)
        info = File.info?(path, follow_symlinks: false)
        next unless info && info.directory?
        if name == ".ai"
          found << dir
        elsif !name.starts_with?('.') && name != "node_modules" && depth < MAX_DEPTH + 1
          walk(path, depth + 1, found)
        end
      end
    rescue File::Error
    end

    # The project with `address`: {directory, nil}, or {nil, why not}.
    def self.lookup(map : Array({String?, String}), address : String) : {String?, String?}
      found = map.select { |entry| entry[0] == address }.map(&.[1])
      case found.size
      when 0 then {nil, "no project on this machine has the address #{address}"}
      when 1 then {found[0], nil}
      else        {nil, "two projects have the address #{address}: #{found.join(" and ")}"}
      end
    end

    # -- Locks --------------------------------------------------------------------

    # Takes the lock `path`, a directory, so making it is atomic; one older
    # than `STALE_LOCK` is a crashed run's, and is cleared.
    def self.lock(path : String) : Bool
      Dir.mkdir(path)
      true
    rescue File::AlreadyExistsError
      info = File.info?(path, follow_symlinks: false)
      return false unless info && info.modification_time < Time.utc - STALE_LOCK
      Dir.delete(path) rescue nil
      begin
        Dir.mkdir(path)
        true
      rescue
        false
      end
    rescue
      false
    end

    def self.unlock(path : String) : Nil
      Dir.delete(path) rescue nil
    end

    # Writes `text` to `dir/name` through a hidden name, renamed into
    # place, so no one reads half of it. False when it can't.
    def self.write_hidden(dir : String, name : String, text : String) : Bool
      tmp = File.join(dir, ".#{name}.#{Process.pid}")
      File.write(tmp, text)
      File.rename(tmp, File.join(dir, name))
      true
    rescue
      File.delete(tmp) rescue nil if tmp
      false
    end

    # -- Topics -----------------------------------------------------------------

    def self.topic_ok?(name : String) : Bool
      name.matches?(TOPIC_NAME)
    end

    # Where this machine's topics are kept: `.ai/topics/` of the topic
    # home, the first `ai.path` directory, else the outermost project at or
    # above `root`. {path, nil}, or {nil, why there's none}.
    def self.topic_home(root : String) : {String?, String?}
      first = ai_paths.first?
      if first
        d = File.realpath(first) rescue nil
        return {nil, "ai.path: no such directory: #{first}"} unless d && Dir.exists?(d)
      else
        d = x = root
        until x == "/"
          x = File.dirname(x)
          d = x if Dir.exists?(File.join(x, ".ai"))
        end
      end
      return {nil, "the topic home, #{d}, has no .ai/"} unless Dir.exists?(File.join(d, ".ai"))
      {File.join(d, ".ai", "topics"), nil}
    end

    # The posts in the topic folder `dir` after number `n`, oldest first.
    def self.posts_after(dir : String, n : Int32) : Array(String)
      return [] of String unless Dir.exists?(dir)
      Dir.children(dir).select { |p| p.matches?(POST_FILE) && post_number(p) > n }.sort
    end

    # A post's number, from its file name.
    def self.post_number(name : String) : Int32
      name.split('-', 2)[0].to_i? || 0
    end

    # The topics the project at `root` follows: `mail.follow` in its
    # config.
    def self.follows(root : String) : Array(String)
      path = AgentConfig.config_path(root) || return [] of String
      list = YAML.parse(File.read(path))["mail"]?.try(&.["follow"]?).try(&.as_a?)
      return [] of String unless list
      list.compact_map { |t| t.as_s?.try(&.strip.presence) }
    rescue
      [] of String
    end

    # The project at `root`'s place in `topic`: the last post it read.
    def self.place_of(root : String, topic : String) : Int32
      path = File.join(root, ".ai", "mail", "following")
      return 0 unless File.exists?(path)
      place = 0
      File.each_line(path) do |line|
        t, n = line.split(' ', 2) + [""]
        place = n.strip.to_i? || 0 if t == topic
      end
      place
    end

    # Moves the project at `root`'s place in `topic` to `n`.
    def self.set_place(root : String, topic : String, n : Int32) : Nil
      mail = File.join(root, ".ai", "mail")
      return unless Dir.exists?(mail)
      path = File.join(mail, "following")
      lines = File.exists?(path) ? File.read_lines(path).reject { |l| l.split(' ', 2)[0] == topic } : [] of String
      lines << "#{topic} #{n}"
      tmp = File.join(mail, ".following.#{Process.pid}")
      File.write(tmp, lines.join("\n") + "\n")
      File.rename(tmp, path)
    end

    # -- Messages -----------------------------------------------------------------

    # An outbound file's header lines, each with its newline, and its
    # message: what follows them and the blank line that ends them.
    def self.layout(text : String) : {Array(String), String}
      header = [] of String
      offset = 0
      text.each_line(chomp: false) do |line|
        if line.matches?(HEADER)
          header << line
          offset += line.bytesize
          next
        end
        offset += line.bytesize if !header.empty? && line == "\n"
        break
      end
      {header, text.byte_slice(offset)}
    end

    # Whether a `Re:` line names something: a message's id (8 or more hex
    # digits) or a topic's post (`#topic:number`).
    def self.re_ok?(re : String) : Bool
      if re.starts_with?('#') && re.includes?(':')
        topic, _, number = re.rpartition(':')
        topic = topic.lchop('#')
        !number.empty? && number.each_char.all?(&.ascii_number?) &&
          !topic.empty? && topic.matches?(/\A[a-z0-9.-]+\z/)
      else
        re.size >= 8 && re.matches?(/\A[0-9a-f]+\z/)
      end
    end

    # A message's id: the first 8 hex digits of the SHA-256 of the
    # sender's address, the outbound file's name and the message.
    def self.message_id(sender : String, name : String, message : String) : String
      Digest::SHA256.hexdigest("#{sender}\n#{name}\n#{message}")[0, 8]
    end

    # A message on its way: what the inbox file or post is made from.
    record Outgoing, sender : String, to : String, topic : String, id : String,
      re : String?, iso : String, message : String, inbox_name : String

    # Sends a message over the Arcana bus: nil once the bus has it, else
    # why not.
    alias BusSend = Proc(Outgoing, String?)

    # An inbox file's or post's text: header lines, a blank line, then
    # the message.
    def self.inbox_text(m : Outgoing, post : Int32? = nil) : String
      String.build do |io|
        io << "From: " << m.sender << "\nTo: " << m.to << "\nSent: " << m.iso << "\n"
        io << "Subject: " << m.topic << "\n" unless m.topic.empty?
        io << "Id: " << m.id << "\n"
        io << "Post: " << post << "\n" if post
        io << "Re: " << m.re << "\n" if m.re
        io << "Via: " << NAME << "\n\n" << m.message
      end
    end

    # Files with a name ending in `-<id>.md` in `dir`, hidden ones aside.
    def self.has_id?(dir : String, id : String) : Bool
      Dir.exists?(dir) && Dir.children(dir).any? { |n| !n.starts_with?('.') && n.ends_with?("-#{id}.md") }
    end

    # -- Delivery -------------------------------------------------------------------

    # Delivers the outbox of the project at `root`, one line per message
    # to `io`: delivered (posted, for a topic), or left in the outbox and
    # why (the spec's Delivery, under the outbox's lock). A message for an
    # address no project here has goes to `bus`.
    def self.deliver(root : String, io : IO, warn : IO? = nil, bus : BusSend? = bus_sender(root)) : Nil
      box = File.join(root, ".ai", "mail", "outbox")
      return unless Dir.exists?(box)
      names = Dir.children(box).reject(&.starts_with?('.')).sort
      return if names.empty?

      sender = address_of(root)
      unless sender
        io.puts "error: #{root}/.ai/config.yml: its handle line isn't a handle, so nothing was delivered"
        return
      end

      lock_path = File.join(box, ".delivering")
      unless lock(lock_path)
        io.puts "busy: another delivery from this outbox is running"
        return
      end
      begin
        map = scan(root, warn)
        names.each { |name| deliver_one(root, box, name, sender, map, io, bus) }
      ensure
        unlock(lock_path)
      end
    end

    private def self.deliver_one(root : String, box : String, name : String, sender : String,
                                 map : Array({String?, String}), io : IO, bus : BusSend?) : Nil
      f = File.join(box, name)
      return unless File.file?(f)
      unless name.matches?(OUTBOUND)
        io.puts "left in the outbox: #{name}: its name isn't <time>-<address>--<topic>.md"
        return
      end
      base = name[17..].rchop(".md")
      to, sep, topic = base.partition("--")
      topic = "" if sep.empty?

      # Where it goes: a topic's folder, a project's inbox, or the bus
      dir = nil
      dest = ""
      if to.starts_with?('#')
        unless topic_ok?(to.lchop('#'))
          io.puts "left in the outbox: #{name}: #{to} isn't an address"
          return
        end
        home, why = topic_home(root)
        unless home
          io.puts "left in the outbox: #{name}: #{why}"
          return
        end
        dest = File.join(home, to.lchop('#'))
        unless Dir.exists?(dest)
          io.puts "left in the outbox: #{name}: there's no topic #{to} (#{dot_ai ? "dot-ai" : "arcana"} mail topic makes one)"
          return
        end
      else
        unless to.matches?(AGENT)
          io.puts "left in the outbox: #{name}: #{to} isn't an address"
          return
        end
        dir, why = lookup(map, to)
        if dir
          dest = File.join(dir, ".ai", "mail", "inbox")
          unless Dir.exists?(dest)
            io.puts "left in the outbox: #{name}: #{to} (#{dir}) has no .ai/mail/inbox/"
            return
          end
        elsif bus.nil? || map.any? { |entry| entry[0] == to }
          io.puts "left in the outbox: #{name}: #{why}"
          return
        end
      end

      text = File.read(f)
      header, message = layout(text)
      re = header.find(&.starts_with?("Re:")).try { |l| l.lchop("Re:").lstrip(' ').delete('\r').rstrip.presence }
      if re && !re_ok?(re)
        io.puts "left in the outbox: #{name}: its Re: line isn't a message's id or a topic's post (#topic:number)"
        return
      end
      id = message_id(sender, name, message)
      now = Time.utc
      stamp = now.to_s("%Y%m%d-%H%M%SZ")
      iso = now.to_s("%Y-%m-%dT%H:%M:%SZ")
      inbox_name = "#{stamp}-#{sender}--#{topic.empty? ? "" : "#{topic}-"}#{id}.md"
      m = Outgoing.new(sender, to, topic, id, re, iso, message, inbox_name)

      post = nil
      if to.starts_with?('#')
        post, why = post_to(dest, m)
        unless post
          io.puts "left in the outbox: #{name}: #{why}"
          return
        end
      elsif dir.nil?
        if why = bus.try &.call(m)
          io.puts "left in the outbox: #{name}: #{why}"
          return
        end
      elsif !has_id?(dest, id) && !has_id?(File.join(dir, ".ai", "mail", "received"), id)
        # Deliver, unless an earlier run did and stopped before filing it
        unless write_hidden(dest, inbox_name, inbox_text(m))
          io.puts "left in the outbox: #{name}: couldn't write to #{dest}/ " \
                  "(from a sandbox, leave it: the session hooks deliver it when the turn ends)"
          return
        end
      end

      # File the original under sent/, with Sent: and Id: lines, and Post:
      # for a post
      sent = File.join(root, ".ai", "mail", "sent")
      Dir.mkdir_p(sent) rescue nil
      unless File.exists?(File.join(sent, name))
        copy = String.build do |s|
          header.each { |l| s << l }
          s << "Sent: " << iso << " via " << NAME << "\nId: " << id << "\n"
          s << "Post: " << post << "\n" if post
          s << "\n" << message
        end
        unless write_hidden(sent, name, copy)
          io.puts "error: #{name} went to #{to}, but couldn't be filed under .ai/mail/sent/"
          return
        end
      end
      File.delete(f) rescue nil
      if post
        io.puts "posted: #{name} to #{to} as post #{post}"
      elsif dir
        wait_for_receipt(box, id, to, dir, name)
        io.puts "delivered: #{name} to #{to}"
      else
        # No receipt: nothing on the bus tells yet when a message is read
        io.puts "delivered: #{name} to #{to} over the Arcana bus"
      end
    end

    # Sends mail from the project at `root` over the bus at `ARCANA_URL`,
    # as the MCP bridge's `arcana_deliver` would: from the project's
    # handle, to be read when the agent gets to it, with the message's id
    # and `Re:`, the request signed with the project's key and the
    # message too, so its recipient can check who sent it. The subject is
    # the outbound name's topic.
    def self.bus_sender(root : String) : BusSend
      ->(m : Outgoing) do
        rest = Hook::Rest.new(ENV["ARCANA_URL"]?.presence || "http://127.0.0.1:19118")
        key = (AgentConfig.load(root).key rescue nil)
        rest.key = key
        payload = JSON.parse({text: m.message}.to_json)
        envelope = Envelope.new(from: m.sender, to: m.to, subject: m.topic, payload: payload, id: m.id, re: m.re)
        body = {
          "from"           => JSON::Any.new(m.sender),
          "to"             => JSON::Any.new(m.to),
          "subject"        => JSON::Any.new(m.topic),
          "payload"        => payload,
          "ordering"       => JSON::Any.new("async"),
          "id"             => JSON::Any.new(m.id),
          "re"             => JSON::Any.new(m.re),
          "correlation_id" => JSON::Any.new(envelope.correlation_id),
          "timestamp"      => JSON::Any.new(envelope.timestamp.to_rfc3339),
        }
        if key && (sig = envelope.signed(key).signature)
          body["signature"] = JSON.parse({key: sig.key, sig: sig.sig}.to_json)
        end
        status, reply = rest.post("/deliver", body)
        if status == 200
          nil
        elsif status
          said = reply.try(&.["error"]?).try(&.as_s?) || "status #{status}"
          "no project on this machine has the address #{m.to}, and the Arcana bus says: #{said}"
        else
          "no project on this machine has the address #{m.to}, and the Arcana bus can't be reached"
        end.as(String?)
      end
    end

    # Posts `m` to the topic folder `dir`, taking the next number while
    # holding the topic's lock: {its number, nil}, or {nil, why not}. A
    # post with this id already there (a run that stopped before filing
    # it) keeps its number.
    private def self.post_to(dir : String, m : Outgoing) : {Int32?, String?}
      lock_path = File.join(dir, ".posting")
      tries = 0
      until lock(lock_path)
        tries += 1
        return {nil, "another post to #{m.to} is being made: it goes next time"} if tries >= 5
        sleep 1.second
      end
      begin
        if old = Dir.children(dir).find { |n| !n.starts_with?('.') && n.matches?(/\A[0-9]*-.*-#{m.id}\.md\z/) }
          return {post_number(old), nil}
        end
        n = (posts_after(dir, 0).max_of? { |p| post_number(p) } || 0) + 1
        return {nil, "couldn't write to #{dir}"} unless write_hidden(dir, "%06d-%s" % {n, m.inbox_name}, inbox_text(m, n))
        {n, nil}
      ensure
        unlock(lock_path)
      end
    end

    # -- Receipts ---------------------------------------------------------------

    # Adds a message to the outbox's `.receipts`, the ones waiting until
    # their recipient files them under `received/`: id, address, the
    # recipient's project and the outbound file's name, tab-separated.
    # Called under the outbox's lock.
    private def self.wait_for_receipt(box : String, id : String, to : String, dir : String, name : String) : Nil
      path = File.join(box, ".receipts")
      return if File.exists?(path) && File.read_lines(path).any?(&.starts_with?("#{id}\t"))
      File.open(path, "a") { |file| file << id << '\t' << to << '\t' << dir << '\t' << name << '\n' }
    rescue
    end

    # The receipts for the mail the project at `root` sent: a line for
    # each message read, or one that can't be any more, whose line is
    # dropped. A line whose project doesn't start with `/` is another
    # carrier's, for a recipient elsewhere, and is left. Left for next
    # time while a delivery holds the outbox.
    def self.receipts(root : String) : Array(String)
      box = File.join(root, ".ai", "mail", "outbox")
      path = File.join(box, ".receipts")
      return [] of String unless File.exists?(path) && File.size(path) > 0
      lock_path = File.join(box, ".delivering")
      return [] of String unless lock(lock_path)
      told = [] of String
      begin
        waiting = [] of String
        File.each_line(path) do |line|
          id, to, dir, name = line.split('\t', 4) + ["", "", ""]
          next if name.empty?
          state = if !dir.starts_with?('/')
                    :waiting
                  elsif !Dir.exists?(File.join(dir, ".ai", "mail"))
                    :moved
                  elsif has_id?(File.join(dir, ".ai", "mail", "received"), id)
                    :read
                  elsif has_id?(File.join(dir, ".ai", "mail", "inbox"), id)
                    :waiting
                  else
                    :gone
                  end
          case state
          when :waiting then waiting << line
          when :read    then told << "  #{to} read #{name}"
          when :gone    then told << "  #{to} took #{name} out of its inbox without filing it under received/"
          else               told << "  #{to}: no telling whether it read #{name}, since its project is no longer at #{dir}"
          end
        end
        if waiting.empty?
          File.delete(path)
        else
          write_hidden(box, ".receipts", waiting.join("\n") + "\n")
        end
      ensure
        unlock(lock_path)
      end
      told
    end

    # The inbox of the project at `root`, oldest first.
    def self.inbox(root : String) : Array(String)
      dir = File.join(root, ".ai", "mail", "inbox")
      return [] of String unless Dir.exists?(dir)
      Dir.children(dir).reject(&.starts_with?('.')).sort
    end
  end
end
