require "json"

module Arcana
  module Chat
    # Defines a tool the model can call (function calling).
    struct Tool
      property name : String
      property description : String
      property parameters_json : String  # raw JSON Schema string

      def initialize(@name : String, @description : String, @parameters_json : String)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "type", "function"
          json.field "function" do
            json.object do
              json.field "name", @name
              json.field "description", @description
              json.field "parameters", JSON.parse(@parameters_json)
            end
          end
        end
      end
    end
  end
end
