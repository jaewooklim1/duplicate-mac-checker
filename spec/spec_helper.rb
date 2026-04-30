ENV['RACK_ENV'] = 'test'

require 'rack/test'
require 'rspec'
require_relative '../duplicate-mac-checker-v2'

RSpec.configure do |config|
  config.include Rack::Test::Methods

  def app
    Sinatra::Application
  end
end