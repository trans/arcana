require "../src/arcana"

host = ENV["ARCANA_HOST"]? || "0.0.0.0"
port = (ENV["ARCANA_PORT"]? || "4000").to_i

bus = Arcana::Bus.new
dir = Arcana::Directory.new

STDERR.puts "Arcana v#{Arcana::VERSION} starting on #{host}:#{port}"
STDERR.puts "  WebSocket: ws://#{host}:#{port}/bus"
STDERR.puts "  REST:      http://#{host}:#{port}/directory"
STDERR.puts "  Health:    http://#{host}:#{port}/health"

server = Arcana::Server.new(bus, dir, host: host, port: port)
server.start
