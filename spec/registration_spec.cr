require "./spec_helper"
require "http/client"

private HEADERS = HTTP::Headers{"Content-Type" => "application/json"}

private def post(port : Int32, path : String, body) : {Int32, JSON::Any}
  resp = HTTP::Client.post("http://127.0.0.1:#{port}#{path}", headers: HEADERS, body: body.to_json)
  {resp.status_code, JSON.parse(resp.body)}
end

private def with_server(port : Int32, &)
  dir = Arcana::Directory.new
  dir.agent_ttl = 7.days
  server = Arcana::Server.new(Arcana::Bus.new, dir, port: port)
  server.start_in_background
  begin
    yield
  ensure
    server.stop
  end
end

describe "POST /register with an owner token" do
  it "tells the holder its own registration from someone else's" do
    with_server(14600) do
      status, body = post(14600, "/register", {address: "@proj", kind: "agent", description: "Proj agent", owner_token: "mine"})
      status.should eq(200)
      body["status"].should eq("registered")
      body["listing"]["online"].should eq(true)
      body["listing"]["expires_at"].as_s.should_not be_empty

      # Same token: it's yours, and an omitted description is kept.
      status, body = post(14600, "/register", {address: "@proj", kind: "agent", owner_token: "mine"})
      status.should eq(200)
      body["status"].should eq("yours")
      body["listing"]["description"].should eq("Proj agent")

      # Different token: held by someone else, with the holder's listing.
      status, body = post(14600, "/register", {address: "@proj", kind: "agent", owner_token: "theirs"})
      status.should eq(409)
      body["held"].should eq(true)
      body["error"].as_s.should contain("held by another owner")
      body["listing"]["description"].should eq("Proj agent")
    end
  end

  it "doesn't let a failed registration replace the mailbox token" do
    with_server(14601) do
      post(14601, "/register", {address: "@proj", kind: "agent", token: "mbox", owner_token: "mine"})[0].should eq(200)
      status, _ = post(14601, "/register", {address: "@proj", kind: "agent", token: "stolen", owner_token: "theirs"})
      status.should_not eq(200)

      post(14601, "/receive", {address: "@proj", token: "mbox"})[0].should eq(200)
      post(14601, "/receive", {address: "@proj", token: "stolen"})[0].should eq(400)
    end
  end

  it "marks an agent offline with its owner token, and back online on register" do
    with_server(14602) do
      post(14602, "/register", {address: "@proj", kind: "agent", owner_token: "mine"})

      post(14602, "/presence", {address: "@proj", online: false, owner_token: "wrong"})[0].should eq(409)
      status, body = post(14602, "/presence", {address: "@proj", online: false, owner_token: "mine"})
      status.should eq(200)
      body["online"].should eq(false)
      JSON.parse(HTTP::Client.get("http://127.0.0.1:14602/directory/@proj").body)["online"].should eq(false)

      post(14602, "/register", {address: "@proj", kind: "agent", owner_token: "mine"})[1]["listing"]["online"].should eq(true)
    end
  end

  it "requires the owner token to unregister" do
    with_server(14603) do
      post(14603, "/register", {address: "@proj", kind: "agent", owner_token: "mine"})
      post(14603, "/unregister", {address: "@proj"})[0].should eq(409)
      post(14603, "/unregister", {address: "@proj", owner_token: "mine"})[0].should eq(200)
    end
  end

  it "keeps registrations without an owner token working as before" do
    with_server(14604) do
      post(14604, "/register", {address: "@legacy", kind: "agent"})[0].should eq(200)
      status, body = post(14604, "/register", {address: "@legacy", kind: "agent"})
      status.should eq(400)
      body["error"].as_s.should contain("already registered")
      post(14604, "/unregister", {address: "@legacy"})[0].should eq(200)
    end
  end
end
