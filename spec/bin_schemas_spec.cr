require "./spec_helper"

# bin/arcana.cr builds its tool schemas from `JSON.parse(%(...))`
# literals, which only run when the daemon starts with the matching
# provider key. 0.31.0 shipped one with `\"` inside: Crystal turns that
# into a bare quote, the JSON breaks, and the daemon crashed at startup
# whenever OPENAI_API_KEY was set. Parse every literal the way the
# compiler would.
describe "bin/arcana.cr schema literals" do
  it "are all valid JSON" do
    source = File.read(File.join(__DIR__, "..", "bin", "arcana.cr"))
    # One literal per line; without /m, `.*` stays on its line.
    literals = source.scan(/JSON\.parse\(%\((.*)\)\)/)
    literals.size.should be > 0
    literals.each do |m|
      text = m[1].gsub(/\\(.)/) { |_, md| md[1] == "n" ? "\n" : md[1] }
      begin
        JSON.parse(text)
      rescue ex : JSON::ParseException
        fail "bin/arcana.cr: #{ex.message}\n  in: #{m[1][0, 80]}..."
      end
    end
  end
end
