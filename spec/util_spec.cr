require "./spec_helper"

describe Arcana::Util do
  describe ".bearer_headers" do
    it "builds authorization and content-type headers" do
      headers = Arcana::Util.bearer_headers("sk-test123")
      headers["Authorization"].should eq("Bearer sk-test123")
      headers["Content-Type"].should eq("application/json")
    end
  end

  describe ".mime_for" do
    it "detects common image types" do
      Arcana::Util.mime_for("photo.png").should eq("image/png")
      Arcana::Util.mime_for("photo.jpg").should eq("image/jpeg")
      Arcana::Util.mime_for("photo.jpeg").should eq("image/jpeg")
      Arcana::Util.mime_for("photo.webp").should eq("image/webp")
      Arcana::Util.mime_for("anim.gif").should eq("image/gif")
    end

    it "detects audio types" do
      Arcana::Util.mime_for("speech.opus").should eq("audio/opus")
      Arcana::Util.mime_for("song.mp3").should eq("audio/mpeg")
      Arcana::Util.mime_for("audio.wav").should eq("audio/wav")
    end

    it "falls back to octet-stream for unknown types" do
      Arcana::Util.mime_for("data.xyz").should eq("application/octet-stream")
    end

    it "is case-insensitive" do
      Arcana::Util.mime_for("PHOTO.PNG").should eq("image/png")
    end
  end

  describe ".parameter_hash" do
    it "produces consistent SHA-256 hashes" do
      h1 = Arcana::Util.parameter_hash(model: "gpt-4o", temp: 0.5)
      h2 = Arcana::Util.parameter_hash(model: "gpt-4o", temp: 0.5)
      h1.should eq(h2)
      h1.size.should eq(64) # SHA-256 hex length
    end

    it "produces different hashes for different params" do
      h1 = Arcana::Util.parameter_hash(model: "gpt-4o")
      h2 = Arcana::Util.parameter_hash(model: "gpt-3.5")
      h1.should_not eq(h2)
    end
  end
end

describe Arcana::Util::MultipartBuilder do
  it "builds multipart form data with fields" do
    mp = Arcana::Util::MultipartBuilder.new
    mp.add_field("model", "gpt-image-1")
    mp.add_field("prompt", "a cat")

    body = mp.to_s
    body.should contain("model")
    body.should contain("gpt-image-1")
    body.should contain("prompt")
    body.should contain("a cat")
    mp.content_type.should start_with("multipart/form-data; boundary=")
  end
end
