
module Delayed

  class DeserializationError < StandardError
  end

  class Job < ActiveRecord::Base
    MAX_ATTEMPTS = 25
    MAX_RUN_TIME = 4.hours
    set_table_name :delayed_jobs

    # By default failed jobs are destroyed after too many attempts.
    # If you want to keep them around (perhaps to inspect the reason
    # for the failure), set this to false.
    cattr_accessor :worker_name, :min_priority, :max_priority, :destroy_failed_jobs
    self.destroy_failed_jobs = true

    # Every worker has a unique name which by default is the pid of the process. 
    # There are some advantages to overriding this with something which survives worker retarts: 
    # Workers can safely resume working on tasks which are locked by themselves. The worker will assume that it crashed before.
    self.worker_name = "host:#{Socket.gethostname} pid:#{Process.pid}" rescue "pid:#{Process.pid}"
  
    NextTaskSQL         = '(run_at <= ? AND (locked_at IS NULL OR locked_at < ?) OR (locked_by = ?)) AND failed_at IS NULL'
    NextTaskOrder = 'priority DESC, run_at ASC'

    ParseObjectFromYaml = /\!ruby\/\w+\:([^\s]+)/
    
    cattr_accessor :min_priority, :max_priority
    self.min_priority = nil
    self.max_priority = nil    

    class LockError < StandardError
    end

    def self.clear_locks!
      update_all("locked_by = null, locked_at = null", ["locked_by = ?", worker_name])
    end

    def failed?
      failed_at
    end
    alias_method :failed, :failed?

    def payload_object
      @payload_object ||= deserialize(self['handler'])
    end
    
    def name    
      @name ||= begin
        payload = payload_object
        if payload.respond_to?(:display_name)
          payload.display_name
        else
          payload.class.name
        end
      end
    end

    def info_attributes
      { :locked_by => locked_by, :period => period, :executions_left => executions_left, :recur => recur, 
        :description => description, :attempts => attempts, :last_error => last_error }
    end

    def payload_object=(object)
      self['handler'] = object.to_yaml
      self['description'] = object.respond_to?(:description) ? object.description : ''
    end

    def reschedule(message, backtrace = [], time = nil)
      if self.attempts < MAX_ATTEMPTS
        time ||= Job.db_time_now + (attempts ** 4) + 5

        self.attempts    += 1
        self.run_at       = time
        self.last_error   = message + "\n" + backtrace.join("\n")
        self.unlock
        save!
      else
        logger.info "* [JOB] PERMANENTLY removing #{self.name} because of #{attempts} consequetive failures."
        destroy_failed_jobs ? destroy : update_attribute(:failed_at, Time.now)
      end
    end

    def self.enqueue(*args, &block)
      if block_given?
        priority = args.first || 0
        run_at   = args.second
        
        Job.create(:payload_object => EvaledJob.new(&block), :priority => priority.to_i, :run_at => run_at)
      else
        object   = args.first
        priority = args.second || 0
        run_at   = args.third
        
        unless object.respond_to?(:perform)
          raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
        end

        Job.create(:payload_object => object, :priority => priority.to_i, :run_at => run_at)
      end
    end
    
    #This provides a method of "scheduling"
    #start_time is when the job will first run, the period dictates when it will run again after that
    #executions_left dictates how many times it will run, or use -1 to indicate infinite repeats.  by default
    #it is infinite (-1)
    def self.recurring(object, priority = 0, start_time = db_time_now, period = 24.hours, executions_left = -1)
      unless object.respond_to?(:perform)
        raise ArgumentError, 'Cannot enqueue items which do not respond to perform'
      end
      Job.create(:payload_object => object, :priority => priority.to_i, :run_at => start_time, :recur => true, :period => period, :executions_left => executions_left) 
    end
     
    def self.find_available(limit = 5, max_run_time = MAX_RUN_TIME)

      time_now = db_time_now      

      sql = NextTaskSQL.dup

      conditions = [time_now, time_now - max_run_time, worker_name]
      
      if self.min_priority
        sql << ' AND (priority >= ?)'
        conditions << min_priority
      end
      
      if self.max_priority
        sql << ' AND (priority <= ?)'
        conditions << max_priority         
      end

      conditions.unshift(sql)         
            
      records = ActiveRecord::Base.silence do
        find(:all, :conditions => conditions, :order => NextTaskOrder, :limit => limit)
      end
      
      records.sort { rand() }
    end                                    
      
    # Get the payload of the next job we can get an exclusive lock on.
    # If no jobs are left we return nil
    def self.reserve(max_run_time = MAX_RUN_TIME, &block)

      # We get up to 5 jobs from the db. In face we cannot get exclusive access to a job we try the next.
      # this leads to a more even distribution of jobs across the worker processes
      find_available(5, max_run_time).each do |job|
        begin
          logger.info "* [JOB] aquiring lock on #{job.name}"
          job.lock_exclusively!(max_run_time, worker_name)
          runtime =  Benchmark.realtime do
            invoke_job(job.payload_object, job.info_attributes, &block)
            if job.recur == true && (job.executions_left > 1 || job.executions_left == -1)
              run = job.run_at + job.period
              executions_left = job.executions_left == -1 ? -1 : job.executions_left - 1
              job.update_attributes(:run_at => run, :executions_left => executions_left)
              job.unlock
              job.save
            else
              job.destroy
            end
          end
          logger.info "* [JOB] #{job.name} completed after %.4f" % runtime

          return job
        rescue LockError
          # We did not get the lock, some other worker process must have
          logger.warn "* [JOB] failed to aquire exclusive lock for #{job.name}"
        rescue StandardError => e 
          job.reschedule e.message, e.backtrace
          log_exception(job, e)
          return job
        end
      end

      nil
    end

    # This method is used internally by reserve method to ensure exclusive access
    # to the given job. It will rise a LockError if it cannot get this lock.
    def lock_exclusively!(max_run_time, worker = worker_name)
      now = self.class.db_time_now
      affected_rows = if locked_by != worker
        # We don't own this job so we will update the locked_by name and the locked_at
        self.class.update_all(["locked_at = ?, locked_by = ?", now, worker], ["id = ? and (locked_at is null or locked_at < ?)", id, (now - max_run_time.to_i)])
      else
        # We already own this job, this may happen if the job queue crashes. 
        # Simply resume and update the locked_at
        self.class.update_all(["locked_at = ?", now], ["id = ? and locked_by = ?", id, worker])
      end
      raise LockError.new("Attempted to aquire exclusive lock failed") unless affected_rows == 1
      
      self.locked_at    = now
      self.locked_by    = worker
    end
    
    def unlock
      self.locked_at    = nil
      self.locked_by    = nil
    end

    # This is a good hook if you need to report job processing errors in additional or different ways
    def self.log_exception(job, error)
      logger.error "* [JOB] #{job.name} failed with #{error.class.name}: #{error.message} - #{job.attempts} failed attempts"
      logger.error(error)
    end

    def self.work_off(num = 100)
      success, failure = 0, 0

      num.times do

        job = self.reserve do |j, atts|
          begin
            logger.info "job: #{j.description}" if j.respond_to?(:description) && j.description
            if j.method(:perform).arity == 1
              j.perform atts
            else
              j.perform
            end
            success += 1
          rescue
            failure += 1
            raise
          end
        end

        break if job.nil?
      end

      return [success, failure]
    end          
    
    
    # Moved into its own method so that new_relic can trace it.
    def self.invoke_job(job, attributes, &block)
      block.call(job, attributes)
    end


    private

    def deserialize(source)
      attempt_to_load_file = true

      begin
        handler = YAML.load(source) rescue nil
        return handler if handler.respond_to?(:perform)

        if handler.nil?
          if source =~ ParseObjectFromYaml

            # Constantize the object so that ActiveSupport can attempt
            # its auto loading magic. Will raise LoadError if not successful.
            attempt_to_load($1)

            # If successful, retry the yaml.load
            handler = YAML.load(source)
            return handler if handler.respond_to?(:perform)
          end
        end

        if handler.is_a?(YAML::Object)

          # Constantize the object so that ActiveSupport can attempt
          # its auto loading magic. Will raise LoadError if not successful.
          attempt_to_load(handler.class)

          # If successful, retry the yaml.load
          handler = YAML.load(source)
          return handler if handler.respond_to?(:perform)
        end

        raise DeserializationError, 'Job failed to load: Unknown handler. Try to manually require the appropiate file.'

      rescue TypeError, LoadError, NameError => e

        raise DeserializationError, "Job failed to load: #{e.message}. Try to manually require the required file."
      end
    end

    def attempt_to_load(klass)
       klass.constantize
    end

    def self.db_time_now
      (ActiveRecord::Base.default_timezone == :utc) ? Time.now.utc : Time.now
    end

    protected

    def before_save
      self.run_at ||= self.class.db_time_now
    end

  end

  class EvaledJob
    def initialize
      @job = yield
    end

    def perform
      eval(@job)
    end
  end
end
