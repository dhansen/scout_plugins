# 
# Created by Eric Lindvall <eric@5stops.com>
#

require 'set'
 
class MysqlQueryStatisticsTriand < Scout::Plugin
  ENTRIES = %w(Com_insert Com_select Com_update Com_delete).to_set
  ENTRIES_SINGLE = %w(Connections Max_used_connections).to_set
  
  needs "mysql"

  def build_report
    # get_option returns nil if the option value is blank
    user     = get_option(:user) || 'root'
    password = get_option(:password)
    host     = get_option(:host)
    port     = get_option(:port)
    socket   = get_option(:socket)
    
    
    now = Time.now
    mysql = Mysql.connect(host, user, password, nil, (port.nil? ? nil : port.to_i), socket)
    result = mysql.query('SHOW /*!50002 GLOBAL */ STATUS')
    
    report_hash = {}
    rows = []
    total = 0
    result.each do |row| 
      rows << row if ENTRIES.include?(row.first)
      total += row.last.to_i if row.first[0..3] == 'Com_'
    
      report_hash[row.first] = row.last.to_i if ENTRIES_SINGLE.include?(row.first)
    end
    result.free
    
    rows.each do |row|
      name = row.first[/_(.*)$/, 1]
      value = calculate_counter(now, name, row.last.to_i)
      # only report if a value is calculated
      next unless value
      report(name => value)
    end
    
    report_hash.each_pair{|name, value| report(name => value) }
    

    total_val = calculate_counter(now, 'total', total)
    report('total' => total_val) if total_val
  end

  private
  
  # Returns nil if an empty string
  def get_option(opt_name)
    val = option(opt_name)
    val = (val.is_a?(String) and val.strip == '') ? nil : val
    return val
  end
  
  # Note this calculates the difference between the last run and the current run.
  def calculate_counter(current_time, name, value)
    result = nil
    # only check if a past run has a value for the specified query type
    if memory(name) && memory(name).is_a?(Hash)
      last_time, last_value = memory(name).values_at('time', 'value')
      # We won't log it if the value has wrapped
      if last_value and value >= last_value
        elapsed_seconds = current_time - last_time
        elapsed_seconds = 1 if elapsed_seconds < 1
        result = value - last_value

        # calculate per-second
        result = result / elapsed_seconds.to_f
      end
    end

    remember(name => {:time => current_time, :value => value})
    
    result
  end
end
