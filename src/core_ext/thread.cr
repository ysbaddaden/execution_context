class Thread
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
