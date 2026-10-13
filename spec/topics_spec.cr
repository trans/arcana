require "./spec_helper"
require "http/client"

private HEADERS = HTTP::Headers{"Content-Type" => "application/json"}

private def post(port : Int32, path : String, body) : {Int32, JSON::Any}
  resp = HTTP::Client.post("http://127.0.0.1:#{port}#{path}", headers: HEADERS, body: body.to_json)
  {resp.status_code, JSON.parse(resp.body)}
end

private def get(port : Int32, path : String) : JSON::Any
  JSON.parse(HTTP::Client.get("http://127.0.0.1:#{port}#{path}").body)
end

# A server with `#news` (keeping 3 posts), @alice and @bob (holding
# owner token "bobs").
private def with_topic_server(port : Int32, &)
  bus = Arcana::Bus.new
  dir = Arcana::Directory.new
  bus.directory = dir
  server = Arcana::Server.new(bus, dir, port: port)
  server.start_in_background
  begin
    post(port, "/register", {address: "#news", kind: "topic", description: "What's new", retention: {ring: 3}, owner_token: "newsroom"})[0].should eq(200)
    post(port, "/register", {address: "@alice", kind: "agent"})[0].should eq(200)
    post(port, "/register", {address: "@bob", kind: "agent", owner_token: "bobs"})[0].should eq(200)
    yield
  ensure
    server.stop
  end
end

private def publish(port : Int32, subject : String, text : String = subject, topic : String = "#news") : {Int32, JSON::Any}
  post(port, "/publish", {topic: topic, from: "@alice", subject: subject, payload: {text: text}})
end

describe "Topics over REST" do
  it "lists a topic with its newest post" do
    with_topic_server(14700) do
      topics = get(14700, "/directory?kind=topic").as_a
      topics.map(&.["address"]).should eq(["#news"])
      topics[0]["retention"].should eq(3)
      topics[0]["last_seq"].should eq(0)

      status, body = publish(14700, "hello")
      status.should eq(200)
      body["seq"].should eq(1)
      body["subscribers"].should eq(0)

      listing = get(14700, "/directory/%23news")
      listing["last_seq"].should eq(1)
      listing["last_published_at"].as_s.should_not be_empty
    end
  end

  it "lets anyone read posts after a number, without consuming them" do
    with_topic_server(14701) do
      publish(14701, "one")
      publish(14701, "two")
      2.times do
        status, body = post(14701, "/inbox", {address: "#news", after: 1})
        status.should eq(200)
        body["first_seq"].should eq(1)
        body["last_seq"].should eq(2)
        posts = body["posts"].as_a
        posts.size.should eq(1)
        posts[0]["seq"].should eq(2)
        posts[0]["from"].should eq("@alice")
        posts[0]["subject"].should eq("two")
        posts[0]["payload"]["text"].should eq("two")
      end
      post(14701, "/inbox", {address: "#news", limit: 1})[1]["posts"].as_a.map(&.["seq"]).should eq([1])
      post(14701, "/peek", {address: "#news"})[1]["last_seq"].should eq(2)
    end
  end

  it "keeps the topic's retention" do
    with_topic_server(14702) do
      5.times { |i| publish(14702, "p#{i + 1}") }
      body = post(14702, "/inbox", {address: "#news", after: 0})[1]
      body["first_seq"].should eq(3)
      body["posts"].as_a.map(&.["seq"]).should eq([3, 4, 5])
    end
  end

  it "notifies subscribers, who need their owner token to sign up" do
    with_topic_server(14703) do
      status, body = post(14703, "/subscribe", {topic: "#news", address: "@bob"})
      status.should eq(409)
      body["error"].as_s.should contain("held by another owner")

      status, body = post(14703, "/subscribe", {topic: "#news", address: "@bob", owner_token: "bobs"})
      status.should eq(200)
      body["subscribed"].should eq(true)
      post(14703, "/subscriptions", {address: "@bob"})[1]["topics"].should eq(["#news"])

      publish(14703, "Q3 notes", "the long version")[1]["subscribers"].should eq(1)
      inbox = post(14703, "/inbox", {address: "@bob"})[1].as_a
      inbox.size.should eq(1)
      inbox[0]["from"].should eq("#news")
      inbox[0]["subject"].should eq("Q3 notes")
      note = post(14703, "/receive", {address: "@bob"})[1].as_a[0]
      note["payload"]["seq"].should eq(1)
      note["payload"]["topic"].should eq("#news")
      note["payload"]["payload"]?.should be_nil

      post(14703, "/unsubscribe", {topic: "#news", address: "@bob", owner_token: "bobs"})[0].should eq(200)
      publish(14703, "again")
      post(14703, "/inbox", {address: "@bob"})[1].as_a.should be_empty
    end
  end

  it "takes only the always cadence" do
    with_topic_server(14704) do
      status, body = post(14704, "/subscribe", {topic: "#news", address: "@alice", cadence: "daily"})
      status.should eq(400)
      body["error"].as_s.should contain("isn't implemented yet")
    end
  end

  it "refuses to receive from, send to, or post to an unregistered topic" do
    with_topic_server(14705) do
      status, body = post(14705, "/receive", {address: "#news"})
      status.should eq(400)
      body["error"].as_s.should contain("read it with inbox")

      status, body = post(14705, "/deliver", {from: "@alice", to: "#news", payload: {text: "hi"}})
      status.should_not eq(200)
      body["error"].as_s.should contain("is a topic: publish")

      status, body = publish(14705, "typo", topic: "#nwes")
      status.should eq(400)
      body["error"].as_s.should contain("no topic #nwes")
      body["did_you_mean"]["address"].should eq("#news")
    end
  end

  it "checks registrations" do
    with_topic_server(14706) do
      post(14706, "/register", {address: "@carol", kind: "agent", retention: 5})[1]["error"].as_s.should contain("retention is for topics")
      post(14706, "/register", {address: "#big", kind: "topic", retention: 0})[1]["error"].as_s.should contain("from 1 to")
      post(14706, "/register", {address: "#quiet", kind: "topic", listed: false})[1]["error"].as_s.should contain("always listed")
      post(14706, "/register", {address: "news", kind: "topic"})[1]["error"].as_s.should contain("`#` sigil")
    end
  end

  it "drops an unregistered topic" do
    with_topic_server(14707) do
      publish(14707, "hello")
      post(14707, "/unregister", {address: "#news"})[0].should eq(409)
      post(14707, "/unregister", {address: "#news", owner_token: "newsroom"})[0].should eq(200)
      get(14707, "/directory?kind=topic").as_a.should be_empty
      publish(14707, "gone")[0].should eq(400)
    end
  end
end

describe "Topics in a snapshot" do
  it "keep their posts, numbering and subscribers" do
    bus = Arcana::Bus.new
    dir = Arcana::Directory.new
    bus.directory = dir
    server = Arcana::Server.new(bus, dir, port: 14710)
    dir.register(Arcana::Directory::Listing.new("#news", "News", "", kind: :topic, retention: 2))
    dir.register(Arcana::Directory::Listing.new("@bob", "Bob", ""))
    bus.mailbox("@bob")
    bus.subscribe("#news", "@bob")
    3.times { |i| bus.publish("#news", Arcana::Envelope.new(from: "@bob", subject: "p#{i + 1}")) }

    path = File.tempname("arcana-snap", ".json")
    begin
      Arcana::Snapshot.save(bus, dir, server, path)

      bus2 = Arcana::Bus.new
      dir2 = Arcana::Directory.new
      bus2.directory = dir2
      Arcana::Snapshot.load(bus2, dir2, Arcana::Server.new(bus2, dir2, port: 14711), path).should be_true

      dir2.lookup("#news").not_nil!.retention.should eq(2)
      log = bus2.topic_log("#news")
      log.read.map { |p| {p.seq, p.envelope.subject} }.should eq([{2_i64, "p2"}, {3_i64, "p3"}])
      bus2.subscribers("#news").should eq(["@bob"])
      bus2.has_mailbox?("#news").should be_false
      bus2.publish("#news", Arcana::Envelope.new(from: "@bob", subject: "p4")).should eq(4)
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
