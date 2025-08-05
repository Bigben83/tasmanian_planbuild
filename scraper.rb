require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'nokogiri'

logger = Logger.new(STDOUT)

# STEP 1: Fetch the HTML page to get CSRF token and cookies
uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/search")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true

logger.info("Performing initial GET request...")
get_request = Net::HTTP::Get.new(uri)
get_request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'

response = http.request(get_request)

# STEP 2: Extract session cookie
set_cookie_header = response.get_fields('Set-Cookie') || []
session_cookie = nil
set_cookie_header.each do |cookie|
  if cookie.start_with?("SESSION=")
    session_cookie = cookie.split(';').first
    break
  end
end

# STEP 3: Extract CSRF token and header name
doc = Nokogiri::HTML(response.body)
csrf_token_tag = doc.at('meta[name="_csrf"]')
csrf_header_tag = doc.at('meta[name="_csrf_header"]')

csrf_token = csrf_token_tag ? csrf_token_tag['content'] : nil
csrf_header = csrf_header_tag ? csrf_header_tag['content'] : 'X-CSRF-TOKEN'

if csrf_token.nil? || session_cookie.nil?
  logger.error("Failed to extract CSRF token or session cookie.")
  exit
end

logger.info("Extracted CSRF Token: #{csrf_token}")
logger.info("Extracted CSRF Header Name: #{csrf_header}")
logger.info("Extracted Session Cookie: #{session_cookie}")

# STEP 4: Make the POST request to fetch advertised applications
post_uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/search/listadvertisements")
http = Net::HTTP.new(post_uri.host, post_uri.port)
http.use_ssl = true

post_data = { "lgaCode" => "LGA003" }

post_request = Net::HTTP::Post.new(post_uri)
post_request.body = post_data.to_json
post_request['Content-Type'] = 'application/json'
post_request['Origin'] = 'https://portal.planbuild.tas.gov.au'
post_request['Referer'] = 'https://portal.planbuild.tas.gov.au/external/advertisement/search'
post_request[csrf_header] = csrf_token
post_request['X-Requested-With'] = 'XMLHttpRequest'
post_request['Cookie'] = session_cookie
post_request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36'

logger.info("Performing POST request to fetch data...")
response = http.request(post_request)

# STEP 5: Handle the JSON response
if response.code == "200"
  logger.info("Successfully retrieved data from API")
  json = JSON.parse(response.body)

  # Debug structure
  if json.is_a?(Hash) && json['advertisements']
    json['advertisements'].each do |item|
      logger.info("#{item['applicationReference']} - #{item['address']} (#{item['advertisedDate']})")
    end
  elsif json.is_a?(Array)
    json.each do |item|
      logger.info("#{item['applicationReference']} - #{item['address']} (#{item['advertisedDate']})")
    end
  else
    logger.warn("Unexpected JSON structure:")
    logger.warn(json.inspect)
  end
else
  logger.error("API call failed with status #{response.code}")
  logger.debug("Response body: #{response.body}")
end
