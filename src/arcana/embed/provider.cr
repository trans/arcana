module Arcana
  module Embed
    abstract class Provider
      include Arcana::Traceable

      abstract def embed(request : Request) : Result
      abstract def name : String

      # Embed texts in batches, aggregating results.
      def batch_embed(request : Request, batch_size : Int32 = 100) : Result
        texts = request.texts
        return embed(request) if texts.size <= batch_size

        all_embeddings = [] of Array(Float64)
        all_token_counts = [] of Int32
        total_tokens = 0
        raw_requests = [] of String
        raw_responses = [] of String
        model_name = ""
        provider_name = ""

        texts.each_slice(batch_size) do |batch|
          batch_request = Request.new(
            texts: batch,
            model: request.model,
            dimensions: request.dimensions,
            input_type: request.input_type,
            trace_tags: request.trace_tags,
          )
          result = embed(batch_request)

          all_embeddings.concat(result.embeddings)
          all_token_counts.concat(result.token_counts)
          total_tokens += result.total_tokens
          raw_requests << result.raw_request
          raw_responses << result.raw_response
          model_name = result.model
          provider_name = result.provider
        end

        Result.new(
          embeddings: all_embeddings,
          token_counts: all_token_counts,
          total_tokens: total_tokens,
          model: model_name,
          provider: provider_name,
          raw_request: raw_requests.join("\n---\n"),
          raw_response: raw_responses.join("\n---\n"),
        )
      end

      # Embed with automatic retry on transient errors (429, 503, 502, 500).
      def embed_with_retry(request : Request, max_retries : Int32 = 3, base_delay : Float64 = 1.0) : Result
        retries = 0
        loop do
          return embed(request)
        rescue ex : APIError
          raise ex unless retryable?(ex.status_code) && retries < max_retries
          retries += 1
          delay = base_delay * (2 ** (retries - 1)) # exponential backoff
          sleep delay.seconds
        end
      end

      # Combines batching and retry.
      def batch_embed_with_retry(request : Request, batch_size : Int32 = 100, max_retries : Int32 = 3) : Result
        texts = request.texts
        return embed_with_retry(request, max_retries) if texts.size <= batch_size

        all_embeddings = [] of Array(Float64)
        all_token_counts = [] of Int32
        total_tokens = 0
        raw_requests = [] of String
        raw_responses = [] of String
        model_name = ""
        provider_name = ""

        texts.each_slice(batch_size) do |batch|
          batch_request = Request.new(
            texts: batch,
            model: request.model,
            dimensions: request.dimensions,
            input_type: request.input_type,
            trace_tags: request.trace_tags,
          )
          result = embed_with_retry(batch_request, max_retries)

          all_embeddings.concat(result.embeddings)
          all_token_counts.concat(result.token_counts)
          total_tokens += result.total_tokens
          raw_requests << result.raw_request
          raw_responses << result.raw_response
          model_name = result.model
          provider_name = result.provider
        end

        Result.new(
          embeddings: all_embeddings,
          token_counts: all_token_counts,
          total_tokens: total_tokens,
          model: model_name,
          provider: provider_name,
          raw_request: raw_requests.join("\n---\n"),
          raw_response: raw_responses.join("\n---\n"),
        )
      end

      private def retryable?(status_code : Int32) : Bool
        status_code.in?(429, 500, 502, 503)
      end
    end
  end
end
