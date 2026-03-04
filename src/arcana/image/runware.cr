require "base64"
require "http/client"
require "json"
require "uuid"

module Arcana
  module Image
    class Runware < Provider
      ENDPOINT = "https://api.runware.ai/v1"

      # Runware model AIR IDs
      FLUX_DEV     = "runware:101@1"  # Good quality, ~4s
      FLUX_SCHNELL = "runware:100@1"  # Fastest, ~2s
      FLUX_FILL    = "runware:102@1"  # Required for ACE++

      getter model : String
      getter steps : Int32
      getter cfg_scale : Float64

      def initialize(
        @api_key : String,
        @model : String = FLUX_DEV,
        @steps : Int32 = 20,
        @cfg_scale : Float64 = 14.0,
        trace : Proc(String, Nil)? = nil,
      )
        raise ConfigError.new("API key is required for Runware") if @api_key.strip.empty?
        @trace = trace
      end

      # ── FLUX.1 dimension constraints ──

      FLUX1_DIMENSIONS = [
        {1568, 672}, {1504, 688}, {1456, 720}, {1392, 752},
        {1328, 800}, {1248, 832}, {1184, 880}, {1104, 944},
        {1024, 1024},
        {944, 1104}, {880, 1184}, {832, 1248}, {800, 1328},
        {752, 1392}, {720, 1456}, {688, 1504}, {672, 1568},
      ]

      FIXED_DIMENSION_MODELS = [FLUX_DEV, FLUX_SCHNELL]

      # ── ControlNet model presets ──

      FLUX_UNION_MODEL     = "runware:110@1"          # FLUX ControlNet Union Pro 2.0
      SD15_OPENPOSE_MODEL  = "civitai:38784@44811"    # SD 1.5 OpenPose v1.1

      def name : String
        "runware"
      end

      def generate(request : Request, output_path : String) : Result
        raise ConfigError.new("Image prompt cannot be empty") if request.prompt.strip.empty?

        payload = build_payload(request)

        emit_request_trace(request)

        response = post_api(payload)
        emit_response_trace(request, response)

        unless response.success?
          raise APIError.new(response.status_code, response.body, "runware")
        end

        parsed = JSON.parse(response.body)
        data = parsed["data"].as_a
        raise Arcana::Error.new("Runware returned empty data array") if data.empty?

        image_url = data[0]["imageURL"].as_s
        cost = data[0]["cost"]?.try(&.as_f?)

        Util.download_file(image_url, output_path)
        Result.new(output_path, effective_model(request), "runware", cost)
      end

      # Upload an image to Runware, returns a reusable UUID.
      def upload_image(file_path : String) : String
        task_uuid = UUID.random.to_s
        data_uri = image_data_uri(file_path)

        payload = JSON.build do |json|
          json.array do
            json.object do
              json.field "taskType", "imageUpload"
              json.field "taskUUID", task_uuid
              json.field "image", data_uri
            end
          end
        end

        response = post_api(payload)
        unless response.success?
          raise APIError.new(response.status_code, response.body, "runware:upload")
        end

        result = JSON.parse(response.body)
        data = result["data"].as_a
        task_result = data.find { |r| r["taskUUID"].as_s == task_uuid }
        raise Arcana::Error.new("No upload result for task #{task_uuid}") unless task_result
        task_result["imageUUID"].as_s
      end

      # Extract OpenPose skeleton via ControlNet preprocessing.
      # Returns {guide_uuid, guide_url}.
      def preprocess_pose(image_uuid : String, width : Int32, height : Int32) : {String, String}
        task_uuid = UUID.random.to_s

        payload = JSON.build do |json|
          json.array do
            json.object do
              json.field "taskType", "imageControlNetPreProcess"
              json.field "taskUUID", task_uuid
              json.field "inputImage", image_uuid
              json.field "preProcessorType", "openpose"
              json.field "width", width
              json.field "height", height
              json.field "outputType", "URL"
              json.field "outputFormat", "PNG"
            end
          end
        end

        response = post_api(payload)
        unless response.success?
          raise APIError.new(response.status_code, response.body, "runware:preprocess")
        end

        result = JSON.parse(response.body)
        data = result["data"].as_a
        task_result = data.find { |r| r["taskUUID"].as_s == task_uuid }
        raise Arcana::Error.new("No preprocess result for task #{task_uuid}") unless task_result

        guide_uuid = task_result["guideImageUUID"].as_s
        guide_url = task_result["guideImageURL"].as_s
        {guide_uuid, guide_url}
      end

      # Snap dimensions to valid FLUX.1 pairs if needed.
      def self.snap_dimensions(width : Int32, height : Int32, model : String = FLUX_DEV) : {Int32, Int32}
        if FIXED_DIMENSION_MODELS.includes?(model)
          aspect = width.to_f / height.to_f
          best = FLUX1_DIMENSIONS.min_by { |w, h| (w.to_f / h.to_f - aspect).abs }
          {best[0], best[1]}
        else
          w = ((width + 8) // 16) * 16
          h = ((height + 8) // 16) * 16
          {w.clamp(64, 2048), h.clamp(64, 2048)}
        end
      end

      # Select the appropriate model based on identity method.
      private def effective_model(request : Request) : String
        if id = request.identity
          case id.method
          when Identity::Method::AcePlus then FLUX_FILL
          else @model
          end
        else
          @model
        end
      end

      # Build the full JSON payload as a string.
      private def build_payload(request : Request) : String
        model = effective_model(request)
        identity = request.identity
        control = request.control

        JSON.build do |json|
          json.array do
            json.object do
              json.field "taskType", "imageInference"
              json.field "taskUUID", UUID.random.to_s
              json.field "outputType", "URL"
              json.field "outputFormat", request.output_format
              json.field "positivePrompt", request.prompt
              json.field "width", request.width
              json.field "height", request.height
              json.field "model", model
              json.field "steps", @steps
              json.field "CFGScale", @cfg_scale
              json.field "numberResults", 1
              json.field "includeCost", true

              json.field "promptEnhancer", true if request.enhance_prompt

              # Identity conditioning
              if id = identity
                if File.exists?(id.reference_path)
                  case id.method
                  when Identity::Method::SeedImage
                    json.field "seedImage", image_data_uri(id.reference_path)
                    json.field "strength", id.strength

                  when Identity::Method::AcePlus
                    json.field "acePlusPlus" do
                      json.object do
                        json.field "inputImages" do
                          json.array { json.string image_data_uri(id.reference_path) }
                        end
                        json.field "taskType", id.task_type || "portrait"
                        json.field "repaintingScale", id.strength
                      end
                    end

                  when Identity::Method::PuLID
                    json.field "referenceImages" do
                      json.array { json.string image_data_uri(id.reference_path) }
                    end
                    json.field "guidanceScale", id.strength
                  end
                end
              end

              # ControlNet
              if ctrl = control
                if (guide_path = ctrl.guide_path) && File.exists?(guide_path)
                  json.field "controlNet" do
                    json.array do
                      json.object do
                        json.field "guideImage", image_data_uri(guide_path)
                        json.field "weight", ctrl.weight
                        json.field "startStepPercentage", ctrl.start_pct
                        json.field "endStepPercentage", ctrl.end_pct
                        json.field "controlMode", "balanced"
                        if model_id = ctrl.model
                          json.field "model", model_id
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      private def image_data_uri(path : String) : String
        image_bytes = File.open(path, "rb") { |f| f.getb_to_end }
        b64 = Base64.strict_encode(image_bytes)
        mime = Util.mime_for(path)
        "data:#{mime};base64,#{b64}"
      end

      private def post_api(payload : String) : HTTP::Client::Response
        headers = Util.bearer_headers(@api_key)
        uri = URI.parse(ENDPOINT)
        client = HTTP::Client.new(uri)
        client.connect_timeout = 30.seconds
        client.read_timeout = 60.seconds
        client.post(uri.request_target, headers: headers, body: payload)
      end

      private def emit_request_trace(request : Request) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:           "api_request_image",
          event_type:      "api_request",
          provider:        "runware",
          endpoint:        ENDPOINT,
          model:           effective_model(request),
          identity_method: request.identity.try(&.method.to_s) || "none",
          control_type:    request.control.try(&.type.to_s) || "none",
          prompt_length:   request.prompt.size,
          tags:            tags.to_json,
        })
      end

      private def emit_response_trace(request : Request, response : HTTP::Client::Response) : Nil
        tags = request.trace_tags || {} of String => String
        emit_trace({
          phase:          "api_response_image",
          event_type:     "api_response",
          provider:       "runware",
          endpoint:       ENDPOINT,
          status_code:    response.status_code,
          content_type:   response.headers["Content-Type"]? || "",
          content_length: response.headers["Content-Length"]? || "",
          tags:           tags.to_json,
        })
      end
    end
  end
end
