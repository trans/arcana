require "http/client"

module Arcana
  module Util
    def self.bearer_headers(api_key : String) : HTTP::Headers
      HTTP::Headers{
        "Authorization" => "Bearer #{api_key}",
        "Content-Type"  => "application/json",
      }
    end

    def self.mime_for(path : String) : String
      case File.extname(path).downcase
      when ".webp"         then "image/webp"
      when ".jpg", ".jpeg" then "image/jpeg"
      when ".png"          then "image/png"
      when ".gif"          then "image/gif"
      when ".opus"         then "audio/opus"
      when ".mp3"          then "audio/mpeg"
      when ".wav"          then "audio/wav"
      else                      "application/octet-stream"
      end
    end

    def self.download_file(url : String, output_path : String,
                           connect_timeout : Time::Span = 30.seconds,
                           read_timeout : Time::Span = 30.seconds) : Nil
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout

      response = client.get(uri.request_target)
      unless response.success?
        raise APIError.new(response.status_code, response.body, "download")
      end

      File.open(output_path, "wb") { |f| f.write(response.body.to_slice) }
    ensure
      client.try(&.close)
    end
  end
end
