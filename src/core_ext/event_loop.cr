abstract class Crystal::EventLoop
  @[AlwaysInline]
  def self.current : self
    # ExecutionContext.current.event_loop
    ExecutionContext::Scheduler.current.event_loop
  end
end
