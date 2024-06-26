{% if flag?(:unix) %}
  module IO::Evented
    def resume_read(timed_out = false) : Nil
      @read_timed_out = timed_out

      if reader = @readers.get?.try &.shift?
        reader.execution_context.enqueue(reader)
      end
    end

    def resume_write(timed_out = false) : Nil
      @write_timed_out = timed_out

      if writer = @writers.get?.try &.shift?
        writer.execution_context.enqueue(writer)
      end
    end
  end
{% end %}

# TODO: win32
