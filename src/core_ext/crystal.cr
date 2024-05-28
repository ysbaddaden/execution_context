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

    def to_slice : Bytes
      Slice.new(@buffer.to_unsafe, @size)
    end
  end

  macro trace(fmt, *args)
    {% if flag?(:sched_tracing) %}
      %buf = Crystal::StackIO(512).new # 512 == PIPE_BUF (minimum as per POSIX)
      %thread = Thread.current
      %fiber = Fiber.current

      {% if flag?(:wasm32) %}
        Crystal::System.printf("fi=%p [%s] ", %fiber.as(Void*), %fiber.name) { |bytes| %buf.write(bytes) }
      {% elsif flag?(:linux) %}
        Crystal::System.printf("th=0x%lx [%s] fi=%p [%s] ", %thread.@system_handle, %thread.name, %fiber.as(Void*), %fiber.name) { |bytes| %buf.write(bytes) }
      {% else %}
        Crystal::System.printf("th=%p [%s] fi=%p [%s] ", %thread.@system_handle, %thread.name, %fiber.as(Void*), %fiber.name) { |bytes| %buf.write(bytes) }
      {% end %}

      Crystal::System.printf({{fmt}}, {{args.splat}}) { |bytes| %buf.write(bytes) }
      %buf.write("\n")

      Crystal::System.print_error(%buf.to_slice)

      nil
    {% end %}
  end
end
