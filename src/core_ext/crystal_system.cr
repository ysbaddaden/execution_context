module Crystal::System
  def self.print_error_buffered(message, *args, backtrace = nil) : Nil
    buf = uninitialized UInt8[4096]
    io = IO::Memory.new(buf.to_slice)

    print_error(message, *args) { |bytes| io.write(bytes) }
    io << '\n'

    if backtrace
      backtrace.each do |frame|
        print_error("  from %s\n", frame) { |bytes| io.write(bytes) }
      end
    end

    {% if flag?(:unix) || flag?(:wasm32) %}
      LibC.write(2, buf.to_unsafe, io.pos)
    {% elsif flag?(:win32) %}
      LibC.WriteFile(LibC.GetStdHandle(LibC::STD_ERROR_HANDLE), buf.to_unsafe, io.pos, out _, nil)
    {% end %}
  end
end
