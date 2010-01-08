#
# memcached_stats
#
# Scout plugin http://scoutapp.com/ to monitor and gather statistics of a memcached server
#
# This plugin is based on the memcached_monitor.rb plugin written by Mike Mangino http://github.com/mmangino.
#
# Author: Colin Surprenant, colin.surprenant@praizedmedia.com, http://github.com/colinsurprenant
#
require 'timeout'

class MissingLibrary < StandardError; end
class TestFailed < StandardError; end 
class BadData < StandardError; end 
class InvalidConfig < StandardError; end 

class MemcachedMonitor < Scout::Plugin

  SIZE_METRICS = ["bytes", "limit_maxbytes", "bytes_read", "bytes_written"]
  VALUE_CHARS = ('a'..'z').to_a
  RATE_KEYS_MAP = {
    "gets_per_sec"      => "cmd_get",
    "sets_per_sec"      => "cmd_set", 
    "misses_per_sec"    => "get_misses",
    "hits_per_sec"      => "get_hits",
    "evictions_per_sec" => "evictions"
  }

  attr_accessor :connection  
  
  OPTIONS = <<-HEREDOC
options:
  host:
    name: Host
    notes: The host to monitor
    default: 127.0.0.1
  port:
    name: Port
    notes: The port memcached is running on
    default: 11211
  key:
    name: Key to use for testing
    notes: This key will be both read and set 
    default: memcached_monitor_key
  timeout: 
    name: Timeout
    notes: maximum amount of time to wait for a response
    default: 0.25
  units:
    name: sizes units for stats fields
    notes: use either B, KB, MB, GB. Apply only to bytes, limit_maxbytes, bytes_read, bytes_written metrics
    default: MB
  metrics:
    name: stats metrics to monitor
    notes: see available metrics in http://code.sixapart.com/svn/memcached/trunk/server/doc/protocol.txt
    default: cmd_get:get_count, cmd_set:set_count, get_misses, get_hits, curr_connections:current_connections, curr_items:total_items, bytes:current_data, limit_maxbytes:max_data
  rates:
    name: computed rates stats
    notes: these values will be computed to expose per/second statistics
    default: gets_per_sec, sets_per_sec, misses_per_sec, hits_per_sec  
HEREDOC
   
  
  def setup_memcache
    begin
      require 'memcache'
    rescue LoadError
      begin
        require "rubygems"
        require 'memcache'
      rescue LoadError
        raise MissingLibrary, "could not load the memcache gem"
      end
    end
    # puts "[#{option(:host)}:#{option(:port)}]  key[#{option(:key)}]"
    self.connection = MemCache.new("#{option(:host)}:#{option(:port)}")
  end
  
  def build_report(h={})
    begin
      setup_memcache
      test_setting_value
      test_getting_value
      report(gather_stats)
    rescue MissingLibrary => e
      # the MissingLibrary rescue must be before the MemCache::MemCacheError rescue because
      # if the gem is not loaded, the exception class will not be defined either.
      error("missing library", e.message)
    rescue Timeout::Error => e
      alert("memcached timeout", "memcached on #{option(:host)}:#{option(:port)} failed to respond within #{timeout_value} seconds")
    rescue MemCache::MemCacheError => e
      alert("memcache connection failed", "unable to connect to memcached on #{option(:host)}:#{option(:port)}")
    rescue TestFailed => e
      alert(e.message)
    end
  end

  def test_setting_value
    @test_value = (1..4).collect { |a| VALUE_CHARS[rand(VALUE_CHARS.size)] }.join
    timeout(timeout_value) do
      connection.set(option(:key), @test_value)
    end
  end

  def test_getting_value
    value = timeout(timeout_value) do
      connection.get(option(:key))
    end
    if value != @test_value
      raise TestFailed, "bad data from #{option(:host)}, expected #{@test_value} but got #{value}"
    end
  end

  def gather_stats
    now = Time.now
    
    # grab stats and validate returned structure
    stats = timeout(timeout_value) do
      connection.stats
    end
    unless (host_stats = stats["#{option(:host)}:#{option(:port)}"])
      raise(TestFailed, "unable to retrieve stats from #{option(:host)}:#{option(:port)}")
    end
    
    report_stats = {}
    
    # fill report with gathered stats
    metric_keys_map.each do |stats_key, report_key|
      report_stats[report_key] = SIZE_METRICS.include?(stats_key) ? cast_unit(host_stats[stats_key], option(:units)) : host_stats[stats_key]
    end
    
    # fill report with computed stats
    if (last_run_time = memory(:last_run_time))
      duration = now - last_run_time
      raise(BadData, "cannot compute rates without duration") if duration <= 0
      
      rates_keys.each do |key|
        raise(InvalidConfig, "invalid rate key: #{key}") unless RATE_KEYS_MAP[key]
        rate = (host_stats[RATE_KEYS_MAP[key]].to_i - memory("last_run_#{key}".to_sym).to_i) / duration
        raise(BadData, "#{key} has decreased since last report") if rate < 0
        report_stats[key] = round_to(rate, 1)
      end    
    end
    
    # remember last values
    remember(:last_run_time => now)
    rates_keys.each { |key| remember("last_run_#{key}".to_sym => host_stats[RATE_KEYS_MAP[key]].to_i) }
    
    return report_stats
  end
  
  def rates_keys
    return option(:rates).to_s.split(/\s*,\s*/)
  end
  
  # return a hash to map original metric name as returned by memcached (stats_key) to nicer name as configured in options (report_key)
  def metric_keys_map
    keys_map = {}
    option(:metrics).to_s.split(/\s*,\s*/).each do |k|
      stats_key, report_key = key_names(k)
      keys_map[stats_key] = report_key
    end
    return keys_map
  end
    
  # return tupple [stats_key, report_key] where stats_key is the original key name as returned by memcached
  # and report_key is configured nicer name with configured units appended
  # k parameter contains the single item from the metrics option (format "stats_key:report_key")
  def key_names(k)
    keys = k.split(/\s*:\s*/)
    keys << k if keys.size == 1
    keys[1] = "#{keys[1]}_#{option(:units)}" if SIZE_METRICS.include?(keys[0])
    return keys
  end
    
  def cast_unit(bytes, unit)
    case unit
      when "B"
        return bytes
      when "KB"
        return round_to(bytes / 1024, 2)
      when "MB" 
        return round_to(bytes / (1024 * 1024), 2)
      when "GB"
        return round_to(bytes / (1024 * 1024 * 1024), 2)
    end
  end

  def round_to(f, x)
    (f * 10**x).round.to_f / 10**x
  end

  def timeout_value
    (option(:timeout) || 1).to_f
  end

end