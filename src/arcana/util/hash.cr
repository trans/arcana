require "digest/sha256"
require "json"

module Arcana
  module Util
    def self.parameter_hash(**params) : String
      Digest::SHA256.hexdigest(params.to_json)
    end
  end
end
