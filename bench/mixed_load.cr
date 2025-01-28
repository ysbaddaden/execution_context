{% if flag?(:ec) %}
  require "../src/execution_context"
{% end %}
require "http/server"
require "big"

def take_some_time(n)
  count = BigInt.new 0
  while Time.local < n
    count += 1
  end
  count
end

FIBER_COUNT = 10

server = HTTP::Server.new do |context|
  context.response.content_type = "text/plain"

  ch = Channel(BigInt | String).new
  FIBER_COUNT.times do |i|
    if i % 2 == 0
      spawn do
        ch.send(take_some_time(Time.local + 1.seconds))
      end
    else
      spawn do
        contents = File.read(__FILE__)
        ch.send contents
      end
    end
  end
  FIBER_COUNT.times do
    context.response.print(ch.receive.to_s)
  end
end

address = server.bind_tcp 8080, reuse_port: true
puts "Listening on http://#{address}"
server.listen
