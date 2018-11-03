#!/usr/bin/env ruby

## This script returns a table-formatted list of virtual machines from a Softlayer account.
## You can get a similar result using the popular slcli tool, but this script goes a step further
## since provides also information on the physical location of the machine (server room, slot, rack)
## or migration flag, which is a flag that indicates a machine is due to a migration:
## https://softlayer.github.io/reference/services/SoftLayer_Virtual_Guest/getPendingMigrationFlag/

require 'json'
require 'highline/import'
require 'optparse'
require 'parseconfig'
require 'pp'
require 'csv'
require 'rubygems'
require 'softlayer_api'
require 'terminal-table'
require 'table_print'

softlayer_config_files = ["vm.cfg", "#{ENV['HOME']}/.softlayer"]
softlayer_config = {}

csv_file = 'output.csv'

options = {}
option_parser = OptionParser.new do |opts|
  opts.banner = "This script generate a list of devices from softlayer\n### USAGE ###\nUsage: #{$PROGRAM_NAME} [options]"
  opts.on('-qQUERY', "--query=QUERY", 'Query specific hosts') do |v|
    options[:query] = v
  end
  opts.on('-c', '--csv', "Export csv to #{csv_file}") do |v|
    options[:csv] = true
  end
  opts.on('-m', '--migration', "Include migration information") do |v|
    options[:migration] = true
  end
  opts.on('-l', '--location', "Include location information") do |v|
    options[:location] = true
  end
end
begin option_parser.parse! ARGV
rescue OptionParser::InvalidOption => e
end

softlayer_config_files.each do |softlayer_config_file|
  if File.exist?(softlayer_config_file)
    softlayer_config = ParseConfig.new(softlayer_config_file)['softlayer']
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

  object_filter = SoftLayer::ObjectFilter.new
  object_filter.set_criteria_for_key_path('datacenterName', 'operation' => 'in', 'options' => [{'name': 'data', 'value': ['tor01', 'mon01', 'lon02']}])
  network_pod = sl_client.service_named('Network_Pod')
  pods = network_pod.object_filter(object_filter).getAllObjects
  pod_hash = {}
  pod_info = pods.map do |pod|
    pod_hash[pod['backendRouterName']] = pod['name']
    {
      name: pod['name'],
      router: pod['backendRouterName']
    }
  end

  account_service = sl_client.service_named('Account')

  mask = "mask[pendingMigrationFlag, location.pathString, networkComponents, blockDevices.diskImage, operatingSystemReferenceCode, backendRouters.backendRouters]"
  object_filter = SoftLayer::ObjectFilter.new

  if !options[:query].nil?
    object_filter.set_criteria_for_key_path('virtualGuests.hostname', 'operation' => '*=' + options[:query])
  end
  servers = account_service.object_filter(object_filter).object_mask(mask).getVirtualGuests()

  servers_info = servers.map do |server|

    disks = []
    index = 0
    datacenter, server_room, rack, slot = server['location']['pathString'].split('.')
    server['blockDevices'].each do |block|
      if block['diskImage']
        if block['diskImage']['description'] =~ /SWAP$/
          next
        end
        index += 1
        disks << 'Disk ' + index.to_s + ' ' + block['diskImage']['capacity'].to_s + ' ' + block['diskImage']['units']
      end
    end

    {
      name: server['fullyQualifiedDomainName'],
      dc: datacenter,
      pod: pod_hash[server['backendRouters'][0]['hostname']],
      location: server['location']['pathString'],
      cpu: server['maxCpu'],
      memory: server['maxMemory'],
      priv_link: server['networkComponents'][0]['speed'],
      publ_link: server['networkComponents'][1]['speed'],
      disks: disks.join(', '),
      os: server['operatingSystemReferenceCode'],
      migrate_flag: server['pendingMigrationFlag'] ? 'migrate' : ''
    }
  end

  tp servers_info,
    {:name => {:width => 120}},
    options[:location] ? :dc : '',
    options[:location] ? :pod : '',
    options[:location] ? :location : '',
    :cpu,
    :memory,
    :priv_link,
    :publ_link,
    :disks,
    :os,
    options[:migration] ? :migrate_flag : ''

  if !options[:csv].nil?
    CSV.open(csv_file, "w") do |csv|
      servers_info.each do |record|
        csv_record = [record[:name]]
        if options[:location]
          csv_record.push(record[:dc], record[:pod], record[:location])
        end
        csv_record.push(record[:cpu], record[:memory], record[:priv_link], record[:publ_link], record[:disks], record[:os])
        if options[:migration]
          csv_record.push(record[:migrate_flag])
        end
        if !options[:migration] || (options[:migration] && !record[:migrate_flag].empty?)
          csv << csv_record
        end
      end
    end
  end

rescue StandardError => exception
  $stderr.puts "An exception occurred: #{exception}"
end
