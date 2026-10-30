require "yaml"
require "random/secure"

module Arcana
  # Who a project's agent is on the bus, read from the project's
  # `.ai/config.yml` (the dot-ai convention, draft 0.3):
  #
  #     handle: arcana
  #     description: >
  #       The agent for the Arcana bus itself.
  #
  # The handle may be written with or without its `@`. Configs from before
  # draft 0.3 kept both keys under `arcana:`; those are still read when the
  # top-level keys are missing. Without a handle anywhere, the handle falls
  # back to `@` plus the project directory's name.
  #
  # A session's project is the nearest directory at or above where it
  # works that holds `.ai/` (`find`, `project_root`); only where there is
  # none is the session's own directory the project.
  #
  # The owner token proves to the bus that a registration is this
  # project's (see `Directory#claim`). It lives in `.ai/arcana.token`,
  # kept out of git through the repository's `info/exclude` since it only
  # means something to this machine's bus. A project without `.ai/` keeps
  # it under `$XDG_STATE_HOME/arcana/tokens/` instead.
  #
  # The project's key (see `Arcana::Key`) proves the same, without the
  # bus ever holding the secret: `.ai/arcana.key`, kept out of git the
  # same way, or `$XDG_STATE_HOME/arcana/keys/` without `.ai/`. One key
  # holds all the project's addresses.
  struct AgentConfig
    class Error < Arcana::Error; end

    CONFIG_FILES = {"config.yml", "config.yaml"}
    TOKEN_FILE   = "arcana.token"
    KEY_FILE     = "arcana.key"

    getter project_dir : String
    getter handle : String
    getter description : String

    def initialize(@project_dir : String, @handle : String, @description : String = "")
    end

    # Raises `AgentConfig::Error` when the config exists but can't be
    # read, rather than quietly falling back to the directory name.
    def self.load(project_dir : String) : AgentConfig
      handle = nil
      description = nil
      if path = config_path(project_dir)
        yaml = begin
          YAML.parse(File.read(path))
        rescue ex
          raise Error.new("can't read #{path}: #{ex.message}")
        end
        top = yaml.as_h?
        old = top.try(&.[YAML::Any.new("arcana")]?).try(&.as_h?)
        handle = string_key(top, "handle").try(&.presence) || string_key(old, "handle").try(&.presence)
        description = string_key(top, "description") || string_key(old, "description")
      end
      handle = handle ? (handle.starts_with?('@') ? handle : "@#{handle}") : fallback_handle(project_dir)
      new(project_dir, handle, description || "")
    end

    # The project a session in `dir` works in (dot-ai, "Projects inside
    # projects"): the nearest directory at or above it that holds `.ai/`,
    # since a directory without one belongs to the project above it.
    # Walks the path with symbolic links resolved, as dot-ai does, so
    # both find the same project. With no `.ai/` anywhere above, `dir`
    # itself, whose handle is then the fallback.
    #
    # `.ai` may be a symbolic link to another project's `.ai/`: a folder
    # grouping several repositories under one project links to the `.ai/`
    # of the repository that holds it, and a session in any of them finds
    # that project through the link.
    def self.project_root(dir : String) : String
      start = resolve(dir)
      ancestors(start) { |path| return path.to_s if Dir.exists?(path.join(".ai").to_s) }
      start.to_s
    end

    # An `.ai` link on the way from `dir` to its project whose target is
    # gone. The walk passes it as if it weren't there, so a session it
    # should have led to a project lands in the one above, or in none.
    def self.broken_link(dir : String) : String?
      ancestors(resolve(dir)) do |path|
        ai = path.join(".ai").to_s
        return nil if Dir.exists?(ai)
        return ai if File.symlink?(ai)
      end
      nil
    end

    private def self.resolve(dir : String) : Path
      Path[(File.realpath(dir) rescue File.expand_path(dir))]
    end

    # `start`, then each directory above it, up to `/`.
    private def self.ancestors(start : Path, &) : Nil
      path = start
      loop do
        yield path
        parent = path.parent
        break if parent == path
        path = parent
      end
    end

    # `load` for the project a session in `dir` works in (`project_root`).
    def self.find(dir : String) : AgentConfig
      load(project_root(dir))
    end

    private def self.string_key(map : Hash(YAML::Any, YAML::Any)?, key : String) : String?
      map.try(&.[YAML::Any.new(key)]?).try(&.as_s?).try(&.strip)
    end

    def self.config_path(project_dir : String) : String?
      CONFIG_FILES.each do |name|
        path = File.join(project_dir, ".ai", name)
        return path if File.exists?(path)
      end
      nil
    end

    # `@` plus the directory name, folded into a legal handle.
    def self.fallback_handle(project_dir : String) : String
      name = File.basename(project_dir).downcase.gsub(/[^a-z0-9-]+/, "-").strip('-')
      name = name.empty? ? "agent" : "agent-#{name}" unless name =~ /\A[a-z]/
      "@#{name}"
    end

    def ai_dir? : Bool
      Dir.exists?(File.join(@project_dir, ".ai"))
    end

    def token_path : String
      ai_dir? ? File.join(@project_dir, ".ai", TOKEN_FILE) : state_token_path
    end

    private def state_token_path : String
      state_path("tokens")
    end

    private def state_path(kind : String) : String
      state = ENV["XDG_STATE_HOME"]?.try(&.presence) || File.join(Path.home.to_s, ".local", "state")
      File.join(state, "arcana", kind, @handle.lchop('@'))
    end

    def key_path : String
      ai_dir? ? File.join(@project_dir, ".ai", KEY_FILE) : state_path("keys")
    end

    # The project's key, or nil if none has been made yet.
    def key : Key?
      path = key_path
      Key.load(path) if File.exists?(path)
    end

    # The project's key, made on first use. Each call also checks that
    # git ignores it, which a key made by an older hook may lack.
    def key! : Key
      path = key_path
      Dir.mkdir_p(File.dirname(path))
      key = Key.load_or_create(path)
      exclude_from_git(KEY_FILE, "Arcana key (private, machine-local, see arcana hook)") if ai_dir?
      key
    end

    # The owner token, or nil if none has been made yet.
    def owner_token : String?
      path = token_path
      return File.read(path).strip.presence if File.exists?(path)
      adopt_state_token
    end

    # A project that gained `.ai/` after its first registration still has
    # its token under XDG state. Move it into `.ai/`: a new token would
    # make the bus refuse the handle as held by another owner.
    private def adopt_state_token : String?
      return nil unless ai_dir?
      old = state_token_path
      return nil unless File.exists?(old)
      token = File.read(old).strip.presence || return nil
      File.write(token_path, "#{token}\n", perm: 0o600)
      exclude_from_git(TOKEN_FILE)
      File.delete(old)
      token
    end

    # The owner token, made on first use. Each call also checks that git
    # ignores it, as `key!` does.
    def owner_token! : String
      token = owner_token || begin
        path = token_path
        Dir.mkdir_p(File.dirname(path))
        made = Random::Secure.hex(16)
        File.write(path, "#{made}\n", perm: 0o600)
        made
      end
      exclude_from_git(TOKEN_FILE) if ai_dir?
      token
    end

    # List `file` (in `.ai/`) in the repository's `info/exclude`, which
    # keeps it out of commits without touching any tracked file. The
    # repository is the one the file is in: when `.ai` is a link to
    # another project's, that project's. The pattern is the file's path
    # from the top of its checkout, which is just `/arcana.key` when `.ai`
    # is a checkout of its own: a worktree of the `ai` branch, or a clone.
    # Every worktree shares `info/exclude`, so that pattern also ignores
    # an `arcana.key` at the top of the code checkout, which is harmless.
    private def exclude_from_git(file : String, comment : String = "Arcana owner token (machine-local, see arcana hook)") : Nil
      ai = File.realpath(File.join(@project_dir, ".ai"))
      buffer = IO::Memory.new
      status = Process.run("git", ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude", "--show-prefix"],
        chdir: ai, output: buffer, error: Process::Redirect::Close)
      return unless status.success?
      lines = buffer.to_s.lines
      exclude = lines[0]?.presence || return
      prefix = lines[1]? || ""
      pattern = "/" + "#{prefix}#{file}".gsub(/[\\*?\[]/) { |c| "\\#{c}" }
      return if File.exists?(exclude) && File.read_lines(exclude).includes?(pattern)
      Dir.mkdir_p(File.dirname(exclude))
      File.open(exclude, "a") { |f| f.puts "# #{comment}\n#{pattern}" }
    rescue
      # No git, or not a repository: nothing to keep it out of.
    end
  end
end
