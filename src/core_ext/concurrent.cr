@[AlwaysInline]
def spawn(*, name : String? = nil, &block) : Fiber
  ExecutionContext::Scheduler.current.spawn(name: name, &block)
end

@[AlwaysInline]
@[Deprecated("The same_thread argument to spawn is deprecated")]
def spawn(*, name : String? = nil, same_thread : Bool, &block) : Fiber
  ExecutionContext::Scheduler.current.spawn(name: name, same_thread: same_thread, &block)
end

@[AlwaysInline]
def sleep : Nil
  ExecutionContext.reschedule
end

@[AlwaysInline]
def sleep(time : Time::Span) : Nil
  raise ArgumentError.new "Sleep time must be positive" if time.negative?

  Fiber.current.resume_event.add(time)
  ExecutionContext.reschedule
end

@[AlwaysInline]
def sleep(seconds : Number) : Nil
  sleep(seconds.seconds)
end
