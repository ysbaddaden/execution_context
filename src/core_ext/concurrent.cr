def spawn(*, name : String?, execution_context : ExecutionContext = ExecutionContext.current, &) : Fiber
  execution_context.spawn(name: name) { yield }
end

@[Deprecated("spawn(same_thread) is deprecated, use ExecutionContext::SingleThreaded instead")]
def spawn(*, name : String?, same_thread : Bool, &) : Fiber
  ExecutionContext.current.spawn(name: name, same_thread: same_thread) { yield }
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
