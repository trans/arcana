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

    # TODO: Streaming conversion — accumulate chunks in a buffer and reconvert
    # the full buffer on each append (the Onboard approach). Simple but burns CPU
    # on repeated full parses. Consider throttling (e.g. convert at most every N ms)
    # or only reconverting when a structural boundary is detected (blank line, closing
    # fence, etc.) to reduce waste. Hold off on exposing until perf is evaluated.

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
