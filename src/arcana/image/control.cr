module Arcana
  module Image
    # Structural control — guides pose, edges, or depth in the generated image.
    struct Control
      enum Type
        OpenPose  # Human pose skeleton
        Canny     # Edge detection
        Depth     # Depth map
      end

      property type : Type
      property guide_path : String?  # pre-processed control image
      property model : String?       # ControlNet model AIR ID (provider-specific)
      property weight : Float64      # 0.0-1.0
      property start_pct : Int32     # 0-99, percentage step where control begins
      property end_pct : Int32       # 1-100, percentage step where control ends

      def initialize(
        @type : Type,
        @guide_path : String? = nil,
        @model : String? = nil,
        @weight : Float64 = 0.8,
        @start_pct : Int32 = 0,
        @end_pct : Int32 = 100,
      )
      end

      def self.openpose(guide_path : String, weight : Float64 = 0.8, model : String? = nil) : self
        new(Type::OpenPose, guide_path: guide_path, model: model, weight: weight)
      end

      def self.canny(guide_path : String, weight : Float64 = 0.8, model : String? = nil) : self
        new(Type::Canny, guide_path: guide_path, model: model, weight: weight)
      end

      def self.depth(guide_path : String, weight : Float64 = 0.8, model : String? = nil) : self
        new(Type::Depth, guide_path: guide_path, model: model, weight: weight)
      end

      # FLUX-compatible OpenPose via Union Pro 2.0 model.
      # Default weight 0.9, control ends at 65% of steps.
      def self.flux_pose(guide_path : String, weight : Float64 = 0.9) : self
        new(Type::OpenPose, guide_path: guide_path,
            model: Arcana::Image::Runware::FLUX_UNION_MODEL,
            weight: weight, start_pct: 0, end_pct: 65)
      end
    end
  end
end
