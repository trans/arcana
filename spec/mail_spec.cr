require "./spec_helper"
require "file_utils"

# Arcana as a machine's mail carrier. dot.ai's tests check what it shares
# with dot-ai (`CARRIER=arcana just test` there); these check what only
# Arcana does: mail beyond this machine's projects over the bus, the
# bridge staying out of mail under another carrier, naming dot-ai's
# commands only where it's installed, and a session following its
# project to a new handle.

# A machine: git config with `ai.path` and the carrier, projects under it,
# and no dot-ai (`dot_ai` adds one).
private def machine(carrier : String?, &)
  root = File.tempname("arcana-mail-spec")
  projects = File.join(root, "projects")
  Dir.mkdir_p(projects)
  config = File.join(root, "gitconfig")
  File.write(config, "[ai]\n\tpath = #{projects}\n#{carrier ? "\tcarrier = #{carrier}\n" : ""}")
  saved = {"GIT_CONFIG_GLOBAL", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "CLAUDE_PROJECT_DIR", "ARCANA_URL",
           "CLAUDE_CONFIG_DIR", "CODEX_HOME", "PATH"}.to_h { |k| {k, ENV[k]?} }
  ENV["GIT_CONFIG_GLOBAL"] = config
  ENV["XDG_RUNTIME_DIR"] = File.join(root, "run")
  ENV["XDG_STATE_HOME"] = File.join(root, "state")
  ENV["CLAUDE_CONFIG_DIR"] = File.join(root, "claude")
  ENV["CODEX_HOME"] = File.join(root, "codex")
  ENV["PATH"] = (ENV["PATH"]? || "").split(':').reject { |d| File.exists?(File.join(d, "dot-ai")) }.join(':')
  ENV.delete("CLAUDE_PROJECT_DIR")
  ENV.delete("ARCANA_URL")
  Dir.mkdir_p(File.join(root, "run"))
  begin
    yield projects
  ensure
    saved.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
    FileUtils.rm_rf(root)
  end
end

# dot-ai's command as the plugin installs it, under `home`'s cache
private def dot_ai(projects : String, home : String, version : String, script : String = "dot-ai") : String
  dir = File.join(File.dirname(projects), home, "plugins", "cache", "dot-ai", "dot-ai", version, "skills", "dot-ai", "scripts")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, script), "echo dot-ai #{version}\n")
  File.join(dir, script)
end

private def mail_project(projects : String, name : String) : String
  dir = File.join(projects, name)
  %w(inbox outbox sent received).each { |d| Dir.mkdir_p(File.join(dir, ".ai", "mail", d)) }
  File.write(File.join(dir, ".ai", "config.yml"), "handle: #{name}\n")
  dir
end

private def bus_on(port : Int32, &)
  bus = Arcana::Bus.new
  directory = Arcana::Directory.new
  bus.directory = directory
  server = Arcana::Server.new(bus, directory, host: "127.0.0.1", port: port)
  server.start_in_background
  begin
    yield bus, directory
  ensure
    server.stop
  end
end

private def agent(directory : Arcana::Directory, address : String) : Nil
  directory.register(Arcana::Directory::Listing.new(address: address, name: address, description: "",
    kind: Arcana::Directory::Kind::Agent))
end

private def tool(mcp : Arcana::MCP, name : String, args : String) : JSON::Any
  msg = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"#{name}","arguments":#{args}}}))
  JSON.parse(mcp.test_handle(msg).not_nil!["result"]["content"][0]["text"].as_s)
end

class Arcana::MCP
  def test_handle(msg : JSON::Any) : JSON::Any?
    handle_message(msg)
  end
end

describe Arcana::Mail do
  it "reads the carrier from git config, local by default" do
    machine(nil) { Arcana::Mail.carrier.should eq("local"); Arcana::Mail.carrier?.should be_false }
    machine("arcana") { Arcana::Mail.carrier?.should be_true }
  end

  it "sends mail for an address no project here has over the bus, from the project's handle" do
    machine("arcana") do |projects|
      alpha = mail_project(projects, "alpha")
      File.write(File.join(alpha, ".ai", "mail", "outbox", "20261029-120000Z-@far--hello.md"), "Re: 0123abcd\n\nHello there.\n")
      bus_on(14970) do |bus, directory|
        agent(directory, "@alpha")
        agent(directory, "@far")
        bus.mailbox("@alpha")
        far = bus.mailbox("@far")
        ENV["ARCANA_URL"] = "http://127.0.0.1:14970"
        said = IO::Memory.new
        Arcana::Mail.deliver(alpha, said)
        said.to_s.should eq("delivered: 20261029-120000Z-@far--hello.md to @far over the Arcana bus\n")

        got = far.receive(1.second).not_nil!
        got.from.should eq("@alpha")
        got.subject.should eq("hello")
        got.re.should eq("0123abcd")
        got.payload["text"].as_s.should eq("Hello there.\n")
        got.id.should eq(Arcana::Mail.message_id("@alpha", "20261029-120000Z-@far--hello.md", "Hello there.\n"))

        sent = File.read(File.join(alpha, ".ai", "mail", "sent", "20261029-120000Z-@far--hello.md"))
        sent.should contain("via arcana\nId: #{got.id}\n")
        Dir.children(File.join(alpha, ".ai", "mail", "outbox")).should be_empty # and no .receipts
      end
    end
  end

  it "leaves mail the bus can't take in the outbox, saying why" do
    machine("arcana") do |projects|
      alpha = mail_project(projects, "alpha")
      File.write(File.join(alpha, ".ai", "mail", "outbox", "20261029-120000Z-@nowhere--x.md"), "x\n")
      ENV["ARCANA_URL"] = "http://127.0.0.1:9"
      said = IO::Memory.new
      Arcana::Mail.deliver(alpha, said)
      said.to_s.should eq("left in the outbox: 20261029-120000Z-@nowhere--x.md: no project on this machine " \
                          "has the address @nowhere, and the Arcana bus can't be reached\n")

      bus_on(14971) do |bus, directory|
        agent(directory, "@alpha")
        bus.mailbox("@alpha")
        ENV["ARCANA_URL"] = "http://127.0.0.1:14971"
        said = IO::Memory.new
        Arcana::Mail.deliver(alpha, said)
        said.to_s.should start_with("left in the outbox: 20261029-120000Z-@nowhere--x.md: no project on this " \
                                    "machine has the address @nowhere, and the Arcana bus says: ")
      end
    end
  end
end

describe "Arcana::Mail.dot_ai" do
  it "is dot-ai on the PATH, else the newest plugin copy for Claude Code or Codex, else none" do
    machine(nil) do |projects|
      Arcana::Mail.dot_ai.should be_nil
      Arcana::Mail.dot_ai?.should be_false

      # dot-ai-mail alone (before 0.5) is dot-ai, but not one to name
      dot_ai(projects, "claude", "0.4.2", "dot-ai-mail")
      Arcana::Mail.dot_ai.should be_nil
      Arcana::Mail.dot_ai?.should be_true

      dot_ai(projects, "claude", "0.9.0")
      newest = dot_ai(projects, "codex", "0.10.0")
      Arcana::Mail.dot_ai.should eq(%(sh "#{newest}"))

      bin = File.join(File.dirname(projects), "bin")
      Dir.mkdir_p(bin)
      File.write(File.join(bin, "dot-ai"), "#!/bin/sh\n")
      File.chmod(File.join(bin, "dot-ai"), 0o755)
      ENV["PATH"] = "#{bin}:#{ENV["PATH"]}"
      Arcana::Mail.dot_ai.should eq("dot-ai")
    end
  end

  it "names dot-ai's commands in what the hooks say where it's installed, and Arcana's where it isn't" do
    machine("arcana") do |projects|
      alpha = mail_project(projects, "alpha")
      Dir.mkdir_p(File.join(projects, ".ai", "topics"))
      outbox = File.join(alpha, ".ai", "mail", "outbox")
      inbox = File.join(alpha, ".ai", "mail", "inbox")
      File.write(File.join(inbox, "20261030-120000Z-@beta--hi-0123abcd.md"), "From: @beta\n\nhi\n")

      File.write(File.join(outbox, "20261030-120000Z-#nope--x.md"), "x\n")
      said = Arcana::Mail::Notices.collect("session-start", alpha, "s1")
      said.should contain("there's no topic #nope (arcana mail topic makes one)")
      said.should contain("once each is handled, move it to .ai/mail/received/")

      script = dot_ai(projects, "claude", "0.5.1")
      said = Arcana::Mail::Notices.collect("session-start", alpha, "s1")
      said.should contain("there's no topic #nope (dot-ai mail topic makes one)")
      said.should contain(%(as the dot-ai skill says (Processing the inbox), filing each with: sh "#{script}" mail done NAME))
    end
  end
end

describe "Arcana::MCP under a carrier" do
  it "refuses mail to a project here and posts to topics where dot-ai carries mail" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      mail_project(projects, "beta")
      script = dot_ai(projects, "claude", "0.5.1")
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: alpha)
      tool(mcp, "arcana_deliver", %({"to":"@beta","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should eq("Not sent: @beta is a project on this machine, and this machine's mail carrier is local, " \
                   "the default (git config ai.carrier sets another), so mail to it goes through your project's outbox: send it with " \
                   "sh \"#{script}\" mail send @beta TOPIC, the message on standard input, as the dot-ai skill says (Sending).")
      tool(mcp, "arcana_publish", %({"topic":"#news","payload":{"text":"hello"}}))["error"].as_s
        .should start_with("Not posted: this machine's mail carrier is local")
      # Agents found only on the bus, and services, still go (here, to a bus that's down)
      tool(mcp, "arcana_deliver", %({"to":"@far","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not sent")
      tool(mcp, "arcana_deliver", %({"to":"openai","payload":{"tool":"help"}}))["error"].as_s
        .should_not start_with("Not sent")
    end
  end

  it "carries all mail itself on a machine without dot-ai, whatever the carrier says" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      mail_project(projects, "beta")
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: alpha)
      tool(mcp, "arcana_deliver", %({"to":"@beta","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not sent")
      tool(mcp, "arcana_publish", %({"topic":"#news","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not posted")
    end
  end

  it "says in the tools' descriptions, first, what they refuse" do
    describe_tool = ->(mcp : Arcana::MCP, name : String) do
      mcp.tools.as_a.find! { |t| t["name"] == name }["description"].as_s
    end
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      script = dot_ai(projects, "claude", "0.5.1")
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: alpha)
      describe_tool.call(mcp, "arcana_deliver").should start_with("Not for mail to another project on this machine")
      describe_tool.call(mcp, "arcana_deliver").should contain(%(`sh "#{script}" mail send @handle TOPIC`))
      describe_tool.call(mcp, "arcana_publish").should start_with("Not for `#topics`")
      describe_tool.call(mcp, "arcana_inbox").should_not contain("Not for")
    end
    machine("arcana") do |projects|
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: mail_project(projects, "alpha"))
      describe_tool.call(mcp, "arcana_deliver").should start_with("Send a message on the Arcana bus")
      describe_tool.call(mcp, "arcana_publish").should start_with("A `#topic` kept as files on this machine")
      describe_tool.call(mcp, "arcana_publish").should contain("write it into `.ai/mail/outbox/`")
    end
    machine(nil) do |projects| # no dot-ai: the tools carry everything
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: mail_project(projects, "alpha"))
      describe_tool.call(mcp, "arcana_deliver").should start_with("Send a message on the Arcana bus")
      describe_tool.call(mcp, "arcana_publish").should start_with("Post to a topic on the Arcana bus")
    end
  end

  it "sends to a project where Arcana carries mail, but posts to a file topic through the outbox" do
    machine("arcana") do |projects|
      alpha = mail_project(projects, "alpha")
      mail_project(projects, "beta")
      Dir.mkdir_p(File.join(projects, ".ai", "topics", "news"))
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: alpha)
      tool(mcp, "arcana_deliver", %({"to":"@beta","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not sent")
      tool(mcp, "arcana_publish", %({"topic":"#news","payload":{"text":"hello"}}))["error"].as_s
        .should start_with("Not posted: #news is a topic kept as files on this machine")
      tool(mcp, "arcana_publish", %({"topic":"#elsewhere","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not posted")
    end
  end
end

describe "Arcana::Hook following a session's project" do
  it "registers the project's own handle once a new .ai/ appears above where the session started" do
    machine(nil) do |projects|
      outer = mail_project(projects, "outer")
      inner = File.join(outer, "inner")
      Dir.mkdir_p(inner)
      bus_on(14972) do |_, directory|
        run = ->(event : String) do
          input = IO::Memory.new({session_id: "s1", cwd: inner}.to_json)
          output = IO::Memory.new
          error = IO::Memory.new
          code = Arcana::Hook.run([event, "--agent", "claude"], input, output, error, base_url: "http://127.0.0.1:14972")
          {code, output.to_s, error.to_s}
        end

        run.call("session-start")[1].should contain("You are @outer on the Arcana bus")
        run.call("prompt")[1].should eq("") # nothing changed

        Dir.mkdir_p(File.join(inner, ".ai"))
        File.write(File.join(inner, ".ai", "config.yml"), "handle: inner\n")
        _, stdout, _ = run.call("prompt")
        context = JSON.parse(stdout)["hookSpecificOutput"]["additionalContext"].as_s
        context.should contain("whose handle is @inner, so the hook registered it: you are @inner on the Arcana bus now, not @outer")
        directory.lookup("@inner").should_not be_nil
        File.exists?(File.join(inner, ".ai", "arcana.token")).should be_true

        # Once: not at the next prompt, nor at Stop
        run.call("prompt")[1].should eq("")
        run.call("stop")[0].should eq(0)
      end
    end
  end

  it "registers the handle at the next prompt when the bus was down at session start" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      run = ->(event : String, port : Int32) do
        input = IO::Memory.new({session_id: "s2", cwd: alpha}.to_json)
        output = IO::Memory.new
        Arcana::Hook.run([event, "--agent", "claude"], input, output, IO::Memory.new, base_url: "http://127.0.0.1:#{port}")
        output.to_s
      end

      run.call("session-start", 9).should eq("")
      bus_on(14973) do |_, directory|
        context = JSON.parse(run.call("prompt", 14973))["hookSpecificOutput"]["additionalContext"].as_s
        context.should start_with("You are @alpha on the Arcana bus now: the hook registered this session's project")
        directory.lookup("@alpha").should_not be_nil
        run.call("prompt", 14973).should eq("") # once
      end
    end
  end
end

describe "Arcana::Hook at session end" do
  it "leaves mail on the bus in a project with no config, where no agent would read the files" do
    machine(nil) do |projects|
      bare = File.join(projects, "bare")
      Dir.mkdir_p(File.join(bare, ".ai"))
      staffed = mail_project(projects, "staffed")
      bus_on(14974) do |bus, _|
        {bare, staffed}.each do |dir|
          name = File.basename(dir)
          run = ->(event : String) do
            input = IO::Memory.new({session_id: "s-#{name}", cwd: dir}.to_json)
            Arcana::Hook.run([event, "--agent", "claude"], input, IO::Memory.new, IO::Memory.new, base_url: "http://127.0.0.1:14974")
          end
          run.call("session-start")
          bus.mailbox("@#{name}").deliver(Arcana::Envelope.new(from: "@alpha", to: "@#{name}", subject: "hello"))
          run.call("session-end")
        end

        Dir.exists?(File.join(bare, ".ai", "mail")).should be_false
        bus.mailbox("@bare").pending.should eq(1)
        Dir.children(File.join(staffed, ".ai", "mail", "inbox")).size.should eq(1)
        bus.mailbox("@staffed").pending.should eq(0)
      end
    end
  end
end

describe "Arcana::Mail's per-person settings" do
  it "reads ai.carrier and ai.path from the person's own git config, never a repository's, and warns of one" do
    machine("arcana") do |projects|
      alpha = mail_project(projects, "alpha")
      Process.run("git", ["init", "-q", alpha])
      Process.run("git", ["-C", alpha, "config", "ai.carrier", "local"])
      Process.run("git", ["-C", alpha, "config", "ai.path", "/nowhere"])
      Dir.cd(alpha) do
        Arcana::Mail.carrier?.should be_true
        Arcana::Mail.ai_paths.should eq([projects])
      end
      top = File.realpath(alpha)
      Arcana::Mail.repo_settings(alpha).should eq([
        "#{top} sets ai.carrier in its own git config, which is ignored: it's per person (git config --global ai.carrier)",
        "#{top} sets ai.path in its own git config, which is ignored: it's per person (git config --global ai.path)",
      ])
      Arcana::Mail.repo_settings(projects).should be_empty # not a repository
    end
  end
end

describe "Arcana under another carrier" do
  it "writes no mail files: the bridge's messages just come back, and nothing is filed as sent" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      dot_ai(projects, "claude", "0.9.0")
      Arcana::Mail.carries?.should be_false
      bus_on(14975) do |bus, directory|
        agent(directory, "@alpha")
        agent(directory, "@far")
        bus.mailbox("@alpha").deliver(Arcana::Envelope.new(from: "@far", to: "@alpha", subject: "hello",
          payload: JSON.parse(%({"text":"hi"}))))
        bus.mailbox("@far")
        mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:14975", project_dir: alpha)
        got = JSON.parse(mcp.test_handle(JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"arcana_receive","arguments":{"address":"@alpha"}}}))).not_nil!["result"]["content"][0]["text"].as_s)
        got.as_a.size.should eq(1)
        got[0]["inbox_file"]?.should be_nil
        sent = tool(mcp, "arcana_deliver", %({"to":"@far","subject":"back","payload":{"text":"hello"}}))
        sent["id"]?.should_not be_nil
        sent["sent_file"]?.should be_nil
        Dir.children(File.join(alpha, ".ai", "mail", "inbox")).should be_empty
        Dir.children(File.join(alpha, ".ai", "mail", "sent")).should be_empty
      end
    end
  end

  it "leaves mail on the bus at a session's end and Stop, and says at Stop how much waits there" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      dot_ai(projects, "claude", "0.9.0")
      bus_on(14976) do |bus, _|
        run = ->(event : String) do
          input = IO::Memory.new({session_id: "s-other", cwd: alpha}.to_json)
          error = IO::Memory.new
          code = Arcana::Hook.run([event, "--agent", "claude"], input, IO::Memory.new, error, base_url: "http://127.0.0.1:14976")
          {code, error.to_s}
        end
        run.call("session-start")
        bus.mailbox("@alpha").deliver(Arcana::Envelope.new(from: "@far", to: "@alpha", subject: "hello"))
        code, said = run.call("stop")
        code.should eq(2)
        said.should contain("1 message on the Arcana bus for @alpha")
        run.call("session-end")
        Dir.children(File.join(alpha, ".ai", "mail", "inbox")).should be_empty
        bus.mailbox("@alpha").pending.should eq(1)
        Dir.exists?(Arcana::Mail::Sessions.dir).should be_false # and no session records
      end
    end
  end
end

describe Arcana::Mail::Sessions do
  it "answers arcana tell: 3 with no record or a session not open (marking it ended), 0 busy, 4 idle" do
    machine("arcana") do |projects|
      root = File.realpath(mail_project(projects, "alpha"))
      s = Arcana::Mail::Sessions
      s.own_tell("none").should eq(3)
      s.write(s.path("busy"), {"root" => root, "agent" => "codex", "id" => "busy", "by" => "arcana", "state" => "busy"})
      s.own_tell("busy").should eq(0)
      s.write(s.path("idle"), {"root" => root, "agent" => "codex", "id" => "idle", "by" => "arcana", "state" => "idle"})
      s.own_tell("idle").should eq(4)
      gone = Process.new("true")
      gone.wait
      s.write(s.path("gone"), {"root" => root, "agent" => "claude", "id" => "gone", "by" => "arcana", "pid" => gone.pid.to_s, "state" => "idle"})
      s.own_tell("gone").should eq(3)
      s.read(s.path("gone"))["state"].should eq("ended")
      File.info(s.dir).permissions.value.should eq(0o700)
    end
  end

  it "names the session's runner by DOT_AI_BY, a plain name, else arcana" do
    machine("arcana") do
      begin
        ENV["DOT_AI_BY"] = "aix"
        Arcana::Mail::Sessions.by.should eq("aix")
        ENV["DOT_AI_BY"] = "../bin/x"
        Arcana::Mail::Sessions.by.should eq("arcana")
      ensure
        ENV.delete("DOT_AI_BY")
      end
      Arcana::Mail::Sessions.by.should eq("arcana")
    end
  end
end
