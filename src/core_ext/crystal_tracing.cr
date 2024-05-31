module Crystal
  {% if flag?(:tracing) %}
    # :nodoc:
    module Tracing
      struct BufferIO(N)
        def write(execution_context : ExecutionContext) : Nil
          write execution_context.name
        end

        def write(scheduler : ExecutionContext::Scheduler) : Nil
          write scheduler.name
        end
      end
    end
  {% end %}
end
