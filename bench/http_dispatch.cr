# A server listening on port 8080 that dispatches requests to different handlers
{% if flag?(:ec) %}
  require "../src/execution_context"
{% end %}
require "socket"
require "http/server/request_processor"

THREAD_COUNT = (ENV["CRYSTAL_WORKERS"]?.try(&.to_i?) || 4) - 1 # 1 thread is the dedicated thread
MSG_SIZE = ENV["BENCH_MSG_SIZE"]?.try(&.to_i?) || 1000
MSG = "a" * MSG_SIZE

class Dispatcher
  {% if flag?(:ec) %}
    @mt : ExecutionContext::MultiThreaded? = nil
  {% end %}

  def initialize(@processor : HTTP::Server::RequestProcessor)
    {% if flag?(:ec) %}
      @mt = ExecutionContext::MultiThreaded.new("MT", (THREAD_COUNT..THREAD_COUNT))
    {% end %}
  end

  def dispatch(io)
    {% begin %}
    {% if flag?(:ec) %}
      @mt.not_nil!.spawn do
    {% else %}
      spawn do
    {% end %}
        @processor.process io, io
      ensure 
        io.close
      end
    {% end %}
  end
  
end

{% if flag?(:ec) %}
  # Sets the main thread to be part of the SingleThreaded execution context
  ExecutionContext::SingleThreaded.default
{% end %}


socket = TCPServer.new(Socket::IPAddress::LOOPBACK, 8080, reuse_port: true)
processor = HTTP::Server::RequestProcessor.new do |context|
  context.response.content_type = "text/plain"
  context.response.print(MSG)
end

dispatcher = Dispatcher.new(processor)
puts "Listening on http://#{socket.local_address}"
socket.listen

loop do
  io = begin
    socket.accept?
  rescue e
    STDERR.puts e
    next
  end

  if io
    dispatcher.dispatch(io)
  else
    break
  end
end
