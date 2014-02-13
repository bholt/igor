require_relative 'util'
require_relative 'batchjob'

class Experiment
  include Helpers::Sqlite
  attr_reader :command, :params, :jobid, :serialized_file

  def initialize(params, igor, serialized_file)
    @command = igor.command
    @params = params
    @jobid = nil
    @parser_str = igor.parser.to_source
    @dbpath = igor.dbpath
    @dbtable = igor.dbtable
    @opt = igor.opt
    @serialized_file = serialized_file
    @expect = igor.expect
    @ignore = igor.ignore
  end

  def run()
    require 'open3'
    require 'experiments'
    pid = -1
    pout = ''

    @parser = eval(@parser_str)

    @params[:jobid] = ENV['SLURM_JOBID'].to_i
    @params[:outfile] = BatchJob.fout(@params[:jobid])
    @params[:started_at] = Time.now.to_s

    # puts "running..."
    c = @command % @params
    # puts "#{c}\n--------------".black

    # insert job record no matter what, so we can see errors
    new_job_record = params.merge({:error => 'x', :results => ''})
    job_key = insert(:jobs, new_job_record)

    error = '' # no news is good news
    begin
      Open3.popen2e(c) {|i,oe,waiter|
        pid = waiter.pid
        oe.each_line {|l|
          pout += l
          puts l.strip
        }
        exit_status = waiter.value
        if not exit_status.success?
          puts "Error!"
          error = "exit status: #{exit_status}"
          raise
        end
      }

      puts "Parsing results"
      begin
        results = @parser[pout]
      rescue => e
        puts e
        puts e.backtrace
        puts "Error! parsing failed"
        raise
      end
      puts "Parsing results completed"

      # box up data into an array (so we can easily handle multiple data records if needed)
      results = [] if not results
      results = [results] if results.is_a? Hash
      if results.size == 0
        puts "Error! No results."
        puts error = "no results"
        raise
      end

      missing = Set.new
      results.each{|r| missing |= @expect - r.keys}
      if not missing.empty?
        puts "Error: missing fields: #{missing.to_a}, skipping insertion. See `jobs` for the output."
        error = "missing: #{missing.to_a}"
        raise
      end

      results.each {|d|
        new_record = params.merge(d)
        puts new_record # print
        insert(@dbtable, new_record) unless @opt[:noinsert]
        
        open("temp.out.rb","w"){|f| f.write new_record.to_s}
      }
    rescue # do nothing, just do the ensures
    ensure
      update(:jobs, job_key, {:error => error.to_s, :results => results.to_s})
    end
    return true # success
  end

  def to_s
    "(#{params}, #{command})"
  end
    
  def pretty_s
    Experiment.color_command(@command, @params)
  end

  def self.color_command(command, params)
    '( '.blue +
    '{ '.red + params.map{|n,p| "#{n}:".green + p.to_s.yellow}.join(', ') + ' }'.red +
    ' )'.blue
  end

end
