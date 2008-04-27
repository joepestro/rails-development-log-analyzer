class RailsLogStat
  
  class RequestStats
    attr_accessor :sql_stats, :rendered_stats
    attr_reader :completion_time, :rendering_time, :db_time, :http_status, :url, :size
    
    def initialize max_size
      @max_size, @size, @index = max_size, 0, -1
      @sql_stats       = Hash.new{ |hash,key| hash[key] = RequestStatsCollection.new(max_size) }
      @rendered_stats  = Hash.new{ |hash,key| hash[key] = RequestStatsCollection.new(max_size) }
      @completion_time, @rendering_time, @db_time, @http_status, @url = * Array.new(5, [])
    end
    
    def accept_request
      @index = (@index + 1) % @max_size
      @size += 1 if @size < @max_size
      self
    end
    
    # stat_type => :sql_stats or :rendered_stats
    def push stat_type, stat_name, timing
      stat = send stat_type
      stat[stat_name][@index] << timing
    end
    
    # use one store method instead?
    %w{completion_time rendering_time db_time http_status url}.each do |stat_name|
      define_method "#{stat_name}=" do |value| 
        send(stat_name)[@index] = value 
      end
    end
    
    def reset
      [@sql_stats, @rendered_stats].each do |stat_type|
        stat_type.values { | req_stat_collction | req_stat_collction.reset @index }
      end
      
      [@completion_time, @rendering_time, @db_time, @http_status, @url].each do |stat_type|
        stat_type[@index] = nil
      end
    end
    
    def collection_average stat_type
      stat = send stat_type
      size = @size.to_f
      stat.collect do |stat_name, stat_collection|
        [ stat_collection.sum_all_appearances/size, stat_collection.sum_all_timings/size, stat_name ]
      end
    end
  end
    
  class RequestStatsCollection < Array
    def initialize size 
      super( size ) { Array.new }
    end
    
    def reset indx
      self[indx] = Array.new
    end
    
    def sum_all_appearances
      inject(0) do |sum, timings|
        sum += timings.size
      end
    end
    
    # note size doesn't matter here, the empty timing arrays will sum up to zero
    def sum_all_timings
      inject(0) do |sum, timings| 
        sum += timings.inject(0){ |sum_of_timings, t| sum_of_timings += t }
      end
    end
  end
  
  
  # Processing IndexController#index (for 127.0.0.1 at 2008-04-13 06:40:20) [GET]
  # $1 => 'ActionController#index', $2 => 'GET'
  REQUEST_BEGIN_MATCHER = /Processing\s+(\S+Controller#\S+) \(for.+\) \[(GET|POST|PUT|DELETE)\]$/
  
  # ModelClassName Load (0.000292)SELECT * FROM `answers` WHERE `id` = 2000
  # $1 => ModelClassName, $2 => Load, $3 => 0.0453, $4 => SELECT
  SQL_MATCHER = /([A-Z]\S+)\s+(Load|Update|Create|Destroy).+\((\d+\.\d+)\).+(SELECT|UPDATE|INSERT|DELETE)/
  
  # Rendered layout/application (0.00995)
  # $1 => layout/application, $2 => 0.00995
  RENDERED_MATCHER = /^Rendered (\S+) \((\d+\.\d+)\)$/
  
  # Completed in 3.48602 (0 reqs/sec) | Rendering: 1.53868 (44%) | DB: 0.79623 (22%) | 200 OK [http://www.example.com]
  # $1 => 3.48602, $2 => 1.53868, $3 => 44, $4 => 0.79623, $5 => 22, $6 => 200 OK, $7 => http://www.example.com
  REQUEST_COMPLETION_MATCHER = /^Completed in (\d+\.\d+).+Rendering: (\d+\.\d+) \((\d+)%\).+DB: (\d+\.\d+) \((\d+)%\) \| ([1-5]\d{2} \S+) \[(.+)\]$/
    
  attr_accessor :log_file_path  # , :max_stats_per_request

  def initialize log_file_path, max_stats_per_request=50
    @log_file_path, @max_stats_per_request = log_file_path, max_stats_per_request
    @requests = Hash.new{ |hash,key| hash[key] = RequestStats.new( @max_stats_per_request ) }
    @current_request = nil
  end
  
  def parse_log_file command="tail +0 -f"
    @log_thread ||= Thread.new do
      pipe = IO.popen "#{command.strip} #{log_file_path}", 'r'  # new pipe for tailing a text file
      while message_line = pipe.gets
        parse_line message_line
      end
    end
  end
  
  # Pattern match each line w/ Regexp
  def parse_line line
    if match = line.match( REQUEST_BEGIN_MATCHER )  
      request, method  = match[1], match[2]
      @current_request = "#{request} [#{method}]"   # => "ActionController#index [GET]"
      @current_request_stats = @requests[@current_request].accept_request
    elsif match = line.match( SQL_MATCHER )
      if @current_request # guard against old queries that doesn't have leading request log
        operation, timing = match[2], match[3].to_f 
        model_name = "#{operation.rjust(8)} #{match[1]}"
        @current_request_stats.push( :sql_stats, model_name, timing )
      end
    elsif match = line.match( RENDERED_MATCHER )
      rendered_file_name, timing = match[1], match[2].to_f
      @current_request_stats.push( :rendered_stats, rendered_file_name, timing )
    elsif match = line.match( REQUEST_COMPLETION_MATCHER )
      if @current_request
        @current_request_stats.completion_time = match[0].to_f
        @current_request_stats.rendering_time  = match[2].to_f
        @current_request_stats.db_time         = match[4].to_f
        @current_request_stats.http_status     = match[6]
        @current_request_stats.url             = match[7]
      end
    end
  end
  
  # Array of [ avg. count per request,   avg. time per request, model class name ]
  # notes average over the union might not be a good enough metrics, b/c some request might contain very little or no loads info for a specific model
  # it's generally a good idea to control your inputs for a specific log, so results are resonably consistent to compare with  
  def averages_for_request request, stat_type    
    @requests[request].collection_average( stat_type ) 
  end
  
  def request_names
    @requests.keys.sort
  end
  
  def request_count request
    @requests[request].size
  end
    
end

if __FILE__ == $0
  exit if PLATFORM =~ /win32/
  exit unless STDOUT.tty?
  unless ARGV[0]
    puts 'You need to specify the path to the log file'
    exit
  end
  
  log_stat = RailsLogStat.new ARGV[0]
  log_stat.parse_log_file ARGV[1] || 'tail +0 -f'
      
  header_spacing = "\t"
  spacing = "\t"
  SQL_STATS_HEADERS = [ 'QUERIES / REQUEST', 'TOTAL TIME SPENT / REQUEST', 'MODEL NAME' ]
  SQL_STATS_HEADERS_OUTPUT = SQL_STATS_HEADERS.join( header_spacing )
  
  RENDERED_STATS_HEADERS = [ 'RENDERED / REQUEST', 'TOTAL TIME SPENT / REQUEST', 'TEMPLATE NAME' ]
  RENDERED_STATS_HEADERS_OUTPUT = RENDERED_STATS_HEADERS.join( header_spacing )

  SEPERATOR = '=' * 80
  DATA_SEPERATOR = '-' * 80
  
  # Command Loop
  loop do 
    puts "\nUsage: 'l' to list requests; type ('s' or 'r' '[request#name]') for sql & rendered stats..."
    case input = STDIN.gets.strip
    when 'l', 'ls', 'req', 'request', 'requests'
      log_stat.request_names.each { |request_name| puts "--->  #{request_name}" }
    when 'q', 'quit', 'exit'
      puts 'Bye!'
      exit      
    when /^(s|r)\S*\s+(\S+#.+\])$/   # s ApplictionController#index [GET], render ApplictionController#index [GET]
      request_name = $2
      if log_stat.request_names.include? request_name
        if ($1 == 's') # s => sql_stats
          stat_type = :sql_stats 
          headers, headers_output = SQL_STATS_HEADERS, SQL_STATS_HEADERS_OUTPUT
        else # r => rendered_stats
          stat_type = :rendered_stats
          headers, headers_output = SQL_STATS_HEADERS, SQL_STATS_HEADERS_OUTPUT
        end
        
        output = [SEPERATOR, "#{request_name}: #{log_stat.request_count request_name} calls.", 
                  DATA_SEPERATOR, headers_output, DATA_SEPERATOR] 
        
        stats = log_stat.averages_for_request( request_name, stat_type )
        stats.sort!{ |stat1, stat2| stat2[1] <=> stat1[1] }
        stats.each do |stat|
          total_time_spent_per_request  = ("%.2f" % stat[0] )
          total_appearances_per_request = ( "%.6f" % stat[1] )
          output << [ total_time_spent_per_request.center(headers[0].size), 
                      total_appearances_per_request.center(headers[1].size), 
                      stat[2].to_s] * spacing
        end
        output << SEPERATOR
        puts output.join( "\n" )
      else
        puts 'ERROR: request not found...'
      end
    else
      puts 'ERROR: command not recongized'
    end
  end
end