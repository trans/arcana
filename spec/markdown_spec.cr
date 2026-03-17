require "./spec_helper"

describe Arcana::Markdown do
  describe ".to_html" do
    it "converts basic markdown to HTML" do
      result = Arcana::Markdown.to_html("**bold** and *italic*")
      result.should contain("<strong>bold</strong>")
      result.should contain("<em>italic</em>")
    end

    it "converts headings" do
      result = Arcana::Markdown.to_html("# Hello")
      result.should contain("<h1>Hello</h1>")
    end

    it "converts code blocks" do
      md = "```crystal\nputs \"hello\"\n```"
      result = Arcana::Markdown.to_html(md)
      result.should contain("<code")
      result.should contain("puts")
    end

    it "converts links" do
      result = Arcana::Markdown.to_html("[click](https://example.com)")
      result.should contain("<a href=\"https://example.com\">click</a>")
    end

    it "handles empty string" do
      Arcana::Markdown.to_html("").should eq("")
    end
  end

  describe ".to_ansi" do
    it "converts headings to styled terminal output" do
      result = Arcana::Markdown.to_ansi("# Hello")
      result.should_not eq("# Hello")
      result.should contain("Hello")
    end

    it "converts bold and italic" do
      result = Arcana::Markdown.to_ansi("**bold** and *italic*")
      result.should contain("bold")
      result.should contain("italic")
    end

    it "converts lists" do
      md = "- first\n- second\n- third"
      result = Arcana::Markdown.to_ansi(md)
      result.should contain("first")
      result.should contain("second")
      result.should contain("third")
    end

    it "handles empty string" do
      Arcana::Markdown.to_ansi("").should eq("")
    end
  end
end
