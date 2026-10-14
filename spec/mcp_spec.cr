require "./spec_helper"
require "file_utils"

# Expose handle_message for testing.
class Arcana::MCP
  def test_handle(msg : JSON::Any) : JSON::Any?
    handle_message(msg)
  end
end

describe Arcana::MCP do
  it "has the expected tools defined" do
    tools = Arcana::MCP::TOOLS
    names = tools.map { |t| t[:name] }
    names.should contain("arcana_directory")
    names.should contain("arcana_deliver")
    names.should contain("arcana_publish")
    names.should contain("arcana_register")
    names.should contain("arcana_inbox")
    names.should contain("arcana_receive")
    names.should contain("arcana_expect")
    names.should contain("arcana_freeze")
    names.should contain("arcana_health")
  end

  it "handles initialize message" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"test"}}}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    result = response.not_nil!["result"]
    result["protocolVersion"].as_s.should eq("2024-11-05")
    result["serverInfo"]["name"].as_s.should eq("arcana")
  end

  it "handles tools/list message" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":2,"method":"tools/list"}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    tools = response.not_nil!["result"]["tools"].as_a
    tools.size.should eq(10)
  end

  it "returns nil for notifications" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","method":"notifications/initialized"}))
    response = mcp.test_handle(msg)
    response.should be_nil
  end

  it "returns error for unknown methods" do
    mcp = Arcana::MCP.new
    msg = JSON.parse(%({"jsonrpc":"2.0","id":99,"method":"unknown/method"}))
    response = mcp.test_handle(msg)
    response.should_not be_nil
    response.not_nil!["error"]["code"].as_i.should eq(-32601)
  end
  it "reconnects when the daemon drops its connection" do
    # Answers each request, then closes the socket without saying so, as
    # a daemon that restarts does to a kept-alive connection.
    tcp = TCPServer.new("127.0.0.1", 0)
    spawn do
      while client = tcp.accept?
        if HTTP::Request.from_io(client).is_a?(HTTP::Request)
          client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]"
          client.flush
        end
        client.close
      end
    end
    # A POST: HTTP::Client retries a GET on a stale connection by itself.
    inbox = JSON.parse(%({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"arcana_inbox","arguments":{"address":"@t"}}}))
    mcp = Arcana::MCP.new(base_url: "http://127.0.0.1:#{tcp.local_address.port}", project_dir: Dir.tempdir)
    begin
      3.times { mcp.test_handle(inbox).to_json.should_not contain("error") }
    ensure
      tcp.close
    end
  end

  describe "arcana_receive" do
    # A daemon whose /receive hands over mail from an agent, a topic's
    # notice and a service's reply.
    messages = [
      {from: "@ipck", to: "@proj", subject: "Inbox files", timestamp: "2026-10-14T05:39:00Z",
       correlation_id: "6a33907c1d4519a7", payload: {text: "Could receive write them?"}},
      {from: "#news", to: "@proj", subject: "post 3", timestamp: "2026-10-14T05:40:00Z",
       correlation_id: "1111111111111111", payload: {topic: "#news", seq: 3}},
      {from: "openai", to: "@proj", timestamp: "2026-10-14T05:41:00Z",
       correlation_id: "2222222222222222", payload: {text: "a chat reply"}},
    ].to_json

    receive = ->(address : String) {
      JSON.parse({jsonrpc: "2.0", id: 1, method: "tools/call",
                  params: {name: "arcana_receive", arguments: {address: address}}}.to_json)
    }

    with_project = ->(inbox : Bool, block : Proc(Arcana::MCP, String, Nil)) {
      tcp = TCPServer.new("127.0.0.1", 0)
      spawn do
        while client = tcp.accept?
          if HTTP::Request.from_io(client).is_a?(HTTP::Request)
            client << "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{messages.bytesize}\r\n\r\n#{messages}"
            client.flush
          end
          client.close
        end
      end
      dir = File.tempname("arcana-mcp-proj")
      Dir.mkdir_p(File.join(dir, ".ai"))
      File.write(File.join(dir, ".ai", "config.yml"), "handle: proj\n")
      Dir.mkdir_p(File.join(dir, ".ai", "mail", "inbox")) if inbox
      begin
        block.call(Arcana::MCP.new(base_url: "http://127.0.0.1:#{tcp.local_address.port}", project_dir: dir), dir)
      ensure
        tcp.close
        FileUtils.rm_rf(dir)
      end
    }

    it "writes mail from agents into the project's inbox and names the file" do
      with_project.call(true, ->(mcp : Arcana::MCP, dir : String) {
        result = JSON.parse(mcp.test_handle(receive.call("@proj")).not_nil!["result"]["content"][0]["text"].as_s).as_a
        path = result[0]["inbox_file"].as_s
        File.basename(path).should eq("20261014-053900Z-@ipck--inbox-files-6a33907c.md")
        File.read(path).should eq("From: @ipck\nTo: @proj\nSent: 2026-10-14T05:39:00Z\nSubject: Inbox files\n" \
                                  "Id: 6a33907c1d4519a7\nVia: arcana\n\nCould receive write them?\n")
        result[1]["inbox_file"]?.should be_nil # a topic's notice isn't mail
        result[2]["inbox_file"]?.should be_nil # nor is a service's reply
        Dir.children(File.join(dir, ".ai", "mail", "inbox")).should eq([File.basename(path)])
        nil
      })
    end

    it "writes nothing for another address, or without an inbox folder" do
      with_project.call(true, ->(mcp : Arcana::MCP, dir : String) {
        mcp.test_handle(receive.call("@other")).to_json.should_not contain("inbox_file")
        Dir.children(File.join(dir, ".ai", "mail", "inbox")).should be_empty
        nil
      })
      with_project.call(false, ->(mcp : Arcana::MCP, dir : String) {
        mcp.test_handle(receive.call("@proj")).to_json.should_not contain("inbox_file")
        Dir.exists?(File.join(dir, ".ai", "mail")).should be_false
        nil
      })
    end
  end
end
