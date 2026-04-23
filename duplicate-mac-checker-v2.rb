require 'sinatra'
require 'json'
require 'tiny_tds'

set :bind, '0.0.0.0'
set :port, 4567

def db_client
  @db_client ||= TinyTds::Client.new(
    host: 'localhost',
    database: 'DuplicateMacChecker',
    trusted_connection: true
  )
end

begin
  row = db_client.execute("SELECT DB_NAME() AS db_name").first
  puts "Connected to database: #{row['db_name']}"
rescue => e
  puts "DATABASE CONNECTION FAILED: #{e.class} - #{e.message}"
end

def normalize_code(code)
  code.to_s.strip.upcase
end

get '/' do
  erb :index
end

get '/history' do
  worker = params[:worker].to_s.strip.upcase

  if worker.empty?
    content_type :json
    return [].to_json
  end

  rows = db_client.execute(<<~SQL).each(as: :hash).to_a
    SELECT TOP 10
      sl.mac,
      sl.result,
      sl.reason,
      sl.scanned_at,
      km.first_scanned_by AS last_scanned_by,
      km.created_at AS last_scanned_at
    FROM scan_log sl
    LEFT JOIN known_macs km
      ON sl.mac = km.mac
    WHERE sl.worker = '#{worker.gsub("'", "''")}'
    ORDER BY sl.id DESC
  SQL

  content_type :json
  rows.to_json
end

post '/scan' do
  content_type :json

  puts "SCAN HIT: #{params.inspect}"

  code = normalize_code(params[:code])
  worker = params[:worker].to_s.strip
  station = params[:station].to_s.strip

  if code.empty?
    status 400
    return {
      result: 'NOT GOOD',
      reason: 'EMPTY_CODE'
    }.to_json
  end

  existing = db_client.execute(<<~SQL).first
    SELECT TOP 1
      source_type,
      first_scanned_by,
      created_at
    FROM known_macs
    WHERE mac = '#{code.gsub("'", "''")}'
  SQL

  if existing
    reason = existing['source_type'] == 'IMPORTED' ? 'IMPORTED_LIST' : 'ALREADY_SCANNED'

    db_client.execute(<<~SQL).do
      INSERT INTO scan_log (mac, worker, station, result, reason)
      VALUES (
        '#{code.gsub("'", "''")}',
        '#{worker.gsub("'", "''")}',
        '#{station.gsub("'", "''")}',
        'NOT GOOD',
        '#{reason}'
      )
    SQL

     return {
        result: 'NOT GOOD',
        reason: reason,
        last_scanned_by: existing['first_scanned_by'],
        last_scanned_at: existing['created_at']
      }.to_json
  end

  begin
    db_client.execute(<<~SQL).do
      INSERT INTO known_macs (mac, source_type, first_scanned_by, first_station)
      VALUES (
        '#{code.gsub("'", "''")}',
        'SCANNED',
        '#{worker.gsub("'", "''")}',
        '#{station.gsub("'", "''")}'
      )
    SQL

    db_client.execute(<<~SQL).do
      INSERT INTO scan_log (mac, worker, station, result, reason)
      VALUES (
        '#{code.gsub("'", "''")}',
        '#{worker.gsub("'", "''")}',
        '#{station.gsub("'", "''")}',
        'GOOD',
        'ACCEPTED'
      )
    SQL

    {
      result: 'GOOD',
      reason: 'ACCEPTED'
    }.to_json
  rescue TinyTds::Error
    db_client.execute(<<~SQL).do
      INSERT INTO scan_log (mac, worker, station, result, reason)
      VALUES (
        '#{code.gsub("'", "''")}',
        '#{worker.gsub("'", "''")}',
        '#{station.gsub("'", "''")}',
        'NOT GOOD',
        'ALREADY_SCANNED'
      )
    SQL

    {
      result: 'NOT GOOD',
      reason: 'ALREADY_SCANNED'
    }.to_json
  end
end