module Crystal::System
  private struct BufferIO(N)
    getter size : Int32

    def initialize
      @buf = uninitialized UInt8[N]
      @size = 0
    end

    def write(bytes : Bytes) : Nil
      pos = @size
      remaining = N - pos
      return if remaining == 0

      n = bytes.size.clamp(..remaining)
      bytes.to_unsafe.copy_to(@buf.to_unsafe + pos, n)
      @size = pos + n
    end

    def to_slice : Bytes
      Bytes.new(@buf.to_unsafe, @size)
    end
  end

  def self.print_error_buffered(message, *args, backtrace = nil) : Nil
    buf = BufferIO(4096).new
    printf(message, *args) { |bytes| buf.write(bytes) }
    buf.write "\n".to_slice
    backtrace.each { |frame| printf("  from %s\n", frame) { |bytes| buf.write(bytes) } } if backtrace
    Crystal::System.print_error(buf.to_slice)
  end
end
