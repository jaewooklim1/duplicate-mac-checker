require_relative 'spec_helper'

RSpec.describe 'POST /scan_pair' do
  def json
    JSON.parse(last_response.body)
  end

  if ENV['RACK_ENV'] != 'test'
    raise "Refusing to run tests on non-test database"
    end

  before(:each) do
    # db_client.execute("DELETE FROM known_macs WHERE source_type = 'SCANNED'").do
    # db_client.execute("DELETE FROM scan_log").do

    db_client.execute(<<~SQL).do
      IF NOT EXISTS (
        SELECT 1 FROM known_macs WHERE mac = 'AAAAAAAAAAAA'
      )
      INSERT INTO known_macs (mac, source_type, source_file)
      VALUES ('AAAAAAAAAAAA', 'IMPORTED', 'test')
    SQL
  end

  it 'accepts matching unique valid MACs' do
    post '/scan_pair', {
      first_mac: 'BBBBBBBBBBBB',
      second_mac: 'BBBBBBBBBBBB',
      worker: 'TEST_USER'
    }

    expect(last_response).to be_ok
    expect(json['result']).to eq('GOOD')
    expect(json['reason']).to eq('ACCEPTED_MATCH')
  end

  it 'rejects matching imported MACs' do
    post '/scan_pair', {
      first_mac: 'AAAAAAAAAAAA',
      second_mac: 'AAAAAAAAAAAA',
      worker: 'TEST_USER'
    }

    expect(last_response).to be_ok
    expect(json['result']).to eq('NOT GOOD')
    expect(json['reason']).to eq('MATCH_BUT_BAD')
  end

  it 'rejects mismatching unique MACs' do
    post '/scan_pair', {
      first_mac: 'BBBBBBBBBBBB',
      second_mac: 'CCCCCCCCCCCC',
      worker: 'TEST_USER'
    }

    expect(last_response).to be_ok
    expect(json['result']).to eq('NOT GOOD')
    expect(json['reason']).to eq('MISMATCH')
  end

  it 'rejects invalid first MAC length' do
    post '/scan_pair', {
      first_mac: 'SHORT',
      second_mac: 'BBBBBBBBBBBB',
      worker: 'TEST_USER'
    }

    expect(last_response).to be_ok
    expect(json['result']).to eq('NOT GOOD')
  end

  it 'rejects invalid second MAC length' do
    post '/scan_pair', {
      first_mac: 'BBBBBBBBBBBB',
      second_mac: 'SHORT',
      worker: 'TEST_USER'
    }

    expect(last_response).to be_ok
    expect(json['result']).to eq('NOT GOOD')
  end
end