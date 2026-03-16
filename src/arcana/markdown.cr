require "markd"

module Arcana
  # TODO: Add `to_ansi` method using the `markterm` shard for terminal rendering.
  # TODO: Expose as a bus service so network agents can use markdown conversion.
  module Markdown
    # Convert Markdown text to HTML.
    def self.to_html(text : String, options : Markd::Options? = nil) : String
      if options
        Markd.to_html(text, options)
      else
        Markd.to_html(text)
      end
    end
  end
end
