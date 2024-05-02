{% if flag?(:ec) %}
  require "../src/execution_context"
{% end %}
require "http/server"

contents = File.read(__FILE__)

server = HTTP::Server.new do |context|
  context.response.content_type = "text/plain"

  10.times do
    context.response.print(contents)
  end
end

address = server.bind_tcp 8080, reuse_port: true
puts "Listening on http://#{address}"
server.listen
