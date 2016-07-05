require 'fileutils'
require 'shellwords'
require 'socket'
require 'timeout'
require 'childprocess'
require 'active_support/benchmarkable'
require 'active_support/core_ext/hash'
require 'erb'
require 'yaml'
require 'logger'
require 'open-uri'
require 'tempfile'
require 'zip'

Dir[File.expand_path(File.join(File.dirname(__FILE__),"tasks/*.rake"))].each { |ext| load ext } if (defined?(Rake::VERSION))

class Jettywrapper

  include ActiveSupport::Benchmarkable

  attr_accessor :jetty_home   # Jetty's home directory
  attr_accessor :port         # Jetty's port.  Default is 8888.  Note that attribute is named port, but params passed in expect :jetty_port
  attr_accessor :startup_wait # How many seconds to wait for jetty to spin up. Default is 5.
  attr_accessor :quiet        # true (default) to reduce Jetty's output
  attr_accessor :solr_home    # Solr's home directory. Default is jetty_home/solr
  attr_accessor :base_path    # The root of the application. Used for determining where log files and PID files should go.
  attr_accessor :java_opts    # Options to pass to java (ex. ["-Xmx512mb", "-Xms128mb"])
  attr_accessor :java_command # Path to the Java executable
  attr_accessor :java_version # Minimum java version
  attr_accessor :jetty_opts   # Options to pass to jetty (ex. ["etc/my_jetty.xml", "etc/other.xml"] as in http://wiki.eclipse.org/Jetty/Reference/jetty.xml_usage

  def initialize(params = {})
    self.base_path = self.class.app_root
    configure(params)
  end

  def configure params
    self.quiet        = params[:quiet].nil? ? true : params[:quiet]
    self.jetty_home   = params[:jetty_home  ] || File.expand_path(File.join(self.base_path, 'jetty'))
    self.solr_home    = params[:solr_home   ] || File.join( self.jetty_home, "solr")
    self.port         = params[:jetty_port  ] || 8888
    self.startup_wait = params[:startup_wait] || 5
    self.java_opts    = params[:java_opts   ] || []
    self.java_command = params[:java_command] || default_java_command
    self.java_version = params[:java_version]
    self.jetty_opts   = params[:jetty_opts  ] || []
  end

  # Methods inside of the class << self block can be called directly on Jettywrapper, as class methods.
  # Methods outside the class << self block must be called on Jettywrapper.instance or a Jettywrapper object, as instance methods.
  class << self

    attr_writer :hydra_jetty_version, :url, :tmp_dir, :jetty_dir, :env

    def hydra_jetty_version
      @hydra_jetty_version ||= 'master'
    end

    def url
      @url ||= defined?(ZIP_URL) ? ZIP_URL : "https://github.com/projecthydra/hydra-jetty/archive/#{hydra_jetty_version}.zip"
      @url
    end

    def tmp_dir
      @tmp_dir ||= 'tmp'
    end

    def zip_file
      ENV['JETTY_ZIP'] || File.join(tmp_dir, url.split('/').last)
    end

    def jetty_dir
      @jetty_dir ||= 'jetty'
    end

    def download(url = nil)
      return if File.exists? zip_file
      self.url = url if url
      logger.info "Downloading jetty at #{self.url} ..."
      FileUtils.mkdir tmp_dir unless File.exists? tmp_dir

      begin
        open(self.url) do |io|
          IO.copy_stream(io,zip_file)
        end
      rescue Exception => e
        abort "Unable to download jetty from #{self.url} #{e.message}"
      end
    end

    def unzip
      download unless File.exists? zip_file
      logger.info "Unpacking #{zip_file}..."
      tmp_save_dir = File.join tmp_dir, 'jetty_generator'
      begin
        Zip::File.open(zip_file) do |zip_file|
          # Handle entries one by one
          zip_file.each do |entry|
            dest_file = File.join(tmp_save_dir,entry.name)
            FileUtils.remove_entry(dest_file,true)
            entry.extract(dest_file)
          end
        end
      rescue Exception => e
        abort "Unable to unzip #{zip_file} into tmp_save_dir/ #{e.message}"
      end

      # Remove the old jetty directory if it exists
      FileUtils.remove_dir(jetty_dir,true)

      # Move the expanded zip file into the final destination.
      expanded_dir = expanded_zip_dir(tmp_save_dir)
      begin
        FileUtils.mv(expanded_dir, jetty_dir)
      rescue Exception => e
        abort "Unable to move #{expanded_dir} into #{jetty_dir}/ #{e.message}"
      end
    end

    def expanded_zip_dir(tmp_save_dir)
      # This old way is more specific, but won't work for blacklight-jetty
      #expanded_dir = Dir[File.join(tmp_save_dir, "hydra-jetty-*")].first
      Dir[File.join(tmp_save_dir, "*")].first
    end

    def clean
      FileUtils.remove_dir(jetty_dir,true)
      unzip
    end

    def reset_config
      @app_root = nil
      @env = nil
      @url = nil
      @hydra_jetty_version = nil
    end

    def app_root
      return @app_root if @app_root
      @app_root = Rails.root if defined?(Rails) and defined?(Rails.root)
      @app_root ||= APP_ROOT if defined?(APP_ROOT)
      @app_root ||= '.'
    end

    def env
      @env ||= begin
        case
        when ENV['JETTYWRAPPER_ENV']
          ENV['JETTYWRAPPER_ENV']
        when defined?(Rails) && Rails.respond_to?(:env)
          Rails.env
        when ENV['RAILS_ENV']
          ENV['RAILS_ENV']
        when ENV['environment']
          ENV['environment']
        else
          default_environment
        end
      end
    end

    def default_environment
      'development'
    end

    def load_config(config_name = env)
      @env = config_name
      jetty_file = "#{app_root}/config/jetty.yml"

      unless File.exists?(jetty_file)
        logger.warn "Didn't find expected jettywrapper config file at #{jetty_file}, using default file instead."
        jetty_file = File.expand_path("../config/jetty.yml", File.dirname(__FILE__))
      end

      begin
        jetty_erb = ERB.new(IO.read(jetty_file)).result(binding)
      rescue
        raise("jetty.yml was found, but could not be parsed with ERB. \n#{$!.inspect}")
      end

      begin
        jetty_yml = YAML::load(jetty_erb)
      rescue
        raise("jetty.yml was found, but could not be parsed.\n")
      end

      if jetty_yml.nil? || !jetty_yml.is_a?(Hash)
        raise("jetty.yml was found, but was blank or malformed.\n")
      end

      config = jetty_yml.with_indifferent_access
      config[config_name] || config['default'.freeze]
    end

    # Set the jetty parameters. It accepts a Hash of symbols.
    # @param [Hash<Symbol>] params
    #  :jetty_home Required. Jetty's home direcotry
    #  :jetty_port  Jetty's port.  Default is 8888.   Note that attribute is named port, but params passed in expect :jetty_port
    #  :startup_wait How many seconds to wait for jetty to spin up.  Default is 5. If jetty doesn't finish spinning up, tests can fail because they can't reach jetty.
    #  :solr_home Solr's home directory. Default is jetty_home/solr
    #  :quiet Keep True(default) to reduce jetty's output
    #  :java_opts options to pass to the jvm (ex. ["-Xmx512mb", "-Xms128mb"])
    #  :jetty_opts options to pass to jetty (ex. ["etc/my_jetty.xml", "etc/other.xml"] as in http://wiki.eclipse.org/Jetty/Reference/jetty.xml_usage
    def configure(params = {})
      jetty_server = self.instance
      jetty_server.reset_process!
      jetty_server.configure params
      return jetty_server
    end

    def instance
      @instance ||= Jettywrapper.new
    end

    # Wrap the tests. Startup jetty, yield to the test task, capture any errors, shutdown
    # jetty, and return the error.
    # @example Using this method in a rake task
    #   require 'jettywrapper'
    #   desc "Spin up jetty and run tests against it"
    #   task :newtest do
    #     jetty_params = {
    #       :jetty_home => "/path/to/jetty",
    #       :quiet => false,
    #       :jetty_port => 8983,
    #       :startup_wait => 30,
    #       :jetty_opts => "/etc/jetty.xml"
    #     }
    #     error = Jettywrapper.wrap(jetty_params) do
    #       Rake::Task["rake:spec"].invoke
    #       Rake::Task["rake:cucumber"].invoke
    #     end
    #     raise "test failures: #{error}" if error
    #   end
    def wrap(params)
      error = false
      jetty_server = self.configure(params)

      begin
        jetty_server.start
        yield
      rescue
        error = $!
        logger.error "*** Error starting jetty: #{error}"
      ensure
        # puts "stopping jetty server"
        jetty_server.stop
      end

      raise error if error

      return error
    end

    # Convenience method for configuring and starting jetty with one command
    # @param [Hash] params: The configuration to use for starting jetty
    # @example
    #    Jettywrapper.start(:jetty_home => '/path/to/jetty', :jetty_port => '8983')
    def start(params)
      unzip unless File.exists? jetty_dir
      Jettywrapper.configure(params)
      Jettywrapper.instance.start
      return Jettywrapper.instance
    end

    # Convenience method for configuring and starting jetty with one command. Note
    # that for stopping, only the :jetty_home value is required (including other values won't
    # hurt anything, though).
    # @param [Hash] params: The jetty_home to use for stopping jetty
    # @return [Jettywrapper.instance]
    # @example
    #    Jettywrapper.stop_with_params(:jetty_home => '/path/to/jetty')
    def stop(params)
       Jettywrapper.configure(params)
       Jettywrapper.instance.stop
       return Jettywrapper.instance
    end

    # Determine whether the jetty at the given jetty_home is running
    # @param [Hash] params: :jetty_home is required. Which jetty do you want to check the status of?
    # @return [Boolean]
    # @example
    #    Jettywrapper.is_jetty_running?(:jetty_home => '/path/to/jetty')
    def is_jetty_running?(params)
      Jettywrapper.configure(params)
      pid = Jettywrapper.instance.pid
      return false unless pid
      true
    end

    # Return the pid of the specified jetty, or return nil if it isn't running
    # @param [Hash] params: :jetty_home is required.
    # @return [Fixnum] or [nil]
    # @example
    #    Jettywrapper.pid(:jetty_home => '/path/to/jetty')
    def pid(params)
      Jettywrapper.configure(params)
      pid = Jettywrapper.instance.pid
      return nil unless pid
      pid
    end

    # Check to see if the port is open so we can raise an error if we have a conflict
    # @param [Fixnum] port the port to check
    # @return [Boolean]
    # @example
    #  Jettywrapper.is_port_open?(8983)
    def is_port_in_use?(port)
      begin
        Timeout::timeout(1) do
          begin
            s = TCPSocket.new('127.0.0.1', port)
            s.close
            return true
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
            return false
          rescue
            return false
          end
        end
      rescue Timeout::Error
      end

      return false
    end

    # Check to see if the pid is actually running. This only works on unix.
    def is_pid_running?(pid)
      begin
        return Process.getpgid(pid) != -1
      rescue Errno::ESRCH
        return false
      end
    end

    def check_java_version! java_path, required_java_version
      Tempfile.open("java-version-output") do |f|
        process = ChildProcess.build(java_path, "-version")
        process.io.stderr = f
        process.start

        begin
          process.poll_for_exit(10)
        rescue ChildProcess::TimeoutError
          process.stop # tries increasingly harsher methods to kill the process.
        end

        f.rewind
        err = f.read

        java_version = if version = err.match(/java version "([^"]+)"/)
          version[1]
        else
          raise "Java not found, or an error was encountered when running `#{java_path} -version`: #{err}"
        end

        unless Gem::Dependency.new('', required_java_version.gsub("_", ".")).match?('', java_version.gsub("_", "."))
          raise "Java #{required_java_version} is required to run Jetty. Found Java #{java_version} when running `#{java_path} -version`."
        end
      end

      true
    end

    def logger=(logger)
      @@logger = logger
    end

    # If ::Rails.logger is defined and is not nil, it will be returned.
    # If no logger has been defined, a new STDOUT Logger will be created.
    def logger
      @@logger ||= defined?(::Rails) && Rails.respond_to?(:logger) && Rails.logger ? ::Rails.logger : ::Logger.new(STDOUT)
    end

  end #end of class << self

  def logger
    self.class.logger
  end

  # What command is being run to invoke jetty?
  def jetty_command
    [java_command, java_variables, java_opts, "-jar", "start.jar", jetty_opts].flatten
  end

  def java_variables
    ["-Djetty.port=#{@port}",
     "-Dsolr.solr.home=#{Shellwords.escape(@solr_home)}"]
  end

  def check_java_version!
    if java_version
      @checked_java_version ||= Jettywrapper.check_java_version!(java_command, java_version)
    end
  end

  # Start the jetty server. Check the pid file to see if it is running already,
  # and stop it if so. After you start jetty, write the PID to a file.
  # This is the instance start method. It must be called on Jettywrapper.instance
  # You're probably better off using Jettywrapper.start(:jetty_home => "/path/to/jetty")
  # @example
  #    Jettywrapper.configure(params)
  #    Jettywrapper.instance.start
  #    return Jettywrapper.instance
  def start
    logger.debug "Starting jetty with these values: "
    logger.debug "jetty_home: #{@jetty_home}"
    logger.debug "jetty_command: #{jetty_command.join(' ')}"

    check_java_version!

    # Check to see if we can start.
    # 1. If there is a pid, check to see if it is really running
    # 2. Check to see if anything is blocking the port we want to use
    if pid
      if Jettywrapper.is_pid_running?(pid)
        raise("Server is already running with PID #{pid}")
      else
        logger.warn "Removing stale PID file at #{pid_path}"
        File.delete(pid_path)
      end
    end
    if Jettywrapper.is_port_in_use?(self.port)
      raise("Port #{self.port} is already in use.")
    end
    benchmark "Started jetty" do
      Dir.chdir(@jetty_home) do
        process.start
      end
      FileUtils.makedirs(pid_dir) unless File.directory?(pid_dir)
      begin
        f = File.new(pid_path,  "w")
      rescue Errno::ENOENT, Errno::EACCES
        f = File.new(File.join(base_path,'tmp',pid_file),"w")
      end
      f.puts "#{process.pid}"
      f.close
      logger.debug "Wrote pid file to #{pid_path} with value #{process.pid}"
      startup_wait!
    end
  end

  # Wait for the jetty server to start and begin listening for requests
  def startup_wait!
    begin
    Timeout::timeout(startup_wait) do
      sleep 1 until (Jettywrapper.is_port_in_use? self.port)
    end
    rescue Timeout::Error
      logger.warn "Waited #{startup_wait} seconds for jetty to start, but it is not yet listening on port #{self.port}. Continuing anyway."
    end
  end

  def process
    @process ||= begin
       process = ChildProcess.build(*jetty_command)
       if self.quiet
         process.io.stderr = File.open(File.expand_path("jettywrapper.log"), "w+")
         process.io.stdout = process.io.stderr
         logger.warn "Logging jettywrapper stdout to #{File.expand_path(process.io.stderr.path)}"
       else
         process.io.inherit!
       end
       process.detach = true

       process
     end
  end

  def reset_process!
    @process = nil
  end

  # Instance stop method. Must be called on Jettywrapper.instance
  # You're probably better off using Jettywrapper.stop(:jetty_home => "/path/to/jetty")
  # @example
  #    Jettywrapper.configure(params)
  #    Jettywrapper.instance.stop
  #    return Jettywrapper.instance
  def stop
    logger.debug "Instance stop method called for pid '#{pid}'"
    if pid
      if @process
        @process.stop
      else
        Process.kill("KILL", pid) rescue nil
      end

      begin
        File.delete(pid_path)
      rescue
      end
    end
  end

  # The fully qualified path to the pid_file
  def pid_path
    #need to memoize this, becasuse the base path could be relative and the cwd can change in the yield block of wrap
    @path ||= File.join(pid_dir, pid_file)
  end

  # The file where the process ID will be written
  def pid_file
    jetty_home_to_pid_file(@jetty_home)
  end

  # Take the @jetty_home value and transform it into a legal filename
  # @return [String] the name of the pid_file
  # @example
  #    /usr/local/jetty1 => _usr_local_jetty1.pid
  def jetty_home_to_pid_file(jetty_home)
    begin
      jetty_home.gsub(/\//,'_') << "_#{self.class.env}" << ".pid"
    rescue Exception => e
      raise "Couldn't make a pid file for jetty_home value #{jetty_home}\n  Caused by: #{e}"
    end
  end

  # The directory where the pid_file will be written
  def pid_dir
    File.expand_path(File.join(base_path,'tmp','pids'))
  end

  # Check to see if there is a pid file already
  # @return true if the file exists, otherwise false
  def pid_file?
    File.exist?(pid_path)
  end

  # the process id of the currently running jetty instance
  def pid
    File.open( pid_path ) { |f| return f.gets.to_i } if File.exist?(pid_path)
  end

  private

  def default_java_command
    # Use the same JAVA_HOME lookup as Solr
    @default_java_command ||= if ENV["JAVA_HOME"]
      if File.exists? File.join(ENV["JAVA_HOME"], "bin", "java")
        File.join(ENV["JAVA_HOME"], "bin", "java")
      end

      if File.exists? File.join(ENV["JAVA_HOME"], "amd64", "bin", "java")
        File.join(ENV["JAVA_HOME"], "amd64", "bin", "java")
      end
    end

    @default_java_command ||= "java"
  end

end
