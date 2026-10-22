require "http/server/handler"
require "socket"
require "uri"

module Arcana
  # Keeps web pages off the bus. Any page open in a browser on this
  # machine can reach a server on 127.0.0.1: browsers let it open a
  # WebSocket to any address, and POST a text/plain body without asking
  # first. So a page or an ad could join as any address, call a service
  # that spends money, or consume someone's mail.
  #
  # The browser names the page's site in `Origin` and the server it
  # asked for in `Host`, and a page's scripts can set neither. A request
  # is refused when `Origin` names a site that isn't this machine, or
  # when `Host` isn't a name for this machine: DNS rebinding, a site
  # pointing its own name at 127.0.0.1, still sends that site's name.
  # Programs send no `Origin`, and their `Host` is the address they
  # connected to, so they pass.
  #
  # `allowed` adds names that count as this machine's (a bus reached by
  # a hostname). A server bound to every interface (0.0.0.0) with none
  # listed doesn't check `Host`, since its clients may use any name for
  # it; `Origin` is still checked.
  class LocalGuard
    include HTTP::Handler

    def initialize(bind_host : String, @allowed : Array(String) = [] of String, @events : Events::Backend? = nil)
      @check_host = !@allowed.empty? || !{"0.0.0.0", "::", ""}.includes?(bind_host)
    end

    def call(context : HTTP::Server::Context)
      if reason = refusal(context.request)
        @events.try &.record(Events::Event.new(
          type: "auth.failed",
          subject: context.request.path,
          metadata: {
            "reason" => JSON::Any.new(reason),
            "origin" => JSON::Any.new(context.request.headers["Origin"]? || ""),
            "host"   => JSON::Any.new(context.request.headers["Host"]? || ""),
          } of String => JSON::Any,
        ))
        context.response.status = HTTP::Status::FORBIDDEN
        context.response.content_type = "application/json"
        context.response.print({error: "#{reason}: the bus takes requests only from programs on this machine"}.to_json)
      else
        call_next(context)
      end
    end

    # Why the request is refused, or nil.
    def refusal(request : HTTP::Request) : String?
      if origin = request.headers["Origin"]?
        name = URI.parse(origin).host rescue nil
        return "a web page's request (Origin #{origin})" unless name && ours?(name)
      end
      if @check_host
        host = request.headers["Host"]?
        return "a request for another host (Host #{host || "missing"})" unless host && ours?(host_name(host))
      end
      nil
    end

    # Is `name` one of this machine's: localhost, a loopback address, or
    # a name listed in `allowed`?
    private def ours?(name : String) : Bool
      name = name.downcase.lchop('[').rchop(']')
      return true if name == "localhost" || name.ends_with?(".localhost")
      return true if @allowed.any? { |a| a.downcase == name }
      Socket::IPAddress.valid?(name) && Socket::IPAddress.new(name, 0).loopback?
    end

    # A `Host` header's name, without its port.
    private def host_name(host : String) : String
      if host.starts_with?('[')
        host[0..(host.index(']') || -1)]
      elsif host.count(':') == 1
        host.split(':').first
      else
        host
      end
    end
  end
end
