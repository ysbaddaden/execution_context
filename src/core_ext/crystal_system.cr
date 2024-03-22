module Crystal::System
  def self.print_error_buffered(message, *args, backtrace = nil) : Nil
    buf = Crystal::StackIO(4096).new
    print_error(message, *args) { |bytes| buf.write(bytes) }
    buf.write("\n")

    if backtrace
      backtrace.each do |frame|
        print_error("  from %s\n", frame) { |bytes| buf.write(bytes) }
      end
    end

    {% if flag?(:unix) || flag?(:wasm32) %}
      LibC.write(2, buf.to_unsafe, buf.size)
    {% elsif flag?(:win32) %}
      LibC.WriteFile(LibC.GetStdHandle(LibC::STD_ERROR_HANDLE), buf.to_unsafe, buf.size, out _, nil)
    {% end %}
  end
end
