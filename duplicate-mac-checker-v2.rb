require 'sinatra'
require 'json'
require 'pg'

set :bind, '0.0.0.0'
set :port, 4567

def db_client
  @db_client ||= PG.connect(
    host: '127.0.0.1',
    port: 5432,
    dbname: 'duplicate_mac_checker',
    user: 'ruby',
    password: 'ruby'
  )
end

begin
  row = db_client.exec("SELECT current_database() AS db_name").first
  puts "Connected to database: #{row['db_name']}"
rescue => e
  puts "DATABASE CONNECTION FAILED: #{e.class} - #{e.message}"
end

def normalize_code(code)
  code.to_s.strip.upcase.gsub(/[^A-Z0-9]/, '')
end

def valid_mac?(mac)
  mac.length == 12
end

def imported_mac?(mac)
  return false unless valid_mac?(mac)

  row = db_client.exec_params(
    "SELECT 1 FROM master_mac_list_chicago WHERE mac = $1 AND UPPER(TRIM(tag_type)) = 'IMPORTED' LIMIT 1",
    [mac]
  ).first

  !!row
end

def scanned_master_mac?(mac)
  return false unless valid_mac?(mac)

  row = db_client.exec_params(
    "SELECT 1 FROM master_mac_list_chicago WHERE mac = $1 AND UPPER(TRIM(tag_type)) = 'SCANNED' LIMIT 1",
    [mac]
  ).first

  !!row
end

def scanned_before?(mac)
  return false unless valid_mac?(mac)

  row = db_client.exec_params(
    "SELECT 1 FROM scan_log_chicago WHERE screen_mac = $1 OR physical_mac = $1 LIMIT 1",
    [mac]
  ).first

  !!row
end

def exists_in_master?(mac)
  return false unless valid_mac?(mac)

  row = db_client.exec_params(
    "SELECT 1 FROM master_mac_list_chicago WHERE mac = $1 LIMIT 1",
    [mac]
  ).first

  !!row
end

def insert_master_mac(mac, worker)
  db_client.exec_params(
    "INSERT INTO master_mac_list_chicago (mac, tag_type, first_scanned_by, created_at)
     VALUES ($1, 'SCANNED', $2, NOW())
     ON CONFLICT (mac) DO NOTHING",
    [mac, worker]
  )
end

def insert_scan_log_chicago(
  screen_mac,
  physical_mac,
  worker,
  macs_match,
  result,
  box,
  screen_imported,
  physical_imported,
  screen_scanned_before,
  physical_scanned_before
)
  db_client.exec_params(
    "INSERT INTO scan_log_chicago
      (
        screen_mac,
        physical_mac,
        macs_match,
        worker,
        result,
        box,
        screen_imported,
        physical_imported,
        screen_scanned_before,
        physical_scanned_before
      )
     VALUES
      ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
    [
      screen_mac,
      physical_mac,
      macs_match,
      worker,
      result,
      box,
      screen_imported,
      physical_imported,
      screen_scanned_before,
      physical_scanned_before
    ]
  )
end

get '/' do
  erb :index
end

get '/history' do
  content_type :json

  worker = params[:worker].to_s.strip
  return [].to_json if worker.empty?

  rows = db_client.exec_params(<<~SQL, [worker]).to_a
    SELECT
      screen_mac,
      physical_mac,
      result,
      box,
      scanned_at
    FROM scan_log_chicago
    WHERE worker = $1
    ORDER BY id DESC
    LIMIT 10
  SQL

  rows.to_json
end

post '/scan_pair' do
  content_type :json

  screen_mac = normalize_code(params[:first_mac])
  physical_mac = normalize_code(params[:second_mac])
  worker = params[:worker].to_s.strip

  unless valid_mac?(screen_mac)
    insert_scan_log_chicago(
      screen_mac,
      physical_mac,
      worker,
      screen_mac == physical_mac,
      'SCREEN_MAC_INVALID_LENGTH',
      'BOX_REVIEW',
      false,
      false,
      false,
      false
    )

    return {
      result: 'SCREEN_MAC_INVALID_LENGTH',
      screen_mac: screen_mac,
      physical_mac: physical_mac
    }.to_json
  end

  unless valid_mac?(physical_mac)
    insert_scan_log_chicago(
      screen_mac,
      physical_mac,
      worker,
      screen_mac == physical_mac,
      'PHYSICAL_MAC_INVALID_LENGTH',
      'BOX_REVIEW',
      false,
      false,
      false,
      false
    )

    return {
      result: 'PHYSICAL_MAC_INVALID_LENGTH',
      screen_mac: screen_mac,
      physical_mac: physical_mac
    }.to_json
  end

  match = screen_mac == physical_mac

  screen_imported = imported_mac?(screen_mac)
  physical_imported = imported_mac?(physical_mac)

  screen_scanned_master = scanned_master_mac?(screen_mac)
  physical_scanned_master = scanned_master_mac?(physical_mac)

  screen_scanned_before = scanned_before?(screen_mac)
  physical_scanned_before = scanned_before?(physical_mac)

  result =
    if match && screen_imported && screen_scanned_before
      'SCENARIO_2_DUPLICATED_IMPORTED_MAC'
    elsif match && screen_imported
      'SCENARIO_1_IMPORTED_MATCH'
    elsif !match && (screen_imported || physical_imported)
      'SCENARIO_3_MISMATCH_WITH_IMPORTED_MAC'
    elsif match && screen_scanned_before
      'SCENARIO_4_DUPLICATED_SCANNED_MAC'
    elsif !match
      'SCENARIO_5_NEW_MISMATCH'
    else
      'GOOD_TAG'
    end

  box =
    case result
    when 'SCENARIO_1_IMPORTED_MATCH' then 'BOX_1'
    when 'SCENARIO_2_DUPLICATED_IMPORTED_MAC' then 'BOX_2'
    when 'SCENARIO_3_MISMATCH_WITH_IMPORTED_MAC' then 'BOX_3'
    when 'SCENARIO_4_DUPLICATED_SCANNED_MAC' then 'BOX_4'
    when 'SCENARIO_5_NEW_MISMATCH' then 'BOX_5'
    when 'GOOD_TAG' then 'BOX_GOOD'
    else 'BOX_REVIEW'
    end

  if result == 'GOOD_TAG'
    insert_master_mac(screen_mac, worker)
    insert_master_mac(physical_mac, worker)
  end

  insert_scan_log_chicago(
    screen_mac,
    physical_mac,
    worker,
    match,
    result,
    box,
    screen_imported,
    physical_imported,
    screen_scanned_before,
    physical_scanned_before
  )

  {
    result: result,
    box: box,
    screen_mac: screen_mac,
    physical_mac: physical_mac
  }.to_json
end