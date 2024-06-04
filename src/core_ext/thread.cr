{% unless flag?(:win32) %}
  lib LibC
    fun nanosleep(Timespec*, Timespec*) : UInt
  end
{% end %}

class Thread
  # Blocks the current thread for the duration of `span`.
  def self.sleep(span : Time::Span) : Nil
    {% if flag?(:win32) %}
      LibC.Sleep(span.total_milliseconds.to_i.clamp(1..))
    {% else %}
      ts = uninitialized LibC::Timespec
      ts.tv_sec = typeof(ts.tv_sec).new(span.seconds)
      ts.tv_nsec = typeof(ts.tv_nsec).new(span.nanoseconds)

      if LibC.nanosleep(pointerof(ts), out rem) == -1
        raise RuntimeError.from_errno("nanosleep") unless Errno.value == Errno::EINTR
      end
    {% end %}
  end

  # :nodoc:
  getter! execution_context : ExecutionContext

  # :nodoc:
  property! current_scheduler : ExecutionContext::Scheduler

  def execution_context=(@execution_context : ExecutionContext)
    main_fiber.execution_context = execution_context
  end

  # :nodoc:
  def dead_fiber=(@dead_fiber : Fiber) : Fiber
  end

  # :nodoc:
  def dead_fiber? : Fiber?
    if fiber = @dead_fiber
      @dead_fiber = nil
      fiber
    end
  end

  # the following methods apply these patches:
  # https://github.com/crystal-lang/crystal/pull/14558

  def initialize(@name : String? = nil, &@func : Thread ->)
    @system_handle = uninitialized Crystal::System::Thread::Handle
    init_handle

    Thread.threads.push(self) # <= moved here
  end

  protected def start
    Thread.current = self
    @current_fiber = @main_fiber = fiber = Fiber.new(stack_address, self)

    if name = @name
      self.system_name = name
    end

    begin
      @func.call(self)
    rescue ex
      @exception = ex
    ensure
      {% if flag?(:preview_mt) %}
        # fix the thread stack now so we can start cleaning up references
        GC.lock_read
        GC.set_stackbottom(self.gc_thread_handler, fiber.@stack_bottom)
        GC.unlock_read
      {% else %}
        GC.set_stackbottom(fiber.@stack_bottom)
      {% end %}

      Thread.threads.delete(self)
      Fiber.inactive(fiber)
      detach { system_close }
    end
  end

  def scheduler : Crystal::Scheduler
    raise "BUG: deprecated call to Thread#scheduler"
  end
end

class Thread::WaitGroup
  def initialize(@count : Int32)
    @mutex = Thread::Mutex.new
    @condition = Thread::ConditionVariable.new
  end

  def done : Nil
    @mutex.synchronize do
      @count -= 1
      @condition.broadcast if @count == 0
    end
  end

  def wait : Nil
    @mutex.synchronize do
      @condition.wait(@mutex) unless @count == 0
    end
  end
end
