module Arcana
  module TTS
    VOICE_OPTIONS = %w(alloy ash ballad coral echo fable onyx nova sage shimmer verse)
    AUDIO_FORMATS = Set{"mp3", "wav", "aac", "flac", "opus", "pcm"}

    abstract class Provider
      include Arcana::Traceable

      abstract def synthesize(request : Request, output_path : String) : Result
      abstract def name : String

      # Stream audio chunks as they arrive. Override in subclasses.
      def stream(request : Request, ctx : Context? = nil, &block : Bytes ->) : Result
        raise Error.new("Streaming not supported by #{name} TTS provider")
      end
    end
  end
end
