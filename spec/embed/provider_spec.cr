require "../spec_helper"

# Test provider that returns predictable results without hitting any API.
class FakeEmbedProvider < Arcana::Embed::Provider
  getter call_count : Int32 = 0
  property fail_count : Int32 = 0 # fail this many times before succeeding
  property fail_code : Int32 = 429

  def name : String
    "fake"
  end

  def embed(request : Arcana::Embed::Request) : Arcana::Embed::Result
    if @fail_count > 0
      @fail_count -= 1
      raise Arcana::APIError.new(@fail_code, "rate limited", "fake:embed")
    end

    @call_count += 1
    n = request.texts.size
    dims = request.dimensions || 3

    Arcana::Embed::Result.new(
      embeddings: request.texts.map { |_| Array.new(dims, 0.1) },
      token_counts: Array.new(n, 5),
      total_tokens: n * 5,
      model: request.model.empty? ? "fake-model" : request.model,
      provider: "fake",
      raw_request: request.texts.join(","),
      raw_response: "ok",
    )
  end
end

describe Arcana::Embed::Provider do
  describe "#batch_embed" do
    it "passes through for small requests" do
      p = FakeEmbedProvider.new
      req = Arcana::Embed::Request.new(texts: ["a", "b", "c"])
      result = p.batch_embed(req, batch_size: 10)

      p.call_count.should eq(1)
      result.embeddings.size.should eq(3)
      result.total_tokens.should eq(15)
    end

    it "splits into batches and aggregates" do
      p = FakeEmbedProvider.new
      texts = (1..10).map(&.to_s)
      req = Arcana::Embed::Request.new(texts: texts)
      result = p.batch_embed(req, batch_size: 3)

      p.call_count.should eq(4) # 3+3+3+1
      result.embeddings.size.should eq(10)
      result.token_counts.size.should eq(10)
      result.total_tokens.should eq(50)
    end
  end

  describe "#embed_with_retry" do
    it "succeeds on first try" do
      p = FakeEmbedProvider.new
      req = Arcana::Embed::Request.new(texts: ["hello"])
      result = p.embed_with_retry(req)

      p.call_count.should eq(1)
      result.embeddings.size.should eq(1)
    end

    it "retries on 429 and succeeds" do
      p = FakeEmbedProvider.new
      p.fail_count = 2
      p.fail_code = 429
      req = Arcana::Embed::Request.new(texts: ["hello"])
      result = p.embed_with_retry(req, max_retries: 3, base_delay: 0.01)

      p.call_count.should eq(1)
      result.embeddings.size.should eq(1)
    end

    it "retries on 503 and succeeds" do
      p = FakeEmbedProvider.new
      p.fail_count = 1
      p.fail_code = 503
      req = Arcana::Embed::Request.new(texts: ["hello"])
      result = p.embed_with_retry(req, max_retries: 2, base_delay: 0.01)

      p.call_count.should eq(1)
    end

    it "raises after exhausting retries" do
      p = FakeEmbedProvider.new
      p.fail_count = 5
      p.fail_code = 429
      req = Arcana::Embed::Request.new(texts: ["hello"])

      expect_raises(Arcana::APIError) do
        p.embed_with_retry(req, max_retries: 2, base_delay: 0.01)
      end
    end

    it "does not retry on non-retryable errors" do
      p = FakeEmbedProvider.new
      p.fail_count = 1
      p.fail_code = 401
      req = Arcana::Embed::Request.new(texts: ["hello"])

      expect_raises(Arcana::APIError) do
        p.embed_with_retry(req, max_retries: 3, base_delay: 0.01)
      end
    end
  end

  describe "#batch_embed_with_retry" do
    it "batches and retries" do
      p = FakeEmbedProvider.new
      p.fail_count = 1
      p.fail_code = 429
      texts = (1..5).map(&.to_s)
      req = Arcana::Embed::Request.new(texts: texts)
      result = p.batch_embed_with_retry(req, batch_size: 2, max_retries: 2)

      result.embeddings.size.should eq(5)
      result.total_tokens.should eq(25)
    end
  end

  describe "dimensions passthrough" do
    it "passes dimensions to provider" do
      p = FakeEmbedProvider.new
      req = Arcana::Embed::Request.new(texts: ["hello"], dimensions: 8)
      result = p.embed(req)

      result.embeddings.first.size.should eq(8)
    end
  end
end
