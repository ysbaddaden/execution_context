module Crystal
  # :nodoc:
  struct StackIO(N)
    getter size : Int32

    def initialize
      @buffer = uninitialized UInt8[N]
      @pos = 0
      @size = 0
    end

    def write(str : String) : Nil
      write(str.to_slice)
    end

    def write(bytes : Bytes) : Nil
      size = @size
      return if size == N

      remaining = N - size
      n = bytes.size.clamp(..remaining)
      bytes.to_unsafe.copy_to(@buffer.to_unsafe + size, n)
      @size = size + n
    end

    def to_unsafe : UInt8*
      @buffer.to_unsafe
    end
  end

  macro trace(fmt, *args)
    {% if flag?(:sched_tracing) %}
      %buf = Crystal::StackIO(512).new
      %thread = Thread.current
      %fiber = Fiber.current
      Crystal::System.print_error("th=0x%lx [%s] fi=%p [%s] ", %thread.@system_handle, %thread.name, %fiber.as(Void*), %fiber.name) { |bytes| %buf.write(bytes) }
      Crystal::System.print_error({{fmt}}, {{args.splat}}) { |bytes| %buf.write(bytes) }
      %buf.write("\n")

      {% if flag?(:unix) || flag?(:wasm32) %}
        LibC.write(2, %buf.to_unsafe, %buf.size)
      {% elsif flag?(:win32) %}
        LibC.WriteFile(LibC.GetStdHandle(LibC::STD_ERROR_HANDLE), %buf.to_unsafe, %buf.size, out _, nil)
      {% end %}

      nil
    {% end %}
  end
end
