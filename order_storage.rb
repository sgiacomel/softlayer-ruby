#!/usr/bin/env ruby

## This script orders a portable storage device.
## More info on the Softlayer page: 
## https://www.softlayer.com/Store/orderService/objectStorage

require 'json'
require 'highline/import'
require 'optparse'
require 'parseconfig'
require 'pp'
require 'rubygems'
require 'softlayer_api'
require 'terminal-table'

softlayer_config_files = ["storage.cfg", "#{ENV['HOME']}/.softlayer"]
softlayer_config = {}

$types=["PORTABLE_STORAGE", "NETWORK_ATTACHED_STORAGE"]
$locations=["tor01", "mon01", "lon02"]

def print_help()
  puts '### USAGE ###'
  puts 'This script orders a new portable storage device'
  puts "Usage: #{$PROGRAM_NAME} TYPE CAPACITY_IN_GB DATA_CENTER DESCRIPTION"
  puts "TYPE: "  + $types.join(', ')
  puts "LOCATION: "  + $locations.join(', ')
  puts 'Options:'
  puts '  --yes       skip confirm and apply changes'
  exit 1
end

if ARGV[0].nil?
  print_help
end

if !ARGV[0] || !$types.include?(ARGV[0])
  puts "Valid values for TYPE are: " + $types.join(', ')
  print_help
  exit 1
else
  type = ARGV[0]
  ARGV.shift
end

if ARGV[0] == ARGV[0].to_i.to_s
  capacity = ARGV[0]
  ARGV.shift
else
  puts 'The capacity argument must be a valid integer'
  print_help
  exit 1
end

if !ARGV[0] || !$locations.include?(ARGV[0])
  puts "Valid values for DATA_CENTER are: " + $locations.join(', ')
  print_help
  exit 1
else
  location = ARGV[0]
  ARGV.shift
end

if !ARGV[0]
  puts "The description is required"
  print_help
  exit 1
else
  description = ARGV[0]
  ARGV.shift
end

skip_confirm = false
ARGV.each do |argument|
  case argument
  when '--yes'
    skip_confirm = true
  else
    puts "Invalid parameter '#{argument}'"
    exit 1
  end
end

softlayer_config_files.each do |softlayer_config_file|
  if File.exist?(softlayer_config_file)
    softlayer_config = ParseConfig.new(softlayer_config_file)['softlayer']
    puts 'Found config at ' + softlayer_config_file
    break
  end
end

if softlayer_config.nil? || softlayer_config.empty?
  puts "You need to setup a config file with valid credentials at one of these locations: " + softlayer_config_files.join(' ')
  puts "Example:"
  puts "[softlayer]"
  puts "username = user"
  puts "api_key = abcdefghijklmnopqrstuvwxyz0123456789"
  puts "endpoint_url = https://api.softlayer.com/xmlrpc/v3.1/"
  puts "timeout = 0"
  exit 1
end

begin
  sl_client = SoftLayer::Client.new(
    :username => softlayer_config['username'],
    :api_key => softlayer_config['api_key'],
    :timeout => nil,
    :endpoint_url => softlayer_config['endpoint_url']
  )
  mask = "mask[
    groups
  ]"
  order_service = sl_client.service_named('Product_Order')
  object_filter = SoftLayer::ObjectFilter.new
  key = 'name'
  value = location
  object_filter.set_criteria_for_key_path(key, 'operation' => value)
  datacenters = sl_client.service_named('Location_Datacenter').object_mask(mask).object_filter(object_filter).getDatacenters

  if datacenters.length != 1
    puts "Error retrieving #{key} `#{value}`"
    exit 1
  end
  dc_id = datacenters[0]['id']

  object_filter = SoftLayer::ObjectFilter.new
  object_filter.set_criteria_for_key_path('keyName', 'operation' => type)
  object_filter.set_criteria_for_key_path('isActive', 'operation' => 1)
  packages = sl_client.service_named('Product_Package').object_filter(object_filter).getAllObjects
  if packages.length != 1
    puts "Error retrieving #{key} `#{value}`"
    exit 1
  end
  package_id = packages[0]['id']

  mask = "mask[
    itemCategory
  ]"
  object_filter = SoftLayer::ObjectFilter.new
  key = 'configuration.isRequired'
  value = 1
  object_filter.set_criteria_for_key_path(key, 'operation' => value)
  package = sl_client.service_named('Product_Package').object_filter(object_filter).object_mask(mask).object_with_id(package_id).getConfiguration

  object_filter = SoftLayer::ObjectFilter.new
  key = 'itemPrices.item.capacity'
  value = capacity
  object_filter.set_criteria_for_key_path(key, 'operation' => value)

  groups = []
  datacenters[0]['groups'].each do |group|
    groups << group['id']
  end

  all_prices = sl_client.service_named('Product_Package').object_with_id(package_id).object_filter(object_filter).getItemPrices
  prices = []
  locations = []
  capacities = []
  all_prices.each do |price|
    if groups.include? price['locationGroupId']
      locations << price['locationGroupId']
      prices << { 'id' => price['id'] }
    end
  end
  # If there are no prices, we print the options
  if prices.empty?
    all_prices = sl_client.service_named('Product_Package').object_with_id(package_id).getItemPrices
    all_prices.each do |price|
      if groups.include? price['locationGroupId']
        capacities << price['item']['capacity'].to_i
      end
    end
    puts "Available options for capacity are:"
    capacities.sort.each do |cap|
      puts cap
    end
  end

  if type == 'PORTABLE_STORAGE'

    template = {
      'location'=> dc_id,
      'packageId'=> package_id,
      'prices' => prices,
      'diskDescription' => description,
      'complexType' => 'SoftLayer_Container_Product_Order_Virtual_Disk_Image',
    }

  elsif

    template = {
      'location'=> dc_id,
      'packageId'=> package_id,
      'prices' => prices,
      'message' => description,
      'complexType' => 'SoftLayer_Container_Product_Order_Network_Storage_Nas',
    }

  end

  verify_result = order_service.verifyOrder(template)
  if verify_result.is_a?(Object)
    if !skip_confirm
      exit unless HighLine.agree("You are about to order a #{type} with #{capacity} GB in #{location} with description '#{description}'. Confirm?")
    end
    result = order_service.placeOrder(template)
    puts 'Success!'
  else
    puts 'There was an error verifying the order:'
    pp verify_result
  end

rescue StandardError => exception
  $stderr.puts "An exception occurred: #{exception}"
end
