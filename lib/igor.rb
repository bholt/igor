#!/usr/bin/env ruby

require 'ruby2ruby'
#Temporary fix for https://github.com/seattlerb/ruby_parser/issues/154
class Regexp
  [:ENC_NONE, :ENC_EUC, :ENC_SJIS, :ENC_UTF8].each do |enc|
    send(:remove_const, enc)
  end
end
require 'ruby_parser'

require 'securerandom'
require 'sourcify'
require 'pry'
require 'pty'

require_relative 'experiments'
require_relative 'igor/slurm_ffi'
require_relative 'igor/experiment'
require_relative 'igor/batchjob'
require_relative 'igor/util'

class Params < Hash
  include Helpers::DSL
  
  def initialize(&dsl_code)
    eval_dsl_code(&dsl_code) if dsl_code
  end
  
  # Arbitrary method calls create new entries in Hash
  # Enables DSL syntax:
  #   Params.new { nnode(4); ppn(1, 2) }
  # or even simpler...
  #   Params.new { nnode 4; ppn 1, 2 }
  #
  # TODO: fix problem with collisions (i.e. 'partition' is already a method)
  def method_missing(selector, *args, &blk)
    self[selector.to_sym] = args
  end
  
end

###############################################
# require_relative that uses the location of
# the symlink rather than the underlying file
def require_relative_to_symlink(path)
  dir = File.expand_path(File.dirname(caller[0][/(^.*?):/,1]))
  require "#{dir}/#{path}"
end

def parse_cmdline(opt=nil)
  opt = { :force => false,
          :no_insert => false,
          :include_tag => true,
          :dry_run => false,
          :interactive => false
        }.merge(opt || {})

  require 'optparse'
  parser = OptionParser.new do |p|
    p.banner = "Usage: #{__FILE__} [options]"

    p.on('-f', '--force', 'Force re-runs of experiments even if found in database.') { opt[:force] = true }
    p.on('-n', '--no-insert', "Run experiments, but don't insert results in database.") { opt[:no_insert] = true }
    p.on('-y', '--dry-run', "Don't actually run any experiments. Just print the commands.") { opt[:dry_run] = true }
    p.on('-t', '--[no-]include-tag', "Include tag when deciding to rerun.") {|b| opt[:include_tag] = b }
    p.on('-i', '--interactive', "Enter interactive mode (pry prompt) after initializing.") { opt[:interactive] = true }
  end
  parser.parse!
  opt
end

module Igor
  extend self # this is probably a really terrible thing to do

  extend Helpers::Sqlite
  extend Helpers::DSL
  extend Helpers::Git

  attr_reader :dbinfo, :dbtable, :opt, :parser_file

  @dbinfo = nil
  @dbtable = nil
  @command = nil
  @params = {}
  @experiments = {}
  @jobs = {}
  @interesting = Set.new
  @expect = Set.new
  @ignore = Set.new
  @sbatch_flags = []

  def dsl(&dsl_code)
    @opt = parse_cmdline()
    
    # fill 'params' with things like 'tag', 'run_at', etc. that are not usually specified
    @common_info = common_info()
    @ignore << :run_at

    # make sure directory where we'll put things exists
    begin Dir.mkdir(igor_dir) rescue Errno::EEXIST end

    eval_dsl_code(&dsl_code)

  end

  #################################
  # Methods intended for DSL usage:

  # all calls to 'params' append to existing params, overwriting if needed
  # should allow for imperative-style experiments:
  #   params { scale 16; nnode 4 }
  #   run    # runs with {scale:16, nnode:4}
  #   params { scale 25 }
  #   run    # runs with {scale:25, nnode:4}
  def params(&blk) @params.merge!(Params.new(&blk)) end

  # Allow looking up experiments with aliases (currently just index in experiments array)
  # def exp(a) @experiments[@job_aliases[a]] end
  # def job(a) exp(a) end

  # Set command template string
  def command(c=nil)
    @command = c if c
    return @command
  end
  alias :cmd :command
  
  def database(dbinfo=nil, dbtable=nil)
    return @db if !dbinfo
    @dbinfo ||= {}
    
    if dbinfo.is_a? String
      @dbinfo = {
        adapter: 'sqlite',
        database: File.expand_path(dbinfo)
      }
    else
      raise 'badly specified dbinfo' unless dbinfo.is_a? Hash
      
      if dbinfo[:socket]
        @dbinfo.merge!({adapter:'mysql'}.merge(dbinfo))
      else
        # override defaults with anything set in `dbinfo`
        @dbinfo = {
          adapter: 'mysql',
          host: '127.0.0.1',
          user: 'root',
          database: 'test'
        }.merge( @dbinfo.merge dbinfo )
      end
    end
    
    if dbtable
      @dbtable = dbtable
    elsif dbinfo[:table]
      @dbtable = dbinfo[:table]
    end
    
    @db = Sequel.connect(@dbinfo)
    return @db
  end
  alias :db :database

  # Run a set of experiments, merging this block's params into @params.
  # Also takes a hash of options that replace the global @opt for this set of runs
  def run(opts={},&blk)
    if opts.size > 0
      saved_opts = @opt.clone
      @opt.merge!(opts)
    end
    
    p = Params.new(&blk)
    @interesting += p.keys   # any key in a 'run' is interesting enough to be displayed
    enumerate_experiments(p)
    status
    
    @opt = saved_opts if saved_opts  # restore
    return  # no return value
  end
  
  # shortcut to call `run` with :force => true.
  def run_forced(opts={},&blk)
    run(opts.merge({force:true}), &blk)
  end

  # Parser
  def parser(&blk)
    # getter...
    if !blk then return @parser end

    if blk.arity != 1
      $stderr.puts "Error: invalid parser."
      exit 1
    end

    @parser = blk
  end

  # Parser
  # def setup(&blk) @setup = blk end
    
  # Access sbatch flags array. To override, you may assign to it:
  # Igor do
  #   sbatch_flags = ["--time=4:00:00"]
  # end
  # 
  # or more likely, append:
  #   sbatch_flags << "--time=4:00:00"
  attr_accessor :sbatch_flags

  # Fields that, if missing in parsed output, make the run invalid (so not inserted in results table, just in `:jobs`)
  def expect(*fields)
    @expect |= fields
  end
  
  # fields to ignore for the purposes of `run_already?`
  def ignore(*fields)
    @ignore |= fields
  end
  

  # END DSL methods
  #################################

  ######################
  # Interactive methods
  
  def tail(a)
    begin
      j = @jobs[@job_aliases[a]]
      j.tail
    rescue
      puts "Unable to tail alias: #{a}, job: #{@job_aliases[a]}."
    end
  end
  
  # View output from batch job. Supports several different ways of invoking:
  # - view 0: interprets integer as job number (from 'status')
  # - view 'test.out': interprets string as the output file to read
  # - view { id 3 }: view the most recent *job* matching the given DSL-defined hash (treats the block like a 'params' or 'run' DSL and queries the ':job' table for matching entries)
  # - view(:test){ id 3 }: query a particular table instead of ':job'
  def view(a = @job_aliases.keys.last, &blk)
    if blk
      if a.is_a? Symbol
        view @db[a].reverse_order(:id).where(Params.new(&blk)).first[:outfile]
      else
        view jobs.reverse_order(:id).where(Params.new(&blk)).first.outfile
      end
    elsif a.is_a? Integer
      j = @jobs[@job_aliases[a]]
      j.cat
    elsif a.is_a? String
      File.open(a,'r') {|f| puts f.read }
    end
  end
  alias :v :view
  
  # takes a query block and runs the output of the results through the parser again
  # example:
  #   reparse{where :jobid => 3065519}
  def reparse(dataset, &blk)
    dataset.instance_eval(&blk).each do |r|
      h = parser[open(r[:outfile]).read].merge(r)
      ig = @ignore << :id << :error << :outfile << :results
      h.delete_if{|k| ig.include? k}
      # puts h
      puts insert(@dbtable, h)
    end
  end  
  
  # Kill/cancel a job using its job alias.
  def kill(job_alias = @job_aliases.keys.last)
    j = @jobs[@job_aliases[job_alias]]
    return if not j
    puts `scancel #{j.jobid}`.strip
  end
  
  # Attach to running job (view output live) using job_alias (the number listed by `status`, e.g. [ 0]).
  def attach(job_alias = @job_aliases.keys.last)
    
    j = @jobs[@job_aliases[job_alias]]
    return if not j
    
    j.update
    
    if j.state == :JOB_PENDING
      puts "job pending..."
      Signal.scoped_trap("INT", ->{ raise }) {
        begin
          sleep 0.1 and j.update while j.state == :JOB_PENDING
        rescue # catch ctrl-c safely, will return below
        end
      }
      return if j.state == :JOB_PENDING
    end
    
    begin
      sleep 0.5 # give squeue time to get itself together
      j.update
      job_with_step = %x{ squeue --jobs=#{j.jobid} --steps --format %i }.split[1]
    end while j.state == :JOB_RUNNING && (job_with_step == nil)
    
    if not job_with_step
      puts "Job step not found, might have finished already. Try `view #{job_alias}`"
      return
    end
    
    begin
      begin
        j.update
        job_with_step = %x{ squeue --jobs=#{j.jobid} --steps --format %i }.split[1]
      end while j.state == :JOB_RUNNING && (job_with_step == nil)
      
      attach_again = false
      sleep 0.5
      PTY.spawn "sattach #{job_with_step}" do |r,w,pid|
        Signal.trap("INT") { puts "detaching..."; Process.kill("INT",pid) }
        begin
          r.sync
          r.each_line do |l|
            ll = l.strip
            raise 'No Tasks' if ll =~ /no tasks running/
            raise 'Invalid Jobid' if ll =~ /Invalid job id specified/
            puts ll
          end
        rescue Errno::EIO => e
          # *correct* behavior is to emit an I/O error here, so ignore
        ensure
          ::Process.wait pid
          # puts "$?.exitstatus = #{$?.exitstatus}"
          Signal.trap("INT", "DEFAULT") # reset signal
        end
      end
    rescue Exception => e
      case e.message
      when /No Tasks/
        retry
      when /Invalid Jobid/
        retry
      end
    end
  end
  alias :a :attach
  alias :at :attach

  def status
    @job_aliases = {}
    update_jobs
    @jobs.each_with_index {|(id,job),index|
      puts "[#{'%2d'%index}]".cyan + " " + job.to_s
      @job_aliases[index] = id  # so user can refer to an experiment by a shorter number (or alias)
      
      if @experiments.include? id  # if this job is one of our experiments...
        # print interesting parameters
        p = @experiments[id].params.select{|k,v|
          not(@params[k] || @common_info[k] || k == :command) ||
          (@params[k].is_a? Array and @params[k].length > 1) ||
          (@interesting.include? k)
        }
        puts "     " + p.pretty_s
      end
      # puts '------------------'.black
    }
    return 'status'
  end
  alias :st :status

  # shortcut to provide the pry command-line to debug a remote process
  # usage looks something like: pry(#<Igor>)> .#{gdb 'n01', '11956'}
  # (pry sends commands starting with '.' to the shell, but allows string interpolation)
  def gdb(node, pid)
    return "ssh #{node} -t gdb attach #{pid}"
  end
  
  def interact
    # only do "interact" if it's the script actuall being run...
    if (caller[0] =~ /#{$0}/)
      status
      self.pry
    end
  end

  def scratch()
    sf = "#{igor_dir}/scratch.rb"
    open(sf,"w"){|f| f.write("Igor do\n  \nend\n")} unless File.exists? sf
    Pry::Editor.invoke_editor(sf,2)
    load sf
  end

  # ----- Deprecated -----  
  def print_results(&blk)
    # print results (records in database), optionally takes a block to specify a custom query
    # 
    # usage:
    #   results {|t| t.select(:field).where{value > 100}.order(:run_at) }
    #
    # default (without block) does:
    #   results {|t| t.reverse_order(:run_at) }
    
    if blk
      d = yield @db[@dbtable]
    else
      d = @db[@dbtable].order(:run_at)
    end
    puts Hirb::Helpers::AutoTable.render(d.all) # (doesn't do automatic paging...)
  end
  
  def _dsl_dataset(starting_dataset, &blk)
    d = starting_dataset
    if blk
      # same as DSL eval: if they want a handle, give it to 'em
      if blk.arity == 1
        d = yield d
      else # otherwise just evaluate directly on the dataset (implicit 'self')
        d = d.instance_eval(&blk)
      end
    end
    return d
  end
  
  # Get new handle for a dataset from the results database.
  # This handle is actually a `Sequel::Model`, which means it has lots of useful little things
  # you can do with it.
  # 
  # Example usage:
  # print all results:
  # > results.all
  # get field value from result with given id:
  # > results[12].nnode
  # 
  def results(&blk)
    d = _dsl_dataset(@db[@dbtable], &blk)
    return Class.new(Sequel::Model) { set_dataset d }
  end
  
  # Query separate "jobs" table that has all experiments run, whether they succeeded or not.
  def jobs(&blk)
    d = _dsl_dataset(@db[:jobs], &blk)
    return Class.new(Sequel::Model) { set_dataset d }
  end
  
  # Displays fields of jobs that are probably relevant for determining the status of recent jobs.
  # In particular, displays "error" field and still contains "outfile", and is ordered
  # starting with the most recent jobs first.
  def recent_jobs(&blk)
    return jobs{|d| _dsl_dataset(d.select(:id, :error, :nnode, :ppn, :started_at, :outfile).reverse_order(:id), &blk) }
  end
  
  # Query the database using SQL directly. Returns a Sequel::Model object like `results`.
  #
  # Example usage:
  # pry(Igor)> sql('select nnode, ppn, a, b, c from jobs').all
  # +-------+-----+---+---+-----+
  # | nnode | ppn | a | b | c   |
  # +-------+-----+---+---+-----+
  # | 2     | 1   | 2 | 2 | abc |
  # +-------+-----+---+---+-----+
  def sql(*sql_query_args)
    d = @db.fetch(*sql_query_args)
    return Class.new(Sequel::Model) { set_dataset d }
  end
  
  # doesn't currently work ('create_or_replace_view' unsupported for SQLite, or Sequel bug?)
  # def results_filter(dataset=nil,&blk)
  #   if blk
  #     dataset = yield @db[@dbtable]
  #   end
  #   if dataset || blk
  #     @db.create_or_replace_view(:temp, dataset)
  #   end
  #   return results{|t| t.from(:temp)}
  # end
  
  # Interactive methods
  ##########################

  def update_jobs
    jptr = FFI::MemoryPointer.new :pointer
    Slurm.slurm_load_jobs(0, jptr, 0)
    raise "unable to update jobs, slurm returned NULL" if jptr.get_pointer(0) == FFI::Pointer::NULL
    jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
    
    @jobs = {}
    
    (0...jmsg[:record_count]).each do |i|
      sinfo = Slurm::JobInfo.new(jmsg[:job_array]+i*Slurm::JobInfo.size)
      if sinfo[:user_id] == Process.uid
        jobid = sinfo[:job_id]
        @jobs[jobid] = BatchJob.new(jobid,sinfo)
      end
    end

    Slurm.slurm_free_job_info_msg(jmsg)
  end

  def setup_experiment(p)
    d = igor_dir

    f = "#{d}/igor.#{Process.pid}.#{SecureRandom.hex(3)}.bin"
    fout = BatchJob.fout

    e = Experiment.new(p, self, f)

    File.open(f, 'w') {|o| o.write Marshal.dump(e) }

    cmd = "#{File.dirname(__FILE__)}/igor/igorun.rb '#{f}'"

    # make sure the allocation has at least 1 process
    p[:nnode] = 1 unless p[:nnode]
    p[:ppn] = 1 unless p[:ppn]

    jobname = File.basename($0).gsub(/(\.\/|\.rb)/,'')

    batch_cmd = "sbatch --job-name='#{jobname}' --nodes=#{p[:nnode]} --ntasks-per-node=#{p[:ppn]} #{@sbatch_flags.join(' ')} --output=#{fout} --error=#{fout} #{cmd}"
    puts batch_cmd
    s = `#{batch_cmd}`

    jobid = s[/Submitted batch job (\d+)/,1].to_i

    @jobs[jobid] = BatchJob.new(jobid)
    @experiments[jobid] = e
  end

  def enumerate_experiments(override_params)
    params = @params.merge(@common_info).merge(override_params)
    enumerate_exps(params) do |p|
      p[:command] = @command % p
      
      pcheck = p.clone.delete_if{|k,v| @ignore.include? k }
      
      if @opt[:dry_run]
        print "<dry run> ".magenta
      elsif (not run_already?(pcheck)) || @opt[:force]
        setup_experiment(p)
      else
        print "<skipped> ".red
      end
      
      print "Experiment".blue; puts Experiment.color_command(@command, p)      
    end
  end

end # module Igor

def Igor(&blk)
  Igor.dsl(&blk)
end

# Hirb (for better table output)
begin
  require 'pry'
  require 'hirb'
  Hirb.enable
  old_print = Pry.config.print
  Pry.config.print = proc do |output, value|
    Hirb::View.view_or_page_output(value) || old_print.call(output, value)
  end
rescue LoadError
  # Hirb is just bonus anyway...
end
