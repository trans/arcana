require "./spec_helper"
require "http/client"
require "file_utils"

# These run inside agent sessions, whose CLAUDE_PROJECT_DIR would point
# the hooks at the real project; XDG dirs go to a scratch area too.
private def with_clean_env(&)
  saved = {"CLAUDE_PROJECT_DIR", "XDG_STATE_HOME", "XDG_RUNTIME_DIR"}.to_h { |k| {k, ENV[k]?} }
  scratch = File.tempname("arcana-hook-env")
  Dir.mkdir_p(scratch)
  ENV.delete("CLAUDE_PROJECT_DIR")
  ENV["XDG_STATE_HOME"] = File.join(scratch, "state")
  ENV["XDG_RUNTIME_DIR"] = File.join(scratch, "run")
  Dir.mkdir_p(File.join(scratch, "run"))
  begin
    yield
  ensure
    saved.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
    FileUtils.rm_rf(scratch)
  end
end

private def project(config : String? = nil, &)
  dir = File.tempname("arcana-hook-proj")
  Dir.mkdir_p(File.join(dir, ".ai"))
  File.write(File.join(dir, ".ai", "config.yml"), config) if config
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def hook(port : Int32, dir : String, *args : String, payload = {} of String => JSON::Any) : {Int32, String, String}
  input = IO::Memory.new(payload.merge({"cwd" => JSON::Any.new(dir)}).to_json)
  output = IO::Memory.new
  error = IO::Memory.new
  code = Arcana::Hook.run(args.to_a, input, output, error, base_url: "http://127.0.0.1:#{port}")
  {code, output.to_s, error.to_s}
end

private def with_bus(port : Int32, &)
  dir = Arcana::Directory.new
  server = Arcana::Server.new(Arcana::Bus.new, dir, port: port)
  server.start_in_background
  begin
    yield dir
  ensure
    server.stop
  end
end

private def send_mail(port : Int32, to : String, subject : String, payload)
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  HTTP::Client.post("http://127.0.0.1:#{port}/register", headers: headers,
    body: {address: "@sender", kind: "agent"}.to_json)
  HTTP::Client.post("http://127.0.0.1:#{port}/send", headers: headers,
    body: {from: "@sender", to: to, subject: subject, payload: payload}.to_json)
end

CONFIG = %(arcana:\n  handle: "@proj"\n  description: >\n    The project's agent.\n)

describe Arcana::AgentConfig do
  it "reads handle and description from .ai/config.yml" do
    project(CONFIG) do |dir|
      cfg = Arcana::AgentConfig.load(dir)
      cfg.handle.should eq("@proj")
      cfg.description.should eq("The project's agent.")
    end
  end

  it "adds the @ to an unquoted handle" do
    project("arcana:\n  handle: proj\n") { |dir| Arcana::AgentConfig.load(dir).handle.should eq("@proj") }
  end

  it "falls back to @ plus a legal form of the directory name" do
    Arcana::AgentConfig.fallback_handle("/x/Silicon.Circus").should eq("@silicon-circus")
    Arcana::AgentConfig.fallback_handle("/x/2048").should eq("@agent-2048")
    project { |dir| Arcana::AgentConfig.load(dir).handle.should eq(Arcana::AgentConfig.fallback_handle(dir)) }
  end

  it "raises on a config it can't parse instead of falling back" do
    project("arcana: [unclosed\n") do |dir|
      expect_raises(Arcana::AgentConfig::Error, /can't read/) { Arcana::AgentConfig.load(dir) }
    end
  end

  it "makes the owner token once, private, and excluded from git" do
    with_clean_env do
      project(CONFIG) do |dir|
        Process.run("git", ["init", "-q", dir])
        cfg = Arcana::AgentConfig.load(dir)
        token = cfg.owner_token!
        cfg.token_path.should eq(File.join(dir, ".ai", "arcana.token"))
        cfg.owner_token!.should eq(token)
        (File.info(cfg.token_path).permissions.value & 0o077).should eq(0)
        File.read(File.join(dir, ".git", "info", "exclude")).should contain("**/.ai/arcana.token")

        status = IO::Memory.new
        Process.run("git", ["status", "--porcelain", "--untracked-files=all"], chdir: dir, output: status)
        status.to_s.should_not contain("arcana.token")
      end
    end
  end

  it "moves the XDG-state token into .ai/ when the project gains one" do
    with_clean_env do
      dir = File.tempname("arcana-later-ai")
      Dir.mkdir_p(dir)
      Process.run("git", ["init", "-q", dir])
      begin
        before = Arcana::AgentConfig.load(dir)
        token = before.owner_token!
        old_path = before.token_path

        Dir.mkdir_p(File.join(dir, ".ai"))
        after = Arcana::AgentConfig.load(dir)
        after.owner_token.should eq(token)
        after.owner_token!.should eq(token)
        File.exists?(old_path).should be_false
        (File.info(after.token_path).permissions.value & 0o077).should eq(0)
        File.read(File.join(dir, ".git", "info", "exclude")).should contain("**/.ai/arcana.token")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  it "keeps the token under XDG state for a project without .ai/" do
    with_clean_env do
      dir = File.tempname("arcana-noai")
      Dir.mkdir_p(dir)
      begin
        cfg = Arcana::AgentConfig.load(dir)
        cfg.owner_token!
        cfg.token_path.should start_with(ENV["XDG_STATE_HOME"])
        Dir.exists?(File.join(dir, ".ai")).should be_false
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end

describe Arcana::Hook do
  it "session-start registers the handle and tells the agent it's theirs" do
    with_clean_env do
      with_bus(14610) do |directory|
        project(CONFIG) do |dir|
          code, stdout, _ = hook(14610, dir, "session-start", "--agent", "claude")
          code.should eq(0)
          context = JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
          context.should contain("You are @proj on the Arcana bus")
          context.should contain("the session-start hook registered it")
          directory.lookup("@proj").not_nil!.description.should eq("The project's agent.")

          # The next session finds it already theirs.
          _, stdout, _ = hook(14610, dir, "session-start", "--agent", "codex")
          JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s.should contain("already registered under this project's owner token")
        end
      end
    end
  end

  it "session-start says so when another owner holds the handle" do
    with_clean_env do
      with_bus(14611) do |directory|
        directory.claim(Arcana::Directory::Listing.new(address: "@proj", name: "@proj", description: "someone"), "other")
        project(CONFIG) do |dir|
          _, stdout, _ = hook(14611, dir, "session-start")
          context = JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
          context.should contain("held under a different owner token")
          context.should contain(%("someone"))
        end
      end
    end
  end

  it "stays silent when the bus isn't running" do
    with_clean_env do
      project(CONFIG) do |dir|
        hook(14619, dir, "session-start").should eq({0, "", ""})
      end
    end
  end

  it "stop asks a Claude agent to read mail once per count" do
    with_clean_env do
      with_bus(14612) do
        project(CONFIG) do |dir|
          hook(14612, dir, "session-start")
          hook(14612, dir, "stop", "--agent", "claude")[0].should eq(0)

          send_mail(14612, "@proj", "hi", {text: "hello"})
          code, _, err = hook(14612, dir, "stop", "--agent", "claude")
          code.should eq(2)
          err.should contain("You have mail! (1 message)")
          hook(14612, dir, "stop", "--agent", "claude")[0].should eq(0)
        end
      end
    end
  end

  it "stop blocks a Codex agent unless it is already continuing" do
    with_clean_env do
      with_bus(14613) do
        project(CONFIG) do |dir|
          hook(14613, dir, "session-start")
          send_mail(14613, "@proj", "hi", {text: "hello"})
          _, stdout, _ = hook(14613, dir, "stop", "--agent", "codex")
          JSON.parse(stdout)["decision"].should eq("block")
          _, stdout, _ = hook(14613, dir, "stop", "--agent", "codex", payload: {"stop_hook_active" => JSON::Any.new(true)})
          stdout.strip.should eq("{}")
        end
      end
    end
  end

  it "session-end moves unread mail to .ai/inbox and marks the handle offline" do
    with_clean_env do
      with_bus(14614) do |directory|
        project(CONFIG) do |dir|
          hook(14614, dir, "session-start")
          send_mail(14614, "@proj", "Release notes", {text: "Shipped 0.32.", reply_to: "@sender"})

          hook(14614, dir, "session-end", "--agent", "claude")[0].should eq(0)

          notes = Dir.glob(File.join(dir, ".ai", "inbox", "*.md"))
          notes.size.should eq(1)
          File.basename(notes[0]).should contain("-arcana-sender-")
          note = File.read(notes[0])
          note.should start_with("# Release notes\n")
          note.should contain("- **From:** @sender")
          note.should contain("Shipped 0.32.")
          note.should contain(%("reply_to": "@sender"))

          directory.online?("@proj").should be_false
          directory.lookup("@proj").should_not be_nil # still registered: mail can wait
        end
      end
    end
  end

  it "session-end leaves everything alone on /clear" do
    with_clean_env do
      with_bus(14615) do |directory|
        project(CONFIG) do |dir|
          hook(14615, dir, "session-start")
          send_mail(14615, "@proj", "hi", {text: "hello"})
          hook(14615, dir, "session-end", payload: {"reason" => JSON::Any.new("clear")})
          Dir.glob(File.join(dir, ".ai", "inbox", "*.md")).should be_empty
          directory.online?("@proj").should be_true
        end
      end
    end
  end
end
