def spawn(*, name : String? = nil, &block) : Fiber
  ExecutionContext::Scheduler.current.spawn(name: name, &block)
end

@[Deprecated("The same_thread argument to spawn is deprecated")]
def spawn(*, name : String? = nil, same_thread : Bool, &block) : Fiber
  ExecutionContext::Scheduler.current.spawn(name: name, same_thread: same_thread, &block)
end

def sleep : Nil
  ExecutionContext.reschedule
end

def sleep(time : Time::Span) : Nil
  raise ArgumentError.new "Sleep time must be positive" if time.negative?

  Fiber.current.resume_event.add(time)
  ExecutionContext.reschedule
end

def sleep(seconds : Number) : Nil
  sleep(seconds.seconds)
end
