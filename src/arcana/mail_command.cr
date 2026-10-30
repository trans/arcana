require "set"
require "./mail"

module Arcana
  module Mail
    # `arcana mail <command>`: the carrier's commands of `dot-ai mail`, for
    # a machine whose carrier is Arcana (dot-ai hands them over). Each
    # prints what dot-ai's does.
    module Command
      USAGE = <<-USAGE
        arcana mail: deliver .ai/ mail between the projects on this machine,
        as its carrier (git config ai.carrier arcana)

          arcana mail deliver [DIR]    deliver the outbox of the project at or above DIR
          arcana mail check [DIR]      list its inbox, oldest first (exit 1 when empty)
          arcana mail topic [TOPIC DESCRIPTION]
                                       make a topic, or list them all
          arcana mail read TOPIC [--after N] [DIR]
                                       the posts after this project's place in TOPIC,
                                       or after post N, and move the place on
          arcana mail find [ADDRESS]   where ADDRESS's project is, or every project found

        A topic is written '#name' (quoted: the shell takes a bare # as a comment)
        or just name.
        USAGE

      class Die < Exception; end

      # Returns the process exit code.
      def self.run(args : Array(String), output : IO = STDOUT, error : IO = STDERR) : Int32
        rest = args[1..]? || [] of String
        case args[0]?
        when "deliver" then deliver(rest, output, error)
        when "check"   then check(rest, output)
        when "topic"   then topic(rest, output)
        when "read"    then read(rest, output)
        when "find"    then find(rest, output, error)
        when "help", "-h", "--help", nil
          output.puts USAGE
          0
        else
          error.puts USAGE
          1
        end
      rescue ex : Die
        error.puts "arcana mail: #{ex.message}"
        1
      end

      private def self.die(message : String) : NoReturn
        raise Die.new(message)
      end

      # Under any other carrier, Arcana stays out of mail.
      private def self.only_ours : Nil
        c = Mail.carrier
        die "this machine's carrier is #{c} (git config ai.carrier), so Arcana stays out of mail" unless c == NAME
      end

      private def self.root_of(dir : String) : String
        Mail.project_root(dir) || die("no .ai/ at or above #{dir}")
      end

      private def self.deliver(args : Array(String), output : IO, error : IO) : Int32
        only_ours
        root = root_of(args[0]? || ".")
        buffer = IO::Memory.new
        Mail.deliver(root, buffer, error)
        text = buffer.to_s
        output.print(text.empty? ? "nothing in the outbox\n" : text)
        text.lines.any? { |l| l.starts_with?("error: ") || l.starts_with?("left in the outbox: ") } ? 1 : 0
      end

      private def self.check(args : Array(String), output : IO) : Int32
        dir = args[0]? || "."
        root = root_of(dir)
        die "#{root} has no .ai/mail/inbox/" unless Dir.exists?(File.join(root, ".ai", "mail", "inbox"))
        list = Mail.inbox(root)
        return 1 if list.empty?
        list.each { |n| output.puts n }
        0
      end

      private def self.topic(args : Array(String), output : IO) : Int32
        only_ours
        here = Mail.project_root(".") || (File.realpath(".") rescue Dir.current)
        home, why = Mail.topic_home(here)
        die why.not_nil! unless home
        name = args[0]?
        if name.nil? || name.empty?
          dirs = Dir.exists?(home) ? Dir.children(home).reject(&.starts_with?('.')).select { |d| Dir.exists?(File.join(home, d)) }.sort : [] of String
          output.puts "no topics yet (they are kept in #{home})" if dirs.empty?
          dirs.each do |d|
            last = Mail.posts_after(File.join(home, d), 0).last?
            output.puts "%-24s %6s posts  %s" % {"##{d}", last ? Mail.post_number(last) : 0, description(File.join(home, d))}
          end
          return 0
        end
        t = name.lchop('#')
        die "##{t} isn't a topic's name: names made like handles, joined by . (#arcana.releases)" unless Mail.topic_ok?(t)
        desc = (args[1]? || "").tr("\n\r\t", "   ").strip(' ')
        die "usage: arcana mail topic TOPIC DESCRIPTION (say what the topic is for)" if desc.empty?
        dir = File.join(home, t)
        die "##{t} already exists: #{description(dir)}" if Dir.exists?(dir)
        begin
          Dir.mkdir_p(home)
          Dir.mkdir(dir)
          File.write(File.join(dir, "description"), "#{desc}\n")
        rescue
          die "couldn't make #{dir}"
        end
        output.puts "made ##{t}"
        0
      end

      private def self.description(dir : String) : String
        path = File.join(dir, "description")
        File.exists?(path) ? (File.read_lines(path).first? || "") : ""
      end

      private def self.read(args : Array(String), output : IO) : Int32
        t = nil
        after = nil
        dir = "."
        i = 0
        while i < args.size
          a = args[i]
          if a == "--after"
            after = args[i + 1]? || ""
            i += 1
          elsif a.starts_with?("--after=")
            after = a.lchop("--after=")
          elsif t.nil?
            t = a
          else
            dir = a
          end
          i += 1
        end
        die "usage: arcana mail read TOPIC [--after N] [DIR]" unless t
        die "--after takes a post's number" if after && !after.each_char.all?(&.ascii_number?)
        only_ours
        t = "##{t.lchop('#')}"
        die "#{t} isn't a topic's address" unless Mail.topic_ok?(t.lchop('#'))
        root = root_of(dir)
        home, why = Mail.topic_home(root)
        die why.not_nil! unless home
        tdir = File.join(home, t.lchop('#'))
        die "there's no topic #{t}" unless Dir.exists?(tdir)
        place = Mail.place_of(root, t)
        from = after.try(&.to_i?) || place
        if (oldest = Mail.posts_after(tdir, 0).first?.try { |p| Mail.post_number(p) }) && oldest > from + 1
          output.print "#{t} keeps posts from #{oldest} on: #{from + 1} to #{oldest - 1} are gone\n\n"
        end
        posts = Mail.posts_after(tdir, from)
        if posts.empty?
          output.puts "no posts in #{t} after #{from}"
          return 0
        end
        posts.each do |p|
          output.puts "==> #{p} <=="
          output.print File.read(File.join(tdir, p))
          output.print "\n"
        end
        last = Mail.post_number(posts.last)
        Mail.set_place(root, t, last) if last > place
        0
      end

      private def self.find(args : Array(String), output : IO, error : IO) : Int32
        here = Mail.project_root(".") || (File.realpath(".") rescue Dir.current)
        map = Mail.scan(here, error)
        address = args[0]?
        if address.nil? || address.empty?
          map.each { |(a, d)| output.puts "%-24s %s" % {a, d} if a }
          map.each { |(a, d)| output.puts "(can't read the handle) #{d}/.ai/config.yml" unless a }
          map.compact_map(&.[0]).tally.each { |a, n| output.puts "two projects have the address #{a}: nothing is delivered to it" if n > 1 }
          return 0
        end
        dir, why = Mail.lookup(map, "@#{address.lchop('@')}")
        die why.not_nil! unless dir
        output.puts dir
        0
      end
    end

    # What the session hooks tell the agent when Arcana is the carrier, as
    # dot-ai's hooks do, naming dot-ai's commands where it's installed
    # (`Mail.dot_ai`) and Arcana's own where it isn't: at session start everything, at Stop only
    # what this session hasn't been told of, and at each prompt only the
    # receipts. What a session was told of is kept in
    # `$XDG_RUNTIME_DIR/arcana-mail/<session id>`, so a message the agent
    # leaves for later never loops it.
    module Notices
      # Delivers the outbox (not at a prompt), then returns what to tell,
      # empty when there's nothing.
      def self.collect(event : String, root : String, session : String?) : String
        say = String::Builder.new
        if event == "prompt"
          receipts(root, say)
          return say.to_s
        end
        buffer = IO::Memory.new
        Mail.deliver(root, buffer)
        return "" if event == "session-end"
        start = event == "session-start"
        told = told_file(session, start)
        heard = File.exists?(told) ? File.read_lines(told).to_set : Set(String).new
        untold = ->(key : String) do
          if !start && heard.includes?(key)
            false
          else
            heard << key
            File.open(told, "a", &.puts(key)) rescue nil
            true
          end
        end
        lines = buffer.to_s.lines

        sent = lines.count { |l| l.starts_with?("delivered: ") || l.starts_with?("posted: ") }
        if sent > 0
          them = sent == 1 ? "it" : "them"
          say << "Arcana sent " << count(sent, "message") << " from the outbox and filed " << them <<
            " under .ai/mail/sent/: commit " << them << ".\n"
        end
        lines.each do |l|
          next unless l.starts_with?("error: ") || l.starts_with?("left in the outbox: ")
          say << "Arcana: " << l << "\n" if untold.call("out:#{l}")
        end

        fresh = Mail.inbox(root).select { |n| untold.call("in:#{n}") }
        unless fresh.empty?
          what = start ? "#{count(fresh.size, "message")} waiting" : count(fresh.size, "new message")
          say << "You have mail: " << what << " in .ai/mail/inbox/:\n"
          fresh.each { |n| say << "  " << n << "\n" }
          if d = Mail.dot_ai
            say << "Process " << (fresh.size == 1 ? "it" : "them, oldest first,") <<
              " as the dot-ai skill says (Processing the inbox), filing each with: " << d << " mail done NAME\n"
          else
            say << "Read " << (fresh.size == 1 ? "it" : "them, oldest first") << "; once each is handled, " \
              "move it to .ai/mail/received/ and commit it with the notes it went into.\n"
          end
        end

        # New posts in the topics the project follows, each told of once
        home = Mail.topic_home(root)[0]
        posts = [] of String
        Mail.follows(root).each do |t|
          why = if !t.starts_with?('#') || !Mail.topic_ok?(t.lchop('#'))
                  "#{t} isn't a topic's address"
                elsif home.nil? || !Dir.exists?(File.join(home, t.lchop('#')))
                  "there's no topic #{t}"
                end
          if why
            say << "Arcana: mail.follow in .ai/config.yml: " << why << "\n" if untold.call("follow:#{t}")
            next
          end
          new = Mail.posts_after(File.join(home.not_nil!, t.lchop('#')), Mail.place_of(root, t))
          next if new.empty?
          next unless untold.call("topic:#{t}:#{Mail.post_number(new.last)}")
          posts << "  #{count(new.size, "new post")} in #{t}"
        end
        unless posts.empty?
          say << "New posts in the topics this project follows:\n"
          posts.each { |p| say << p << "\n" }
          if d = Mail.dot_ai
            say << "Read them with: " << d << " mail read '#topic' (the dot-ai skill: Topics).\n"
          else
            say << "Read them with: arcana mail read '#topic'.\n"
          end
        end

        # The receipts too, at session start or when Stop has something to
        # say anyway: on their own they never keep the agent going
        text = say.to_s
        if start || !text.empty?
          more = String::Builder.new
          receipts(root, more)
          text += more.to_s
        end
        text
      end

      private def self.receipts(root : String, say : String::Builder) : Nil
        told = Mail.receipts(root)
        return if told.empty?
        say << "Receipts for mail this project sent (its copies are in .ai/mail/sent/):\n"
        told.each { |l| say << l << "\n" }
      end

      private def self.count(n : Int32, word : String) : String
        n == 1 ? "1 #{word}" : "#{n} #{word}s"
      end

      # This session's record of what it was told of. Files older than a
      # week are removed at session start.
      private def self.told_file(session : String?, start : Bool) : String
        base = ENV["XDG_RUNTIME_DIR"]?.presence || ENV["TMPDIR"]?.presence || "/tmp"
        dir = File.join(base, "arcana-mail")
        Dir.mkdir_p(dir, 0o700)
        if start
          week = Time.utc - 7.days
          Dir.each_child(dir) do |n|
            path = File.join(dir, n)
            File.delete(path) if (info = File.info?(path)) && info.file? && info.modification_time < week
          end
        end
        path = File.join(dir, session.presence || "no-session")
        File.touch(path)
        path
      rescue
        File.tempname("arcana-mail-told")
      end
    end
  end
end
