module Arcana
  module TTS
    VOICE_OPTIONS = %w(alloy ash ballad coral echo fable onyx nova sage shimmer verse)
    AUDIO_FORMATS = Set{"mp3", "wav", "aac", "flac", "opus", "pcm"}

    abstract class Provider
      include Arcana::Traceable

      abstract def synthesize(request : Request, output_path : String) : Result
      abstract def name : String
    end
  end
end
