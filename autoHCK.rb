#!/usr/bin/env ruby

require 'fileutils'
require 'octokit'
require 'net/ping'
require 'rtoolsHCK'
require 'nori/parser/rexml'
require 'filelock'
require 'logger'
require 'mixlib/cli'
require 'net-telnet'
require 'ruby-progressbar'
require './dropbox_api'

class MyCLI
  include Mixlib::CLI

  option :driver,
    :short => "-t [PROJECT]-[OS][ARCH]",
    :long  => "--tag [PROJECT]-[OS][ARCH]",
    :description => "The driver name and architecture",
    :required => true

  option :path,
    :short => "-p [PATH-TO-DRIVER]",
    :long  => "--path [PATH-TO-DRIVER]",
    :description => "The location of the driver",
    :required => true

  option :commit,
    :short => "-c <COMMIT-HASH>",
    :long  => "--commit <COMMIT-HASH>",
    :description => "Commit hash for updating github status"

  option :diff,
    :short => "-d <DIFF-LIST-FILE>",
    :long  => "--diff <DIFF-LIST-FILE>",
    :description => "The location of the driver"

  option :debug,
    :short => "-D",
    :long  => "--debug",
    :description => "print debug information"
end

cli = MyCLI.new
cli.parse_options

# MultiIO class for the Ruby logger
class MultiIO
  def initialize(*targets)
    @targets = targets
  end

  def write(*args)
    @targets.each { |t| t.write(*args) }
  end

  def close
    @targets.each(&:close)
  end
end

def create_snapshot(source, target, tag, timestamp)
  cmd = ["cd #{VIRTHCK}/images/#{tag}/#{timestamp} &&",
         "#{QEMU_IMG} create -f qcow2 -b ../../#{source}.qcow2 #{target}.qcow2"]
  system(cmd.join(' '))
end

def renew_snapshots(platform, tag, support)
  machines = [STUDIO, CLIENT1]
  machines << CLIENT2 if support

  timestamp = Time.now.strftime('%Y_%m_%d_%H_%M_%S')
  path = "#{VIRTHCK}images/#{tag}/#{timestamp}"
  FileUtils.mkdir_p(path)
  machines.each do |machine|
    snapshot = "#{machine}-snapshot-#{tag}"
    base = if machine == STUDIO
             platform['kit']
           else
             "#{platform['kit']}-#{machine}-#{platform['name']}"
           end
    create_snapshot(base, snapshot, tag, timestamp)
  end
  timestamp
end

def machine_cmd(machine, tag, platform, timestamp)
  [
    "-#{machine}_image images/#{tag}/#{timestamp}/#{machine}-snapshot-#{tag}.qcow2",
    "-#{machine}_cpus #{platform["#{machine}_cpus"]}",
    "-#{machine}_memory #{platform["#{machine}_memory"]}"
  ]
end

def device_cmd(device)
  [
    "-device_type #{device['type']}",
    !device['name'].empty? ? "-device_name #{device['name']}" : '',
    !device['extra'].empty? ? "-device_extra #{device['extra']}" : ''
  ]
end

def run_machine(tag, platform, machine, timestamp, device = nil, support = false)
  cmd = [
    "cd #{VIRTHCK} &&",
    'sudo ./hck.sh ci_mode',
    "-world_bridge #{BRIDGE}",
    "-qemu_bin #{QEMU_BIN}",
    "-ctrl_net_device #{platform['ctrl_net_device']}",
    "-world_net_device #{platform['world_net_device']}",
    "-file_transfer_device #{platform['file_transfer_device']}",
    "-id #{platform['id']}",
    "-st_image images/#{tag}/#{timestamp}/st-snapshot-#{tag}.qcow2"
  ]
  if device
    cmd += device_cmd(device)
    cmd += machine_cmd(CLIENT1, tag, platform, timestamp)
    cmd += machine_cmd(CLIENT2, tag, platform, timestamp) if support == true
  end
  cmd += [machine]
  system(cmd.join(' '))
end

def keep_alive(client, device, platform, timestamp, tag)
  device = device['device']
  support = device['support']
  run_machine(tag, platform, client, timestamp, device, support) unless client_alive?(client[-1], platform['id'])
end

def client_alive?(client_id, platform_id)
  id = platform_id.to_s.rjust(4, '0')
  cmd = "ps -A -o cmd | grep '[\-]name HCK-Client#{client_id}_#{id}'"
  `#{cmd}`.split("\n").any?
end

def up?(host)
  check = Net::Ping::External.new(host)
  check.ping?
end

def update_filters
  return unless File.file?(HCK_FILTERS_PATH)
  @logger.info('Updating HCK filters')
  @tools.update_filters(HCK_FILTERS_PATH)
end

def setup_studio(tag, platform, logs_path, timestamp)
  run_machine(tag, platform, STUDIO, timestamp)
  sleep 10
  address = "#{IP}#{platform['id']}"
  sleep 2 until up?(address)
  connect(address, logs_path)
  create_pool(tag)
  create_project(tag)
  update_filters
end

def connect(address, logs_path)
  @logger.info("connecting to #{address}...")
  @tools = RToolsHCK.new(
    addr: address,
    user: USERNAME,
    pass: PASSWORD,
    winrm_ports: CLIENTS_WINRM_PORTS,
    outp_dir: logs_path,
    logger: @logger,
    script_file: TOOLSHCK
  )
end

def fetch_pools
  res = @tools.list_pools
  raise res['message'] if res['result'] == 'Failure'
  res['content']
end

def create_pool(pool_name)
  @logger.info("creating pool #{pool_name}")
  res = @tools.create_pool(pool_name)
  raise res['message'] if res['result'] == 'Failure'
  res['content']
end

def set_machine_ready(machine, pool)
  @logger.info("set machine #{machine} in pool #{pool} to ready...")
  res = @tools.set_machine_state(machine, pool, 'ready')
  raise res['message'] if res['result'] == 'Failure'
end

def move_machine(machine, source, target)
  @logger.info("moving #{machine} from #{source} to #{target}")
  res = @tools.move_machine(machine, source, target)
  raise res['message'] if res['result'] == 'Failure'
end

def install_driver(machine, install_method, driver)
  file = driver.split('/').last
  path = driver[0..-(file.length + 2)]
  @logger.info("installing #{file} driver on #{machine}")
  res = @tools.install_machine_driver_package(machine, install_method, path, file)
  raise res['message'] if res['result'] == 'Failure'
end

def restart_machine(machine)
  @logger.info("restarting #{machine}")
  @tools.machine_shutdown(machine, :restart)
end

def delete_machine(machine, pool)
  @logger.info("deleting machine #{machine} from #{pool}")
  @tools.delete_machine(machine, pool)
end

def get_client_when_up(clients_count)
  sleep 5 while fetch_pools.first['machines'].count == clients_count
  @logger.info("Recognized new client, waiting for initialization")
  sleep 5 while fetch_pools.first['machines'].last['state'] == 'Initializing'
  @logger.info("Client initialized")
  fetch_pools.first['machines'].last
end

def setup_client(device, platform, tag, driver_path, install_method, client, timestamp)
  clients_count = fetch_pools.first['machines'].count
  run_machine(tag, platform, client, timestamp, device['device'], device['support'])
  machine = get_client_when_up(clients_count)
  sleep 120
  install_driver(machine['name'], install_method, driver_path)
  delete_machine(machine['name'], 'Default Pool')
  restart_machine(machine['name'])
  machine = get_client_when_up(clients_count)
  move_machine(machine['name'], 'Default Pool', tag)
  set_machine_ready(machine['name'], tag)
end

def create_project(project)
  @logger.info("creating project #{project}")
  res = @tools.create_project(project)
  raise res['message'] if res['result'] == 'Failure'
end

def fetch_targets(pool, machine)
  @logger.info("listing #{machine} targets.")
  res = @tools.list_machine_targets(machine, pool)
  raise res['message'] if res['result'] == 'Failure'
  raise 'empty targets in machine.' if res.empty?
  res['content']
end

def search_target(targets, arg_target)
  @logger.info("searching for target by name '#{arg_target}'...")
  targets.each do |target|
    if target['name'].include?(arg_target)
      @logger.info("target '#{target['name']}' found.")
      return target
    end
  end
  @logger.info(targets)
  raise 'target not found'
end

def add_target_to_project(pool, machine, project, target)
  @logger.info("adding target: #{target['name']} to project #{project}")
  res = @tools.create_project_target(target['key'],
                                     project,
                                     machine,
                                     pool)
  raise res['message'] if res['result'] == 'Failure'
end

def time_to_seconds(time)
  time.split(':')
      .reverse
      .map
      .with_index { |a, i| a.to_i * (60**i) }
      .reduce(:+)
end

def list_tests(pool, machine, project, target, kit)
  @logger.info("listing tests in target: #{target['name']}")
  playlist = kit[0..2] == 'HLK' ? "playlists/#{kit[3..-1]}.xml" : nil
  res = @tools.list_tests(target['key'],
                          project,
                          machine,
                          pool,
                          nil,
                          nil,
                          playlist)
  raise res['message'] if res['result'] == 'Failure'
  tests = res['content']
  @logger.info("found #{tests.count} tests.")
  tests.each_with_index do |x, i|
    tests[i]['duration'] = time_to_seconds(x['estimatedruntime'])
  end
  tests.sort_by { |test| test['duration'] }
end

def queue_test(pool, machine, support, project, target, test)
  @logger.info('adding test to queue...')
  ipv6 = nil
  unless (test['scheduleoptions'] & %w[6 RequiresMultipleMachines]) != []
    support = nil
  end
  res = @tools.queue_test(test['id'], target['key'], project, machine, pool, support, ipv6)
  raise res['message'] if res['result'] == 'Failure'
end

def apply_filters(project)
  @logger.info('Applying HCK filters to tests results')
  @tools.apply_project_filters(project)
end

def process_test(pool, timestamp, machine, project, target, device, platform, test)
  res = ''
  loop do
    begin
      res = @tools.get_test_info(test['id'], target['key'], project, machine, pool)
    rescue StandardError => e
      @logger.error(e)
      sleep 30
      retry
    end
    break if res['content']['executionstate'] != 'InQueue'
    sleep 30
  end
  @logger.info('test now running...')
  bar = ProgressBar.create(format: '%a %B %p%% %t', total: test['duration'] * 1.5)
  loop do
    if bar.finished?
      sleep 30
    else
      30.times do
        bar.increment
        sleep 1
      end
    end
    begin
      res = @tools.get_test_info(test['id'], target['key'], project, machine, pool)
    rescue StandardError => e
      @logger.error(e)
      sleep 30
      retry
    end
    keep_alive(CLIENT1, device, platform, timestamp, project)
    keep_alive(CLIENT2, device, platform, timestamp, project) if device['support']
    if ([res['content']['status']] & %w[Failed Passed]).any?
      if (res['content']['status'] == 'Failed')
        apply_filters(project)
        sleep APPLY_FILTERS_SECONDS_WAIT
        res = @tools.get_test_info(test['id'], target['key'], project, machine, pool)
      end
      @logger.info("tests results: #{res['content']['status']}")
      break
    end
  end
  bar.finish
  res
end

def archive_results(pool, machine, project, target, test)
    res = @tools.zip_test_result_logs(-1, test['id'],
                                      target['key'],
                                      project,
                                      machine,
                                      pool)
    if res['result'] == 'Failure'
      @logger.info("Archiving results failed: #{res['message']}")
    else
      @logger.info('Archiving results succeded')
      path = res['content']['hostlogszippath']
      dropbox_upload(path, "(#{res['content']['status']}): #{test['name']}")
    end
end

def dropbox_upload(file_path, file_name = nil)
  if @dropbox && @dropbox.connected?
    begin
      @dropbox.upload_file(file_path, file_name)
    rescue StandardError
      @logger.error('Error uploading to dropbox shared folder: #{$!}')
    end
    @logger.info('File uploaded to dropbox shared folder')
  end
end

def create_project_package(project)
  bar = ProgressBar.create
  handler = proc do |progress_package|
    progress_package['steps'].each { |step|
      next unless step.is_a?(Hash)
      bar.total = step['maximum'] if step['maximum'] > bar.total
      bar.progress = step['current'] if step['current'] > bar.progress
      bar.title = step['message']
    }
  end
  res = @tools.create_project_package(project, handler)
  path = res['content']['hostprojectpackagepath']
  dropbox_upload(path, project)
  @logger.info("Results package successfully created at: #{path}")
end

def qemu_monitor(platform, machine, cmd)
  i = { STUDIO => 2, CLIENT1 => 1, CLIENT2 => 0 }
  port = platform['id'].to_i * 3 + 10_000 - i[machine]
  begin
    monitor = Net::Telnet.new('Host' => 'localhost',
                              'Port' => port,
                              'Timeout' => QEMU_MONITOR_TELNET_TIMEOUT,
                              'Prompt' => /(qemu)\z/n)
    monitor.cmd(cmd)
  rescue
  end
end

def force_shutdown(platform, machine)
  qemu_monitor(platform, machine, 'quit')
end

def shutdown(platform, machine)
  qemu_monitor(platform, machine, 'system_shutdown')
end

def shutdown_machine(platform, machine)
  @logger.info("shutting down #{machine}")
  shutdown(platform, machine)
  sleep 60
  force_shutdown(platform, machine)
end

def shutdown_all(platform, support)
  shutdown_machine(platform, CLIENT1)
  shutdown_machine(platform, CLIENT2) if support == true
  shutdown_machine(platform, STUDIO)
  cmd = [
    "cd #{VIRTHCK} &&",
    'sudo ./hck.sh ci_mode',
    "-id #{platform['id']}",
    "-world_bridge #{BRIDGE}",
    'end'
  ]
  system(cmd.join(' '))
end

def file_to_array(file)
  array = []
  File.open(file, 'r') do |file_handle|
    file_handle.each_line do |line|
      array.push(line)
    end
  end
  array
end

def filter_diff_array(diff_arr)
  diff_arr.reject { |file| file.end_with?('.md', '.txt') }
          .map! { |file| file.split('/').first }
          .uniq
end

def info_page(id)
  url = 'https://docs.microsoft.com/en-us/windows-hardware/test/hlk/testref/'
  "info page: #{url}#{id}"
end

def create_status(repo, commit, tag, total, current, failed)
  if current < total
    state = 'pending'
    description = "Running tests (#{current}/#{total}) #{failed} failed"
  else
    if failed == 0
      state = 'success'
      description = "All #{total} tests passed"
    else
      state = 'failure'
      description = "#{total - failed} tests passed out of #{total} tests"
    end
  end
  begin
    @github.create_status(repo,
                          commit,
                          state,
                          { :context => "HCK-CI/#{tag}" ,
                            :target_url => @db_url,
                            :description => description})
    @logger.info('Github status updated')
  rescue
    @logger.error('Updating github status failed')
  end
end

arg_project = cli.config[:driver]
arg_path = cli.config[:path]
arg_diff = cli.config[:diff]
arg_commit = cli.config[:commit]
arg_path = arg_path.slice!(-1) if arg_path.end_with? '/'
arg_debug = cli.config[:debug]

devices = JSON.parse(File.read('devices.json'))
config = JSON.parse(File.read('config.json'))

arg_device = arg_project.split('-').first
arg_platform = arg_project.split('-').last

HCK_FILTERS_PATH = 'filters/UpdateFilters.sql'

QEMU_MONITOR_TELNET_TIMEOUT = 30
APPLY_FILTERS_SECONDS_WAIT = 40

VIRTHCK = config['virthck_path']
QEMU_BIN = config['qemu_bin']
QEMU_IMG = config['qemu_img']
IP = config['ip_segment']
TOOLSHCK = config['toolshck_path']
USERNAME = config['studio_username']
PASSWORD = config['studio_password']
BRIDGE = config['dhcp_bridge']

STUDIO = 'st'
CLIENT1 = 'c1'
CLIENT2 = 'c2'

# fixes issue with ping -i 
ENV.store('LC_ALL','en_US.UTF-8')

device = devices.find { |i| i['short'] == arg_device }
unless device
  puts "There is no '#{arg_device}' device, please check configuration file."
  exit(false)
end

platform = device['platforms'].find { |i| i['name'] == arg_platform }
unless platform
  puts "The device '#{arg_device}' don't dave a #{arg_platform} platform, please check configuration file."
  exit(false)
end

driver_path = "#{arg_path}/#{device['inf']}"
install_method = device['install_method']
playlist_tests = device['playlist']
blacklist_tests = device['blacklist']

support = device['support']

CLIENTS_WINRM_PORTS = {}
CLIENTS_WINRM_PORTS[platform["#{CLIENT1}_name"]] = platform["#{CLIENT1}_port"]
if support
  CLIENTS_WINRM_PORTS[platform["#{CLIENT2}_name"]] = platform["#{CLIENT2}_port"]
end
CLIENTS_WINRM_PORTS

tag = "#{device['short']}-#{platform['name']}"
github_creds = config['github_credentials']
@github = Octokit::Client.new(:login => github_creds['login'],
                              :password => github_creds['password'])

log_file = File.open("#{arg_path}/debug.log", 'a')
@logger = Logger.new MultiIO.new(STDOUT, log_file)
if arg_debug
  @logger.sev_threshold = Logger::DEBUG
else
  @logger.sev_threshold = Logger::INFO
end

unless File.file?(driver_path)
  @logger.info('Driver in given path not found.')
  exit(false)
end

unless arg_diff.nil?
  diff_arr = file_to_array("#{arg_path}/#{arg_diff}")
  diff_arr = filter_diff_array(diff_arr)

  @logger.info("Listing changed drivers: #{diff_arr}") unless diff_arr.empty?

=begin
  if !diff_arr.include?(device['short']) and !diff_arr.empty?
    puts 'Driver is the same, no need to test again.'
    exit(true)
  end
=end
end

begin
  retries ||= 0
  timestamp = renew_snapshots(platform, tag, support)
  @dropbox = DropboxAPI.new(config['dropbox_token'])
  if @dropbox.connected?
    begin
      @dropbox.create_folder("#{tag}-#{timestamp}")
      @logger.info("Dropbox shared folder: #{@dropbox.url}")
    rescue StandardError
      @logger.error('Error uploading to dropbox shared folder: #{$!}')
    end
  else
    @logger.error('Dropbox authentication failure')
  end
  Filelock '/var/tmp/virthck.lock', timeout: 0 do
    setup_studio(tag, platform, arg_path, timestamp)
    setup_client(device, platform, tag, driver_path, install_method, CLIENT1, timestamp)
    setup_client(device, platform, tag, driver_path, install_method, CLIENT2, timestamp) if support
  end
  machine = fetch_pools.last['machines'].first['name']
  support_machine = support ? fetch_pools.last['machines'].last['name'] : nil
  sleep 60
  targets = fetch_targets(tag, machine)
  machine_target = search_target(targets, device['name'])
  add_target_to_project(tag, machine, tag, machine_target)
  tests = list_tests(tag, machine, tag, machine_target, platform['kit'])
  if playlist_tests
    tests.select! { |test| playlist_tests.include?(test['name']) }
    @logger.info("synced with playlist, #{tests.count} tests to run.")
  end
  if blacklist_tests
    @tests.reject! { |test| blacklist_tests.include?(test['name']) }
    @logger.info("synced with blacklist, #{tests.count} tests to run.")
  end
  count = 0
  failed = 0
  tests.each do |test|
    # break if count == 5
    count += 1
    start = Time.now
    puts '---------------------------------------------------------------------'
    @logger.info("Test (#{count}/#{tests.count}): #{test['name']} [#{test['estimatedruntime']}]")
    @logger.info(info_page(test['id']))
    queue_test(tag, machine, support_machine, tag, machine_target, test)
    results = process_test(tag, timestamp, machine, tag, machine_target, device, platform, test)
    failed = failed + 1 if results['content']['status'] == 'Failed'
    create_status(config['repository'], arg_commit, tag, tests.count, count, failed)
    real_time = (Time.now - start).ceil
    sleep 10
    archive_results(tag, machine, tag, machine_target, test)
    @logger.info("real time test taken: #{real_time}")
  end
  @logger.info('Tests ended.')
  create_project_package(tag)
  @logger.info('Shutting down.')
  shutdown_all(platform, support)
rescue StandardError => e
  @logger.error("Error during processing: #{$!}")
  @logger.error("Backtrace:\n\t#{e.backtrace.join("\n\t")}")
  shutdown_all(platform, support)
  sleep 60
  retry if (retries += 1) < 5
end
