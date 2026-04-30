require 'net/http'
require 'uri'
require 'json'

BASE_URL = 'http://localhost:4567'

def post(path, params)
  uri = URI(BASE_URL + path)
  req = Net::HTTP::Post.new(uri)
  req.set_form_data(params)

  res = Net::HTTP.start(uri.hostname, uri.port) do |http|
    http.request(req)
  end

  JSON.parse(res.body)
end

def test_case(name, first_mac, second_mac)
  puts "\n=== #{name} ==="

  response = post('/scan_pair', {
    'first_mac' => first_mac,
    'second_mac' => second_mac,
    'worker' => 'TEST_USER'
  })

  puts "Input: #{first_mac} / #{second_mac}"
  puts "Output: #{response['result']} - #{response['reason']}"
end

# TEST DATA
VALID_1 = "BBBBBBBBBBBB"
VALID_2 = "CCCCCCCCCCCC"
BAD_MAC = "AAAAAAAAAAAA" # this exists in DB
INVALID = "SHORT"

# RUN TESTS
test_case("Match valid", VALID_1, VALID_1)
test_case("Mismatch valid", VALID_1, VALID_2)
test_case("Both bad match", BAD_MAC, BAD_MAC)
test_case("Bad vs good mismatch", BAD_MAC, VALID_1)
test_case("Invalid first", INVALID, VALID_1)
test_case("Invalid second", VALID_1, INVALID)