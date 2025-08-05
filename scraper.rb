require 'mechanize'
require 'sqlite3'
require 'json'
require 'logger'

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

agent = Mechanize.new
agent.user_agent_alias = 'Windows Chrome'

# Visit the initial page to get cookies/session
logger.info("Visiting initial page to get session")
agent.get("https://portal.planbuild.tas.gov.au/external/advertisement/search")

# Now post to the JSON API
uri = 'https://portal.planbuild.tas.gov.au/api/advertisement/search'
payload = {
  advertisementType: 'ALL',
  lgaCode: 'LGA003',
  offset: 0,
  pageSize: 100,
  sortField: 'advertisedDate',
  sortDirection: 'DESC'
}

logger.info("Posting to API endpoint")
response = agent.post(uri, payload.to_json, {
  'Content-Type' => 'application/json',
  'Accept' => 'application/json'
})

if response.code == '200'
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
  logger.debug("Body: #{response.body}")
end
