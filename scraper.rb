require 'net/http'
require 'uri'
require 'json'
require 'logger'

logger = Logger.new(STDOUT)

# First: Fetch the HTML page to get CSRF token and cookies
uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/search")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

# Initial GET to set session cookie and grab token
logger.info("Performing initial GET request...")
get_request = Net::HTTP::Get.new(uri)
get_request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'

response = http.request(get_request)

# Extract cookies
set_cookie = response['Set-Cookie']
session_cookie = set_cookie[/SESSION=[^;]+/]

# Extract CSRF token from HTML meta tag
csrf_token = response.body[/name="csrf-token" content="([^"]+)"/, 1]

if csrf_token.nil? || session_cookie.nil?
  logger.error("Failed to extract CSRF token or session cookie.")
  exit
end

logger.info("Extracted CSRF Token: #{csrf_token}")
logger.info("Extracted Session Cookie: #{session_cookie}")

# Now: Perform POST request to the actual data endpoint
post_uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/search/listadvertisements")
http = Net::HTTP.new(post_uri.host, post_uri.port)
http.use_ssl = true

post_data = {
  "lgaCode" => "LGA003"  # Replace this with the desired council
}

post_request = Net::HTTP::Post.new(post_uri)
post_request.body = post_data.to_json
post_request['Content-Type'] = 'application/json'
post_request['Origin'] = 'https://portal.planbuild.tas.gov.au'
post_request['Referer'] = 'https://portal.planbuild.tas.gov.au/external/advertisement/search'
post_request['X-CSRF-TOKEN'] = csrf_token
post_request['X-Requested-With'] = 'XMLHttpRequest'
post_request['Cookie'] = session_cookie
post_request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'

logger.info("Performing POST request to fetch data...")
response = http.request(post_request)

if response.code == "200"
  logger.info("Successfully retrieved data")
  json = JSON.parse(response.body)
  json['advertisements'].each do |item|
    logger.info("#{item['applicationReference']} - #{item['address']} (#{item['advertisedDate']})")
  end
else
  logger.error("Failed with code #{response.code}")
  logger.debug("Response body: #{response.body}")
end
