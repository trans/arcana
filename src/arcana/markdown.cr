require "markd"
require "markterm"

module Arcana
  module Markdown
    # Convert Markdown text to HTML.
    def self.to_html(text : String, options : Markd::Options? = nil) : String
      if options
        Markd.to_html(text, options)
      else
        Markd.to_html(text)
      end
    end

    # Convert Markdown text to ANSI-styled terminal output.
    def self.to_ansi(
      text : String,
      theme : String? = nil,
      code_theme : String? = nil
    ) : String
      Markd.to_term(text, theme: theme, code_theme: code_theme)
    end
  end
end
