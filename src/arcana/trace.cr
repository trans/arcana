module Arcana
  module Traceable
    @trace : Proc(String, Nil)? = nil

    protected def emit_trace(event : NamedTuple) : Nil
      @trace.try(&.call(event.to_json))
    rescue
    end
  end
end
