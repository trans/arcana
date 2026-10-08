require "yaml"
require "random/secure"

module Arcana
  # Who a project's agent is on the bus, read from the project's
  # `.ai/config.yml` (the dot-ai convention):
  #
  #     arcana:
  #       handle: "@arcana"
  #       description: >
  #         The agent for the Arcana bus itself.
  #
  # Without a handle in the config, the handle falls back to `@` plus the
  # project directory's name, which is what the session hooks used before
  # the config existed.
  #
  # The owner token proves to the bus that a registration is this
  # project's (see `Directory#claim`). It lives in `.ai/arcana.token`,
  # kept out of git through the repository's `info/exclude` since it only
  # means something to this machine's bus. A project without `.ai/` keeps
  # it under `$XDG_STATE_HOME/arcana/tokens/` instead.
  struct AgentConfig
    class Error < Arcana::Error; end

    CONFIG_FILES = {"config.yml", "config.yaml"}
    TOKEN_FILE   = "arcana.token"

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
        if arcana = yaml.as_h?.try(&.[YAML::Any.new("arcana")]?).try(&.as_h?)
          handle = arcana[YAML::Any.new("handle")]?.try(&.as_s?).try(&.strip).try(&.presence)
          description = arcana[YAML::Any.new("description")]?.try(&.as_s?).try(&.strip)
        end
      end
      handle = handle ? (handle.starts_with?('@') ? handle : "@#{handle}") : fallback_handle(project_dir)
      new(project_dir, handle, description || "")
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
      name = "agent-#{name}" unless name =~ /\A[a-z]/
      "@#{name}"
    end

    def ai_dir? : Bool
      Dir.exists?(File.join(@project_dir, ".ai"))
    end

    def token_path : String
      ai_dir? ? File.join(@project_dir, ".ai", TOKEN_FILE) : state_token_path
    end

    private def state_token_path : String
      state = ENV["XDG_STATE_HOME"]?.try(&.presence) || File.join(Path.home.to_s, ".local", "state")
      File.join(state, "arcana", "tokens", @handle.lchop('@'))
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
      exclude_from_git
      File.delete(old)
      token
    end

    # The owner token, made on first use.
    def owner_token! : String
      if token = owner_token
        return token
      end
      path = token_path
      Dir.mkdir_p(File.dirname(path))
      token = Random::Secure.hex(16)
      File.write(path, "#{token}\n", perm: 0o600)
      exclude_from_git if ai_dir?
      token
    end

    # List the token in the repository's `info/exclude`, which keeps it
    # out of commits without touching any tracked file.
    private def exclude_from_git : Nil
      buffer = IO::Memory.new
      status = Process.run("git", ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"],
        chdir: @project_dir, output: buffer, error: Process::Redirect::Close)
      return unless status.success?
      exclude = buffer.to_s.strip
      pattern = "**/.ai/#{TOKEN_FILE}"
      return if File.exists?(exclude) && File.read_lines(exclude).includes?(pattern)
      Dir.mkdir_p(File.dirname(exclude))
      File.open(exclude, "a") { |f| f.puts "# Arcana owner token (machine-local, see arcana hook)\n#{pattern}" }
    rescue
      # No git, or not a repository: nothing to keep it out of.
    end
  end
end
