require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'nokogiri'
require 'sqlite3'
require 'time'

logger = Logger.new(STDOUT)

# Initialize the SQLite database
db = SQLite3::Database.new "data.sqlite"

# Create the table if it doesn't exist
db.execute <<-SQL
CREATE TABLE IF NOT EXISTS planbuild (
id INTEGER PRIMARY KEY,
description TEXT,
date_scraped TEXT,
date_received TEXT,
on_notice_to TEXT,
address TEXT,
council_reference TEXT,
applicant TEXT,
owner TEXT,
stage_description TEXT,
stage_status TEXT,
document_description TEXT,
title_reference TEXT,
pid_reference TEXT,
uuid TEXT,
pdf_data BLOB
);
SQL

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

# post_data = { "lgaCode" => "LGA003" }
# lga_codes = (1..29).map { |i| "LGA%03d" % i }
lga_codes = [
    "BREAK_ODAY", "BRIGHTON", "BURNIE", "CENTRAL_COAST", "CENTRAL_HIGHLANDS",
    "CIRCULAR_HEAD", "CLARENCE", "DERWENT_VALLEY", "DEVONPORT", "DORSET",
    "FLINDERS", "GEORGE_TOWN", "GLAMORGAN-SPRING_BAY", "GLENORCHY", "HOBART",
    "HUON_VALLEY", "KENTISH", "KINGBOROUGH", "KING_ISLAND", "LATROBE",
    "LAUNCESTON", "MEANDER_VALLEY", "NORTHERN_MIDLANDS", "SORELL",
    "SOUTHERN_MIDLANDS", "TASMAN", "WARATAH-WYNYARD", "WEST_COAST", "WEST_TAMAR"
    ]

lga_codes.each do |lga_code|
    logger.info("Fetching data for LGA: #{lga_code}")

    post_data = { "lgas" => [lga_code] }
    logger.info("LGA: #{lga_code} | First result: #{json.first['addressString'] rescue 'N/A'}")

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

        date_scraped = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")

        json.each do |item|
            # Convert startDate from milliseconds to YYYY-MM-DD, use as date_received
            date_received = (Time.at(item['startDate'] / 1000).utc.strftime("%Y-%m-%d") rescue nil)
            on_notice_to = (Time.at(item['endDate'] / 1000).utc.strftime("%Y-%m-%d") rescue nil)

            # Prepare values for DB insert (use empty string or nil where not available)
            description = item['description'] || ''
            address = item['addressString'] || ''
            council_reference = item['referenceNumber'] || ''
            pid_reference = item['pid'] || ''
            uuid = item['uuid'] || ''

            # Fields missing in API data, set to nil or empty string
            applicant = ''
            owner = ''
            stage_description = ''
            stage_status = ''
            document_description = ''
            title_reference = ''

            # Step 6: Ensure the entry does not already exist before inserting
            existing_entry = db.execute("SELECT * FROM planbuild WHERE council_reference = ?", council_reference )

            if existing_entry.empty? # Only insert if the entry doesn't already exist
                db.execute("INSERT INTO planbuild (description, date_scraped, date_received, on_notice_to, address, council_reference, applicant, owner, pid_reference, title_reference, stage_description, stage_status, document_description, uuid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    [description, date_scraped, date_received, on_notice_to, address, council_reference, applicant, owner, pid_reference, title_reference, stage_description, stage_status, document_description, uuid])
                logger.info("Saved: #{council_reference} - #{description}")
            else
                logger.info("Duplicate entry for application #{council_reference} found. Skipping insertion.")
            end

            # === Step 5a: Fetch attachment data and download PDFs ===
            begin
                ad_uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/#{uuid}/get")
                ad_request = Net::HTTP::Get.new(ad_uri)
                ad_request['Cookie'] = session_cookie
                ad_request['User-Agent'] = 'Mozilla/5.0'

                ad_response = http.request(ad_request)

                if ad_response.code == "200"
                    ad_data = JSON.parse(ad_response.body)
                    attachments = ad_data['attachments'] || []

                    attachments.each do |att|
                        attachment_id = att['id']
                        filename = att['name'] || "unknown_#{attachment_id}.pdf"
                        filename = filename.gsub(/[^0-9A-Za-z.\-]/, '_')  # Sanitize filename

                        file_uri = URI("https://portal.planbuild.tas.gov.au/external/advertisement/#{uuid}/attachment/#{attachment_id}")
                        file_request = Net::HTTP::Get.new(file_uri)
                        file_request['Cookie'] = session_cookie
                        file_request['User-Agent'] = 'Mozilla/5.0'

                        logger.info("Downloading PDF: #{filename}")
                        file_response = http.request(file_request)

                        if file_response.code == "200"
                            pdf_data = file_response.body

                            # Build multipart POST manually
                            boundary = "----RubyBoundary#{rand(1000000)}"
                            post_uri = URI("https://yourserver.com/upload-pdf.php")

                            multipart_body = []
                            multipart_body << "--#{boundary}\r\n"
                            multipart_body << "Content-Disposition: form-data; name=\"pdf\"; filename=\"#{filename}\"\r\n"
                            multipart_body << "Content-Type: application/pdf\r\n\r\n"
                            multipart_body << pdf_data
                            multipart_body << "\r\n--#{boundary}\r\n"

                            multipart_body << "Content-Disposition: form-data; name=\"uuid\"\r\n\r\n"
                            multipart_body << "#{uuid}\r\n--#{boundary}\r\n"

                            multipart_body << "Content-Disposition: form-data; name=\"council_reference\"\r\n\r\n"
                            multipart_body << "#{council_reference}\r\n--#{boundary}\r\n"

                            multipart_body << "Content-Disposition: form-data; name=\"token\"\r\n\r\n"
                            multipart_body << "MY_SECRET_TOKEN\r\n--#{boundary}--\r\n"

                            request = Net::HTTP::Post.new(post_uri)
                            request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
                            request.body = multipart_body.join

                            upload_http = Net::HTTP.new(post_uri.host, post_uri.port)
                            upload_http.use_ssl = (post_uri.scheme == "https")

                            response = upload_http.request(request)

                            if response.code == "200"
                                logger.info("✅ Uploaded #{filename} to server")
                            else
                                logger.error("❌ Upload failed for #{filename}: #{response.body}")
                            end
                        else
                            logger.warn("❌ Failed to download PDF for #{council_reference} (#{filename})")
                        end
                    end
                else
                    logger.warn("No attachment JSON for #{council_reference}")
                end
            rescue => e
                logger.error("Error retrieving attachments for #{council_reference}: #{e.message}")
            end
        end
    else
        logger.error("API call failed with status #{response.code}")
        logger.debug("Response body: #{response.body}")
    end
end
