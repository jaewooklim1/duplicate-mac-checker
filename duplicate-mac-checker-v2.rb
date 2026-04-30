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

post '/scan_pair' do
  content_type :json

  first_mac = normalize_code(params[:first_mac])
  second_mac = normalize_code(params[:second_mac])
  worker = params[:worker].to_s.strip
  station = params[:station].to_s.strip

  def sql_safe(value)
    value.to_s.gsub("'", "''")
  end

  def valid_mac?(mac)
    mac.length == 12
  end

  def mac_exists?(mac)
    db_client.execute(<<~SQL).first
      SELECT TOP 1 source_type
      FROM known_macs
      WHERE mac = '#{sql_safe(mac)}'
    SQL
  end

  first_valid = valid_mac?(first_mac)
  second_valid = valid_mac?(second_mac)

  first_exists = first_valid ? mac_exists?(first_mac) : true
  second_exists = second_valid ? mac_exists?(second_mac) : true

  first_good = first_valid && !first_exists
  second_good = second_valid && !second_exists

  match = first_mac == second_mac

  first_result = first_good ? 'GOOD' : 'NOT GOOD'
  second_result = second_good ? 'GOOD' : 'NOT GOOD'

  first_reason =
    if !first_valid
      'INVALID_LENGTH'
    elsif first_exists
      first_exists['source_type'] == 'IMPORTED' ? 'IMPORTED_LIST' : 'ALREADY_SCANNED'
    else
      'UNIQUE'
    end

  second_reason =
    if !second_valid
      'INVALID_LENGTH'
    elsif second_exists
      second_exists['source_type'] == 'IMPORTED' ? 'IMPORTED_LIST' : 'ALREADY_SCANNED'
    elsif match
      'UNIQUE + MATCH'
    else
      'UNIQUE + MISMATCH'
    end

  # Write both scans to scan_log
  db_client.execute(<<~SQL).do
    INSERT INTO scan_log (mac, worker, station, result, reason)
    VALUES (
      '#{sql_safe(first_mac)}',
      '#{sql_safe(worker)}',
      '#{sql_safe(station)}',
      '#{first_result}',
      '#{first_reason}'
    )
  SQL

  db_client.execute(<<~SQL).do
    INSERT INTO scan_log (mac, worker, station, result, reason)
    VALUES (
      '#{sql_safe(second_mac)}',
      '#{sql_safe(worker)}',
      '#{sql_safe(station)}',
      '#{second_result}',
      '#{second_reason}'
    )
  SQL

  # Write to known_macs based on your table
  if match
    if first_good && second_good
      db_client.execute(<<~SQL).do
        INSERT INTO known_macs (mac, source_type, first_scanned_by, first_station)
        VALUES (
          '#{sql_safe(first_mac)}',
          'SCANNED',
          '#{sql_safe(worker)}',
          '#{sql_safe(station)}'
        )
      SQL
    end
  else
    if first_good
      db_client.execute(<<~SQL).do
        INSERT INTO known_macs (mac, source_type, first_scanned_by, first_station)
        VALUES (
          '#{sql_safe(first_mac)}',
          'SCANNED',
          '#{sql_safe(worker)}',
          '#{sql_safe(station)}'
        )
      SQL
    end

    if second_good
      db_client.execute(<<~SQL).do
        INSERT INTO known_macs (mac, source_type, first_scanned_by, first_station)
        VALUES (
          '#{sql_safe(second_mac)}',
          'SCANNED',
          '#{sql_safe(worker)}',
          '#{sql_safe(station)}'
        )
      SQL
    end
  end

  final_result = first_good && second_good && match ? 'GOOD' : 'NOT GOOD'
  final_reason =
    if match && first_good && second_good
      'ACCEPTED_MATCH'
    elsif match
      'MATCH BUT BOTH BAD'
    else
      'MISMATCH'
    end

  {
    result: final_result,
    reason: final_reason,
    first_mac: first_mac,
    second_mac: second_mac,
    first_result: first_result,
    second_result: second_result,
    first_reason: first_reason,
    second_reason: second_reason
  }.to_json
end