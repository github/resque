require "socket"

module Resque
  # A Resque Worker processes jobs. On platforms that support fork(2),
  # the worker will fork off a child to process each job. This ensures
  # a clean slate when beginning the next job and cuts down on gradual
  # memory growth as well as low level failures.
  #
  # It also ensures workers are always listening to signals from you,
  # their master, and can react accordingly.
  class Worker
    include Resque::Helpers
    extend Resque::Helpers

    # Whether the worker should log basic info to STDOUT
    attr_accessor :verbose

    # Whether the worker should log lots of info to STDOUT
    attr_accessor  :very_verbose

    # Boolean indicating whether this worker can or can not fork.
    # Automatically set if a fork(2) fails.
    attr_accessor :cant_fork

    # When true, makes us treat SIGTERM like SIGQUIT (i.e. marks the worker for
    # termination, but lets it finish the current job).
    attr_accessor :graceful_term

    attr_writer :to_s

    # Returns an array of all worker objects.
    def self.all
      with_retries do
        Array(redis.smembers(:workers)).map { |id| find(id, true) }.compact
      end
    end

    # Returns an array of all worker objects currently processing
    # jobs.
    def self.working
      names = all
      return [] unless names.any?

      names.map! { |name| "worker:#{name}" }

      reportedly_working = {}

      begin
        with_retries do
          reportedly_working = redis.mapped_mget(*names).reject do |key, value|
            value.nil? || value.empty?
          end
        end
      rescue Redis::Distributed::CannotDistribute
        names.each do |name|
          with_retries do
            value = redis.get name
            reportedly_working[name] = value unless value.nil? || value.empty?
          end
        end
      end

      reportedly_working.keys.map do |key|
        find(key.sub("worker:", ''), true)
      end.compact
    end

    # Returns a single worker object. Accepts a string id.
    def self.find(worker_id, skip_exists = false)
      if skip_exists || exists?(worker_id)
        queues = worker_id.split(':')[-1].split(',')
        worker = new(*queues)
        worker.to_s = worker_id
        worker
      else
        nil
      end
    end

    # Alias of `find`
    def self.attach(worker_id)
      find(worker_id)
    end

    # Given a string worker id, return a boolean indicating whether the
    # worker exists
    def self.exists?(worker_id)
      with_retries do
        redis.sismember(:workers, worker_id)
      end
    end

    # Workers should be initialized with an array of string queue
    # names. The order is important: a Worker will check the first
    # queue given for a job. If none is found, it will check the
    # second queue name given. If a job is found, it will be
    # processed. Upon completion, the Worker will again check the
    # first queue given, and so forth. In this way the queue list
    # passed to a Worker on startup defines the priorities of queues.
    #
    # If passed a single "*", this Worker will operate on all queues
    # in alphabetical order. Queues can be dynamically added or
    # removed without needing to restart workers using this method.
    def initialize(*queues)
      @current_job = nil
      @queues = queues.map { |queue| queue.to_s.strip }
      validate_queues
    end

    # A worker must be given a queue, otherwise it won't know what to
    # do with itself.
    #
    # You probably never need to call this.
    def validate_queues
      if @queues.nil? || @queues.empty?
        raise NoQueueError.new("Please give each worker at least one queue.")
      end
    end

    # This is the main workhorse method. Called on a Worker instance,
    # it begins the worker life cycle.
    #
    # The following events occur during a worker's life cycle:
    #
    # 1. Startup:   Signals are registered, dead workers are pruned,
    #               and this worker is registered.
    # 2. Work loop: Jobs are pulled from a queue and processed.
    # 3. Teardown:  This worker is unregistered.
    #
    # Can be passed an integer representing the polling frequency.
    # The default is 5 seconds, but for a semi-active site you may
    # want to use a smaller value.
    #
    # Also accepts a block which will be passed the job as soon as it
    # has completed processing. Useful for testing.
    def work(interval = 5, &block)
      interval = Integer(interval)
      $0 = "resque: Starting"
      startup

      loop do
        break if shutdown?

        if !paused?
          procline "Waiting for #{@queues.join(',')}"
        end

        if !paused? && job = reserve(interval)
          log "got: #{job.inspect}"
          job.worker = self
          run_hook :before_fork, job
          working_on job

          if @child = fork
            srand # Reseeding
            procline "Forked #{@child} at #{Time.now.to_i}"
            Process.wait(@child)
          else
            procline "Processing #{job.queue} since #{Time.now.to_i}"
            perform(job, &block)
            exit! unless @cant_fork
          end

          done_working
          @child = nil

          run_hook :after_perform, self
        else
          break if interval.zero? # for testing
          if paused?
            procline "Paused"
            sleep interval
          end
        end
      end

    ensure
      unregister_worker
    end

    # DEPRECATED. Processes a single job. If none is given, it will
    # try to produce one. Usually run in the child.
    def process(job = nil, &block)
      return unless job ||= reserve

      job.worker = self
      working_on job
      perform(job, &block)
    ensure
      done_working
    end

    # Processes a given job in the child.
    def perform(job)
      begin
        @current_job = job
        run_hook :after_fork, job
        job.perform
      rescue Object => e
        log "#{job.inspect} failed: #{e.inspect}"
        begin
          job.fail(e)
        rescue Object => e
          log "Received exception when reporting failure: #{e.inspect}"
        end
        Stat << "failed"
      else
        log "done: #{job.inspect}"
      ensure
        @current_job = nil
        yield job if block_given?
      end
    end

    # Attempts to grab a job off one of the provided queues. Returns
    # nil if no job can be found.
    #
    # The timeout defines how long to wait for a blocking pop, if any queues are
    # available to check for jobs, or how long to sleep if no queues are
    # available. Queues may not be available because resque hasn't created or
    # tracked any queues yet, or because no queues are passing their
    # before_reserve hooks.
    #
    # timeout - an Integer timeout in seconds. Defaults to 5.
    #
    # Returns a Job or nil.
    def reserve(timeout=5)
      available_queues = Job.reservable_queues(queues)
      if available_queues.empty?
        sleep timeout # prevent busy-wait.
      elsif job = Job.reserve(available_queues, timeout)
        log! "Found job on #{job.queue}"
        return job
      end
      nil
    rescue Exception => e
      log "Error reserving job: #{e.inspect}"
      log e.backtrace.join("\n")
      raise e
    end

    # Returns a list of queues to use when searching for a job.
    # A splat ("*") means you want every queue (in alpha order) - this
    # can be useful for dynamically adding new queues.
    def queues
      @queues.map {|queue| queue == "*" ? Resque.queues.sort : queue }.flatten.uniq
    end

    # Not every platform supports fork. Here we do our magic to
    # determine if yours does.
    def fork
      @cant_fork = true if $TESTING

      return if @cant_fork

      begin
        # IronRuby doesn't support `Kernel.fork` yet
        if Kernel.respond_to?(:fork)
          Kernel.fork
        else
          raise NotImplementedError
        end
      rescue NotImplementedError
        @cant_fork = true
        nil
      end
    end

    # Runs all the methods needed when a worker begins its lifecycle.
    def startup
      enable_gc_optimizations
      register_signal_handlers
      run_hook :before_first_fork, self
      register_worker

      # Fix buffering so we can `rake resque:work > resque.log` and
      # get output from the child in there.
      $stdout.sync = true
    end

    # Enables GC Optimizations if you're running REE.
    # http://www.rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
    def enable_gc_optimizations
      if GC.respond_to?(:copy_on_write_friendly=)
        GC.copy_on_write_friendly = true
      end
    end

    # Registers the various signal handlers a worker responds to.
    #
    # TERM: Shutdown immediately, stop processing jobs (unless
    #       `self.graceful_term` is true, in which case only shutdown after the
    #       current job has finished processing).
    #  INT: Shutdown immediately, stop processing jobs.
    # QUIT: Shutdown after the current job has finished processing.
    # USR1: Kill the forked child immediately, continue processing jobs.
    # USR2: Don't process any new jobs
    # CONT: Start processing jobs again after a USR2
    def register_signal_handlers
      trap('TERM') { graceful_term ? shutdown : shutdown! }
      trap('INT')  { shutdown!  }

      begin
        trap('QUIT') { shutdown   }
        trap('USR1') { kill_child }
        trap('USR2') { pause_processing }
        trap('CONT') { unpause_processing }
      rescue ArgumentError
        warn "Signals QUIT, USR1, USR2, and/or CONT not supported."
      end

      log! "Registered signals"
    end

    # Schedule this worker for shutdown. Will finish processing the
    # current job.
    def shutdown
      log 'Exiting...'
      @shutdown = true
    end

    # Kill the child and shutdown immediately.
    def shutdown!
      shutdown
      kill_child
    end

    # Should this worker shutdown as soon as current job is finished?
    def shutdown?
      @shutdown
    end

    # Kills the forked child immediately, without remorse. The job it
    # is processing will not be completed.
    def kill_child
      if @child
        log! "Killing child at #{@child}"
        if system("ps -o pid,state -p #{@child}")
          Process.kill("KILL", @child) rescue nil
        else
          log! "Child #{@child} not found, restarting."
          shutdown
        end
      elsif @cant_fork && @current_job
        raise Resque::DirtyExit, "Worker killed while processing job"
      end
    end

    # are we paused?
    def paused?
      @paused
    end

    # Stop processing jobs after the current one has completed (if we're
    # currently running one).
    def pause_processing
      log "USR2 received; pausing job processing"
      @paused = true
    end

    # Start processing jobs again after a pause
    def unpause_processing
      log "CONT received; resuming job processing"
      @paused = false
    end

    # Looks for any workers which should be running on this server
    # and, if they're not, removes them from Redis.
    #
    # This is a form of garbage collection. If a server is killed by a
    # hard shutdown, power failure, or something else beyond our
    # control, the Resque workers will not die gracefully and therefore
    # will leave stale state information in Redis.
    #
    # By checking the current Redis state against the actual
    # environment, we can determine if Redis is old and clean it up a bit.
    def prune_dead_workers
      all_workers = Worker.all
      known_workers = worker_pids unless all_workers.empty?
      all_workers.each do |worker|
        host, pid = worker.id.split(':')
        next unless host == hostname
        next if known_workers.include?(pid)
        log! "Pruning dead worker: #{worker}"
        worker.unregister_worker
      end
    end

    # Registers ourself as a worker. Useful when entering the worker
    # lifecycle on startup.
    def register_worker
      with_exponential_backoff do
        redis.pipelined do
          redis.sadd(:workers, self)
          redis.set("worker:#{self}:queues", @queues.join(","))
        end
      end
    end

    # Runs a named hook, passing along any arguments.
    def run_hook(name, *args)
      return unless hook = Resque.send(name)
      msg = "Running #{name} hook"
      msg << " with #{args.inspect}" if args.any?
      log msg

      args.any? ? hook.call(*args) : hook.call
    end

    # Unregisters ourself as a worker. Useful when shutting down.
    def unregister_worker
      # If we're still processing a job, make sure it gets logged as a
      # failure.
      if (hash = processing) && !hash.empty?
        job = Job.new(hash['queue'], hash['payload'])
        # Ensure the proper worker is attached to this job, even if
        # it's not the precise instance that died.
        job.worker = self
        job.fail(DirtyExit.new)
      end

      with_exponential_backoff do
        redis.pipelined do
          redis.srem(:workers, self)
          redis.del("worker:#{self}")
          redis.del("worker:#{self}:queues")
        end
      end
    end

    # Given a job, tells Redis we're working on it. Useful for seeing
    # what workers are doing and when.
    def working_on(job)
      data = encode \
        :queue   => job.queue,
        :run_at  => Time.now.utc.iso8601,
        :payload => job.payload
      with_exponential_backoff do
        redis.set("worker:#{self}", data)
      end
    end

    # Called when we are done working - clears our `working_on` state
    # and tells Redis we processed a job.
    def done_working
      with_exponential_backoff do
        redis.pipelined do
          Stat << "processed"
          redis.del("worker:#{self}")
        end
      end
    end

    # Returns a hash explaining the Job we're currently processing, if any.
    def job
      with_exponential_backoff do
        decode(redis.get("worker:#{self}")) || {}
      end
    end
    alias_method :processing, :job

    # Boolean - true if working, false if not
    def working?
      state == :working
    end

    # Boolean - true if idle, false if not
    def idle?
      state == :idle
    end

    # Returns a symbol representing the current worker state,
    # which can be either :working or :idle
    def state
      with_exponential_backoff do
        redis.exists("worker:#{self}") ? :working : :idle
      end
    end

    # Is this worker the same as another worker?
    def ==(other)
      to_s == other.to_s
    end

    def inspect
      "#<Worker #{to_s}>"
    end

    # The string representation is the same as the id for this worker
    # instance. Can be used with `Worker.find`.
    def to_s
      @to_s ||= "#{hostname}:#{Process.pid}:-"
    end
    alias_method :id, :to_s

    # Hostname of this machine
    def hostname
      @hostname ||= Socket.gethostname
    end

    # Returns Integer PID of running worker
    def pid
      Process.pid
    end

    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def worker_pids
      if RUBY_PLATFORM =~ /solaris/
        solaris_worker_pids
      else
        linux_worker_pids
      end
    end

    # Find Resque worker pids on Linux and OS X.
    #
    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def linux_worker_pids
      `ps -A -o pid,command | grep "[r]esque" | grep -v "resque-web"`.split("\n").map do |line|
        line.split(' ')[0]
      end
    end

    # Find Resque worker pids on Solaris.
    #
    # Returns an Array of string pids of all the other workers on this
    # machine. Useful when pruning dead workers on startup.
    def solaris_worker_pids
      `ps -A -o pid,comm | grep "[r]uby" | grep -v "resque-web"`.split("\n").map do |line|
        real_pid = line.split(' ')[0]
        pargs_command = `pargs -a #{real_pid} 2>/dev/null | grep [r]esque | grep -v "resque-web"`
        if pargs_command.split(':')[1] == " resque-#{Resque::Version}"
          real_pid
        end
      end.compact
    end

    # Given a string, sets the procline ($0) and logs.
    # Procline is always in the format of:
    #   resque-VERSION: STRING
    def procline(string)
      $0 = "resque-#{Resque::Version}: #{string}"
      log! $0
    end

    # If a TimeoutError occurs communicating with Redis, retry the operation
    # with an expontially longer sleep on each attempt. This allows us to
    # continue working in the event of a Redis failover, but prevents us from
    # overwhelming Redis if it's having trouble servicing requests due to
    # high CPU utilization.
    def with_exponential_backoff
      retries = 0
      begin
        yield
      rescue Redis::TimeoutError => e
        while !shutdown?
          sleep [2 ** retries + (rand * 5), 60].min
          retries += 1
          break if Resque.reconnect(1)
        end

        raise e if shutdown?
        retry
      end
    end

    # Log a message to STDOUT if we are verbose or very_verbose.
    def log(message)
      if verbose
        puts "*** #{message}"
      elsif very_verbose
        time = Time.now.strftime('%H:%M:%S %Y-%m-%d')
        puts "** [#{time}] #$$: #{message}"
      end
    end

    # Logs a very verbose message to STDOUT.
    def log!(message)
      log message if very_verbose
    end
  end
end
