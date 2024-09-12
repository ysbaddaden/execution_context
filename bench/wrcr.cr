{% if flag?(:ec) %}
  require "../src/execution_context"
{% end %}
require "http/client"
require "option_parser"

address = "localhost:8080"
duration = 30.seconds
requests = 12
fibers = 20
threads = 4

OptionParser.parse do |parser|
  parser.banner = "Usage: wrcr [arguments]"
  {% if flag?(:ec) && flag?(:mt) %}
    parser.on("-t NUMBER", "--threads=NUMBER", "Number of total threads. Defaults to #{threads}") { |thrs| threads = thrs.to_i }
  {% end %}
  parser.on("-f NUMBER", "--fibers=NUMBER", "Number of total fibers. Defaults to #{fibers}") { |fbrs| fibers = fbrs.to_i }
  parser.on("-r NUMBER", "--requests=NUMBER", "Number of requests before closing the connection. Defaults to #{requests}") { |req| requests = req.to_i }
  parser.on("-d NUMBER", "--duration=NUMBER", "Duration of the test. Defaults to #{duration} seconds") { |dur| duration = dur.to_i.seconds }
  parser.on("-u URL", "--url=URL", "Specifies the address of the server. Defaults to #{address}") { |url| address = url }
  parser.on("-h", "--help", "Show this help") do
    puts parser
    exit
  end
  parser.invalid_option do |flag|
    STDERR.puts "ERROR: #{flag} is not a valid option."
    STDERR.puts parser
    exit(1)
  end
end

{% if flag?(:ec) && flag?(:mt) %}
  ExecutionContext::MultiThreaded.default threads
{% end %}

address = address.gsub("http://", "")
if address.includes? ":"
  address, port_s = address.split(":")
  port = port_s.to_i
else
  port = 80
end

start = Time.local

successes = Channel({Int32, Int64}).new(fibers)

fibers.times do
  spawn do
    j = 0
    bytes = 0_i64
    client = HTTP::Client.new address, port
    loop do
      requests.times do
        break if Time.local - start > duration
        response = client.get "/"
        if response.status_code == 200
          j += 1
          bytes += response.body.size
        end
      rescue IO::TimeoutError
      rescue e
        STDERR.puts e
      end
      break if Time.local - start > duration
    end
    successes.send({j, bytes})
  end
end

total_successes = 0
total_bytes = 0_i64

fibers.times do
  reqs, bytes = successes.receive
  total_successes += reqs
  total_bytes += bytes
end

puts "Total requests: #{total_successes}\nTotal bytes read: #{total_bytes.humanize}"
