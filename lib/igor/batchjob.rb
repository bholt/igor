require_relative 'util'

module JobOutput
  require 'file-tail'
  
  def tail
    stop_tailing = false
    out.backward(10).tail {|l|
      puts l
      break if stop_tailing
    }
  end
  def cat
    out.seek(0)
    puts out.read
  end
end

class SlurmJob
  require_relative 'slurm_ffi'
  
  @@jobs = {}
  def self.jobs() @@jobs; end
  
  attr_reader :jobid, :state, :nodes, :out_file
  def initialize(opts={:sinfo => nil, :params => nil})
    if not opts[:sinfo]
      batch_cmd = "sbatch --job-name='#{jobname}' --nodes=#{p[:nnode]} --ntasks-per-node=#{p[:ppn]} #{@sbatch_flags.join(' ')} --output=#{fout} --error=#{fout} #{cmd}"
      puts batch_cmd
      s = `#{batch_cmd}`    
      @jobid = s[/Submitted batch job (\d+)/,1].to_i
    else
      @jobid = sinfo[:job_id]
      update(sinfo)
    end
    @@jobs[@jobid] = self
  end
  
  def output_path
    "#{Igor.igor_dir}/igor.%j.out".gsub(/%j/, @jobid.to_s)
  end

  def update(sinfo=nil)
    jmsg = nil
    if not sinfo
      jptr = FFI::MemoryPointer.new :pointer
      Slurm.slurm_load_job(jptr, @jobid, 0)
      jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
      raise "assertion failure" unless jmsg[:record_count] == 1
      sinfo = Slurm::JobInfo.new(jmsg[:job_array])
    end
    
    @state = sinfo[:job_state]
    @nodes = sinfo[:nodes]
    @start_time = sinfo[:start_time]
    @end_time = sinfo[:end_time]

    Slurm.slurm_free_job_info_msg(jmsg) if jmsg
  end

  def update_jobs
    jptr = FFI::MemoryPointer.new :pointer
    Slurm.slurm_load_jobs(0, jptr, 0)
    raise "unable to update jobs, slurm returned NULL" if jptr.get_pointer(0) == FFI::Pointer::NULL
    jmsg = Slurm::JobInfoMsg.new(jptr.get_pointer(0))
    
    @@jobs = {}
    
    (0...jmsg[:record_count]).each do |i|
      sinfo = Slurm::JobInfo.new(jmsg[:job_array]+i*Slurm::JobInfo.size)
      if sinfo[:user_id] == Process.uid
        jobid = sinfo[:job_id]
        @@jobs[jobid] = SlurmJob.new(jobid,sinfo)
      end
    end

    Slurm.slurm_free_job_info_msg(jmsg)
  end

  def to_s()
    time = @state == :JOB_COMPLETE ? total_time : elapsed_time
    "#{@jobid}: #{@state} on #{@nodes}, time: #{time}"
  end

  def elapsed_time()
    Time.at(Time.now.tv_sec - @start_time).gmtime.strftime('%R:%S')
  end
  def total_time()   Time.at(@end_time - @start_time).gmtime.strftime('%R:%S') end
  def out()          @out ||= File.open(output_path, 'r') end
  
  include JobOutput
end
