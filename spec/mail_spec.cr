require "./spec_helper"
require "file_utils"

# Arcana as a machine's mail carrier. dot.ai's tests check what it shares
# with dot-ai-mail (`CARRIER=arcana just test` there); these check what
# only Arcana does: mail beyond this machine's projects over the bus, the
# bridge staying out of mail under another carrier, and a session
# following its project to a new handle.

# A machine: git config with `ai.path` and the carrier, projects under it.
private def machine(carrier : String?, &)
  root = File.tempname("arcana-mail-spec")
  projects = File.join(root, "projects")
  Dir.mkdir_p(projects)
  config = File.join(root, "gitconfig")
  File.write(config, "[ai]\n\tpath = #{projects}\n#{carrier ? "\tcarrier = #{carrier}\n" : ""}")
  saved = {"GIT_CONFIG_GLOBAL", "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "CLAUDE_PROJECT_DIR", "ARCANA_URL"}.to_h { |k| {k, ENV[k]?} }
  ENV["GIT_CONFIG_GLOBAL"] = config
  ENV["XDG_RUNTIME_DIR"] = File.join(root, "run")
  ENV["XDG_STATE_HOME"] = File.join(root, "state")
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

describe "Arcana::MCP under a carrier" do
  it "refuses mail to a project here and posts to topics where dot-ai-mail carries mail" do
    machine(nil) do |projects|
      alpha = mail_project(projects, "alpha")
      mail_project(projects, "beta")
      mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:9", project_dir: alpha)
      tool(mcp, "arcana_deliver", %({"to":"@beta","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should start_with("Not sent: @beta is a project on this machine, and this machine's mail carrier is local")
      tool(mcp, "arcana_publish", %({"topic":"#news","payload":{"text":"hello"}}))["error"].as_s
        .should start_with("Not posted: this machine's mail carrier is local")
      # Agents found only on the bus, and services, still go (here, to a bus that's down)
      tool(mcp, "arcana_deliver", %({"to":"@far","subject":"hi","payload":{"text":"hello"}}))["error"].as_s
        .should_not start_with("Not sent")
      tool(mcp, "arcana_deliver", %({"to":"openai","payload":{"tool":"help"}}))["error"].as_s
        .should_not start_with("Not sent")
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
end
