require "./spec_helper"
require "http/client"
require "http/web_socket"

private def request(headers : Hash(String, String)) : HTTP::Request
  HTTP::Request.new("POST", "/deliver", HTTP::Headers.new.tap { |h| headers.each { |k, v| h[k] = v } })
end

describe Arcana::LocalGuard do
  guard = Arcana::LocalGuard.new("127.0.0.1")

  it "passes programs, which send no Origin and name the address they connected to" do
    {"127.0.0.1:19118", "localhost:19118", "localhost", "[::1]:19118", "127.0.0.2"}.each do |host|
      guard.refusal(request({"Host" => host})).should be_nil
    end
  end

  it "passes a page on this machine" do
    {"http://localhost:3000", "http://127.0.0.1:19118", "http://[::1]:8080", "http://app.localhost"}.each do |origin|
      guard.refusal(request({"Host" => "127.0.0.1:19118", "Origin" => origin})).should be_nil
    end
  end

  it "refuses a page from another site, or one with no site" do
    {"https://evil.example", "null", "http://192.168.1.10:8000"}.each do |origin|
      guard.refusal(request({"Host" => "127.0.0.1:19118", "Origin" => origin})).not_nil!.should contain("a web page's request")
    end
  end

  it "refuses a request for another host, as DNS rebinding sends" do
    guard.refusal(request({"Host" => "evil.example:19118"})).not_nil!.should contain("another host")
    guard.refusal(request({} of String => String)).not_nil!.should contain("missing")
  end

  it "takes the names it's told are this machine's" do
    named = Arcana::LocalGuard.new("127.0.0.1", ["arcana.internal"])
    named.refusal(request({"Host" => "arcana.internal:19118", "Origin" => "https://ARCANA.internal"})).should be_nil
    named.refusal(request({"Host" => "evil.example"})).should_not be_nil
  end

  it "doesn't check Host when bound to every interface with no names given, but still checks Origin" do
    open = Arcana::LocalGuard.new("0.0.0.0")
    open.refusal(request({"Host" => "bus.example.net:19118"})).should be_nil
    open.refusal(request({"Host" => "bus.example.net", "Origin" => "https://evil.example"})).should_not be_nil
  end

  it "keeps a web page's WebSocket and REST requests off the server" do
    server = Arcana::Server.new(Arcana::Bus.new, Arcana::Directory.new, host: "127.0.0.1", port: 14004)
    server.start_in_background
    begin
      foreign = HTTP::Headers{"Origin" => "https://evil.example", "Content-Type" => "text/plain"}
      resp = HTTP::Client.post("http://127.0.0.1:14004/inbox", headers: foreign, body: %({"address":"@x"}))
      resp.status_code.should eq(403)
      JSON.parse(resp.body)["error"].as_s.should contain("only from programs on this machine")

      expect_raises(Exception) do
        HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:14004/bus"), headers: HTTP::Headers{"Origin" => "https://evil.example"})
      end

      HTTP::Client.get("http://127.0.0.1:14004/health").status_code.should eq(200)
      ws = HTTP::WebSocket.new(URI.parse("ws://127.0.0.1:14004/bus"))
      ws.close
    ensure
      server.stop
    end
  end
end
