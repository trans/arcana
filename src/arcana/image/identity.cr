module Arcana
  module Image
    # Identity conditioning — controls character consistency across generations.
    # The `method` determines how the provider uses the reference image.
    struct Identity
      enum Method
        SeedImage  # img2img: reference as base composition (current default)
        AcePlus    # ACE++: zero-training identity preservation (Runware FLUX Fill)
        PuLID      # PuLID: face-specific identity embedding
        IPAdapter  # IP-Adapter: general style/appearance transfer
      end

      property reference_path : String
      property method : Method
      property strength : Float64   # 0.0-1.0, meaning varies by method
      property task_type : String?  # ACE++ specific: "portrait", "subject", "local_editing"

      def initialize(
        @reference_path : String,
        @method : Method = Method::SeedImage,
        @strength : Float64 = 0.65,
        @task_type : String? = nil,
      )
      end

      def self.seed_image(path : String, strength : Float64 = 0.95) : self
        new(path, method: Method::SeedImage, strength: strength)
      end

      def self.ace_plus(path : String, strength : Float64 = 0.65, task_type : String = "portrait") : self
        new(path, method: Method::AcePlus, strength: strength, task_type: task_type)
      end

      def self.pulid(path : String, strength : Float64 = 0.65) : self
        new(path, method: Method::PuLID, strength: strength)
      end

      def self.ip_adapter(path : String, strength : Float64 = 0.5) : self
        new(path, method: Method::IPAdapter, strength: strength)
      end
    end
  end
end
