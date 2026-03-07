require "./spec_helper"
require "http/client"

describe Arcana::Server do
  it "serves REST directory endpoints" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new

    dir.register(Arcana::Directory::Listing.new(
      address: "test-agent",
      name: "Test Agent",
      description: "A test agent",
      kind: Arcana::Directory::Kind::Agent,
      tags: ["test"],
    ))

    server = Arcana::Server.new(bus, dir, port: 14000)
    server.start_in_background

    begin
      # GET /health
      resp = HTTP::Client.get("http://127.0.0.1:14000/health")
      resp.status_code.should eq(200)
      health = JSON.parse(resp.body)
      health["status"].as_s.should eq("ok")

      # GET /directory
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory")
      resp.status_code.should eq(200)
      listings = JSON.parse(resp.body).as_a
      listings.size.should eq(1)
      listings[0]["address"].as_s.should eq("test-agent")

      # GET /directory?tag=test
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?tag=test")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory?q=test
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?q=test")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory?kind=agent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory?kind=agent")
      JSON.parse(resp.body).as_a.size.should eq(1)

      # GET /directory/test-agent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory/test-agent")
      resp.status_code.should eq(200)
      JSON.parse(resp.body)["name"].as_s.should eq("Test Agent")

      # GET /directory/nonexistent
      resp = HTTP::Client.get("http://127.0.0.1:14000/directory/nonexistent")
      resp.status_code.should eq(404)

      # GET /unknown
      resp = HTTP::Client.get("http://127.0.0.1:14000/unknown")
      resp.status_code.should eq(404)
    ensure
      server.stop
    end
  end
end
