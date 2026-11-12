module Arcana
  module Mail
    # Session records and runners, as the dot-ai spec has them (Mail:
    # Runners, Session records; Draft 0.5 for registered runners), kept the
    # same way whichever program writes them, so each reads the others'.
    # Where Arcana is the carrier, its hooks keep a record of each session
    # (`Hook`), and delivery tells the newest open session of each project
    # it put mail into through that session's runner (`tell_project`).
    # Arcana never pushes into a session itself: its own `tell` says when a
    # session will hear at the end of its turn, and otherwise that it can't
    # push (`own_tell`). Pushing belongs to the runners.
    module Sessions
      # How long a runner's `tell` may take before it's given up on.
      TELL_TIMEOUT = 10.seconds

      # What a runner's or a carrier's name may be: never a path or a
      # command line.
      NAME_RE = /\A[a-z0-9-]+\z/

      # A record ended (or whose harness went) this long ago may be removed.
      KEEP = 7.days

      def self.state_base : String
        ENV["XDG_STATE_HOME"]?.presence || File.join(Path.home.to_s, ".local", "state")
      end

      # Where every runner keeps its sessions' records: the person's own.
      def self.dir : String
        File.join(state_base, "dot-ai", "sessions")
      end

      # Where runners register: `runners/NAME`, a line holding the
      # runner's program's absolute path.
      def self.runners_dir : String
        File.join(state_base, "dot-ai", "runners")
      end

      # A session's id as its record's name.
      def self.key(id : String) : String
        id.gsub(/[^A-Za-z0-9_.-]/, "_")
      end

      def self.path(id : String) : String
        File.join(dir, "#{key(id)}.session")
      end

      # The record at `path` as fields; empty when there's none.
      def self.read(path : String) : Hash(String, String)
        fields = {} of String => String
        File.each_line(path) do |line|
          k, sep, v = line.partition('=')
          fields[k] ||= v unless sep.empty?
        end
        fields
      rescue File::Error
        {} of String => String
      end

      # Writes a record, under a hidden name renamed into place, in the
      # records folder, made private to the person if need be.
      def self.write(path : String, fields : Hash(String, String)) : Nil
        Dir.mkdir_p(dir, 0o700)
        File.chmod(dir, 0o700) rescue nil
        text = String.build do |io|
          {"root", "agent", "id", "by", "pid", "state"}.each do |k|
            v = fields[k]?
            io << k << '=' << v << '\n' if v && !(k == "pid" && v.empty?)
          end
        end
        tmp = File.join(File.dirname(path), ".#{File.basename(path)}.#{Process.pid}")
        File.write(tmp, text)
        File.rename(tmp, path)
      rescue File::Error
        File.delete?(tmp) rescue nil if tmp
      end

      # Changes the state of a record that exists.
      def self.set_state(path : String, state : String) : Nil
        fields = read(path)
        return if fields.empty?
        fields["state"] = state
        write(path, fields)
      end

      # Whether a record's session is still open: not ended, and its
      # harness's process, where it names one, still there.
      def self.open?(fields : Hash(String, String)) : Bool
        return false if fields["state"]? == "ended"
        pid = fields["pid"]?.presence || return true
        alive?(pid)
      end

      private def self.alive?(pid : String) : Bool
        n = pid.to_i64? || return false
        Process.exists?(n)
      rescue
        false
      end

      # The runner of a session the hooks record: the program that started
      # it, by `DOT_AI_BY`; else Arcana, the hooks' carrier. There's no
      # default runner.
      def self.by : String
        v = ENV["DOT_AI_BY"]?
        v && v.matches?(NAME_RE) ? v : NAME
      end

      # The harness's process, for Claude Code or Codex: the nearest
      # process above this one, within three, that is the harness's (a hook
      # runs under a shell it starts). For Codex, only under `codex
      # --no-daemon`, whose TUI runs its app server itself; a hook its
      # daemon runs (`codex app-server`, which outlives its sessions) gets
      # none.
      def self.harness_pid(agent : String) : String?
        return nil unless agent == "claude" || agent == "codex"
        pid = Process.ppid
        3.times do
          break if pid <= 1
          args = ps(pid, "args") || return nil
          first = args.split(' ', 2)[0]
          if first == agent || first.ends_with?("/#{agent}")
            return nil if " #{args} ".includes?(" app-server ")
            return pid.to_s
          end
          pid = ps(pid, "ppid").try(&.to_i64?) || return nil
        end
        nil
      end

      private def self.ps(pid : Int64, field : String) : String?
        buf = IO::Memory.new
        status = Process.run("ps", ["-o", "#{field}=", "-p", pid.to_s], output: buf, error: Process::Redirect::Close)
        status.success? ? buf.to_s.strip.presence : nil
      rescue
        nil
      end

      # Writes the session's record in state `state`. Its runner and
      # harness's process are found at its start and kept after.
      def self.record(id : String, root : String, agent : String, state : String, start : Bool) : Nil
        path = self.path(id)
        old = start ? ({} of String => String) : read(path)
        by_now = old["by"]? || by
        pid = old.empty? ? harness_pid(agent) : old["pid"]?
        write(path, {"root" => root, "agent" => agent, "id" => id, "by" => by_now,
                     "pid" => pid || "", "state" => state})
      end

      # Removes records ended, or whose harness went, a week ago.
      def self.clean : Nil
        return unless Dir.exists?(dir)
        week = Time.utc - KEEP
        Dir.each_child(dir) do |n|
          next unless n.ends_with?(".session") && !n.starts_with?('.')
          p = File.join(dir, n)
          info = File.info?(p) || next
          File.delete?(p) if info.modification_time < week && !open?(read(p))
        end
      rescue File::Error
      end

      # The records of the project at `root`'s sessions, newest first.
      def self.newest_first(root : String) : Array({String, Hash(String, String)})
        return [] of {String, Hash(String, String)} unless Dir.exists?(dir)
        entries = Dir.children(dir).select { |n| n.ends_with?(".session") && !n.starts_with?('.') }.compact_map do |n|
          p = File.join(dir, n)
          info = File.info?(p) || next
          fields = read(p)
          next unless fields["root"]? == root
          {p, fields, info.modification_time}
        end
        entries.sort_by { |e| e[2] }.reverse.map { |e| {e[0], e[1]} }
      end

      # Tells the project at `root`, whose inbox mail has just reached: its
      # newest open session, through its runner, so two sessions don't both
      # answer the mail. Status 0: told, or will be at the end of its turn;
      # 3: not open, so the next newest; 4: can't push, so the session hears
      # at its next start or Stop, from the hooks. Arcana's own sessions it
      # answers for itself (`own_tell`); others', through the program their
      # runner registered (`runner_path`). A record naming a runner that
      # hasn't registered, or whose registration fails the checks, is left
      # alone, as if it answered 4: its session has hooks, so it hears at
      # its Stop, and telling an older one as well would have two answer. A
      # runner that fails is named in a `not told:` line to `io`: the mail
      # was delivered all the same.
      def self.tell_project(root : String, io : IO) : Nil
        real = File.realpath(root) rescue return
        newest_first(real).each do |(_, fields)|
          next unless open?(fields)
          id = fields["id"]?.presence || next
          by = fields["by"]? || ""
          status = if by == NAME
                     own_tell(id)
                   elsif prog = runner_path(by)
                     run_tell(prog, id)
                   else
                     4
                   end
          next if status == 3
          unless status == 0 || status == 4
            io.puts "not told: #{real}'s newest session, since #{by} tell #{id} exited #{status}"
          end
          break
        end
      end

      # Arcana's own `tell`, for a session whose runner is Arcana: 3 when
      # there's no record or its session isn't open (marking it ended), 0
      # when it's busy (its Stop tells it), and 4 otherwise, since Arcana
      # never pushes.
      def self.own_tell(id : String) : Int32
        p = path(id)
        fields = read(p)
        return 3 if fields.empty?
        unless open?(fields)
          set_state(p, "ended")
          return 3
        end
        fields["state"]? == "busy" ? 0 : 4
      end

      # Runs `prog tell id`, given up on after `TELL_TIMEOUT`: its exit
      # status, or 128 plus the signal that ended it.
      private def self.run_tell(prog : String, id : String) : Int32
        process = Process.new(prog, ["tell", id], input: Process::Redirect::Close,
          output: Process::Redirect::Close, error: Process::Redirect::Close)
        done = Channel(Process::Status).new(1)
        spawn { done.send(process.wait) }
        status = select
        when s = done.receive
          s
        when timeout(TELL_TIMEOUT)
          process.terminate rescue nil
          select
          when s = done.receive
            s
          when timeout(2.seconds) # one that won't stop when asked
            process.terminate(graceful: false) rescue nil
            done.receive
          end
        end
        status.exit_code? || 128 + (status.exit_signal?.try(&.value) || 0)
      rescue
        127
      end

      # The program of the runner `name`, as it registered it; nil where it
      # hasn't, or where its registration or its program fails the checks:
      # the folder and the file the person's, the line an absolute path to
      # an executable that's the person's (or root's), checked at what a
      # link leads to, and none of them writable by anyone else.
      def self.runner_path(name : String) : String?
        return nil unless name.matches?(NAME_RE)
        file = File.join(runners_dir, name)
        return nil unless mine_only?(runners_dir, dir: true) && mine_only?(file)
        prog = File.read_lines(file).first?.try(&.strip) || return nil
        return nil unless prog.starts_with?('/') && File::Info.executable?(prog)
        mine_only?(prog, program: true) ? prog : nil
      rescue File::Error
        nil
      end

      private def self.mine_only?(path : String, dir : Bool = false, program : Bool = false) : Bool
        info = File.info?(path, follow_symlinks: program) || return false
        return false unless dir ? info.directory? : info.file?
        me = LibC.getuid.to_s
        return false unless info.owner_id == me || (program && info.owner_id == "0")
        perms = info.permissions
        !perms.includes?(File::Permissions::GroupWrite) && !perms.includes?(File::Permissions::OtherWrite)
      end
    end
  end
end
