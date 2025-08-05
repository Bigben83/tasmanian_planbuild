require 'net/http'
require 'json'
require 'sqlite3'
require 'logger'
require 'uri'

logger = Logger.new(STDOUT)
db = SQLite3::Database.new "data.sqlite"

# Create table if not exists
db.execute <<-SQL
  CREATE TABLE IF NOT EXISTS advertisement_data (
    id INTEGER PRIMARY KEY,
    address TEXT,
    council_reference TEXT,
    advertised_date TEXT
  );
SQL

# Define the API endpoint and payload
uri = URI('https://portal.planbuild.tas.gov.au/api/advertisement/search')
headers = {
  'Content-Type' => 'application/json'
}

# Example LGA code (you'll want to loop through others)
lga_code = 'LGA003'  # Replace with actual code for a council

payload = {
  advertisementType: 'ALL',
  lgaCode: lga_code,
  offset: 0,
  pageSize: 100,
  sortField: 'advertisedDate',
  sortDirection: 'DESC'
}

# Make the request
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
request = Net::HTTP::Post.new(uri.request_uri, headers)
request.body = payload.to_json

logger.info("Sending request to API for LGA code: #{lga_code}")
response = http.request(request)

if response.code.to_i == 200
  results = JSON.parse(response.body)
  results['data'].each do |item|
    address = item['address']
    reference = item['applicationReference']
    date = item['advertisedDate']

    logger.info("Saving: #{address} | #{reference} | #{date}")

    db.execute("INSERT INTO advertisement_data (address, council_reference, advertised_date)
                VALUES (?, ?, ?)", [address, reference, date])
  end
else
  logger.error("API call failed with status #{response.code}")
end
