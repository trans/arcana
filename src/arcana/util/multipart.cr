module Arcana
  module Util
    class MultipartBuilder
      getter boundary : String

      def initialize
        @boundary = "----ArcanaBnd#{Random::Secure.hex(8)}"
        @body = IO::Memory.new
      end

      def content_type : String
        "multipart/form-data; boundary=#{@boundary}"
      end

      def add_field(name : String, value : String) : self
        @body << "--#{@boundary}\r\n"
        @body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
        @body << value
        @body << "\r\n"
        self
      end

      def add_file(name : String, path : String, filename : String, content_type : String) : self
        @body << "--#{@boundary}\r\n"
        @body << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n"
        @body << "Content-Type: #{content_type}\r\n\r\n"
        File.open(path, "rb") { |f| IO.copy(f, @body) }
        @body << "\r\n"
        self
      end

      def to_s : String
        @body << "--#{@boundary}--\r\n"
        @body.to_s
      end
    end
  end
end
