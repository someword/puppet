# The client for interacting with the puppetmaster config server.
require 'sync'
require 'timeout'
require 'puppet/network/http_pool'
require 'puppet/util'

class Puppet::Configurer
  class CommandHookError < RuntimeError; end

  require 'puppet/configurer/fact_handler'
  require 'puppet/configurer/plugin_handler'

  include Puppet::Configurer::FactHandler
  include Puppet::Configurer::PluginHandler

  # For benchmarking
  include Puppet::Util

  attr_reader :compile_time

  # Provide more helpful strings to the logging that the Agent does
  def self.to_s
    "Puppet configuration client"
  end

  class << self
    # Puppetd should only have one instance running, and we need a way
    # to retrieve it.
    attr_accessor :instance
    include Puppet::Util
  end

  # How to lock instances of this class.
  def self.lockfile_path
    Puppet[:puppetdlockfile]
  end

  def clear
    @catalog.clear(true) if @catalog
    @catalog = nil
  end

  def execute_postrun_command
    execute_from_setting(:postrun_command)
  end

  def execute_prerun_command
    execute_from_setting(:prerun_command)
  end

  # Initialize and load storage
  def dostorage
      Puppet::Util::Storage.load
      @compile_time ||= Puppet::Util::Storage.cache(:configuration)[:compile_time]
  rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Corrupt state file #{Puppet[:statefile]}: #{detail}"
      begin
        ::File.unlink(Puppet[:statefile])
        retry
      rescue => detail
        raise Puppet::Error.new("Cannot remove #{Puppet[:statefile]}: #{detail}")
      end
  end

  # Just so we can specify that we are "the" instance.
  def initialize
    Puppet.settings.use(:main, :ssl, :agent)

    self.class.instance = self
    @running = false
    @splayed = false
  end

  def initialize_report
    Puppet::Transaction::Report.new
  end

  # Prepare for catalog retrieval.  Downloads everything necessary, etc.
  def prepare(options)
    dostorage

    download_plugins unless options[:skip_plugin_download]

    download_fact_plugins unless options[:skip_plugin_download]

    execute_prerun_command
  end

  # Get the remote catalog, yo.  Returns nil if no catalog can be found.
  def retrieve_catalog
    if Puppet::Resource::Catalog.indirection.terminus_class == :rest
      # This is a bit complicated.  We need the serialized and escaped facts,
      # and we need to know which format they're encoded in.  Thus, we
      # get a hash with both of these pieces of information.
      fact_options = facts_for_uploading
    else
      fact_options = {}
    end

    # First try it with no cache, then with the cache.
    unless (Puppet[:use_cached_catalog] and result = retrieve_catalog_from_cache(fact_options)) or result = retrieve_new_catalog(fact_options)
      if ! Puppet[:usecacheonfailure]
        Puppet.warning "Not using cache on failed catalog"
        return nil
      end
      result = retrieve_catalog_from_cache(fact_options)
    end

    return nil unless result

    convert_catalog(result, @duration)
  end

  # Convert a plain resource catalog into our full host catalog.
  def convert_catalog(result, duration)
    catalog = result.to_ral
    catalog.finalize
    catalog.retrieval_duration = duration
    catalog.write_class_file
    catalog
  end

  # The code that actually runs the catalog.
  # This just passes any options on to the catalog,
  # which accepts :tags and :ignoreschedules.
  def run(options = {})
    begin
      prepare(options)
    rescue SystemExit,NoMemoryError
      raise
    rescue Exception => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Failed to prepare catalog: #{detail}"
    end

    options[:report] ||= initialize_report
    report = options[:report]
    Puppet::Util::Log.newdestination(report)

    if catalog = options[:catalog]
      options.delete(:catalog)
    elsif ! catalog = retrieve_catalog
      Puppet.err "Could not retrieve catalog; skipping run"
      return
    end

    transaction = nil

    begin
      benchmark(:notice, "Finished catalog run") do
        transaction = catalog.apply(options)
      end
      report
    rescue => detail
      puts detail.backtrace if Puppet[:trace]
      Puppet.err "Failed to apply catalog: #{detail}"
      return
    end
  ensure
    # Make sure we forget the retained module_directories of any autoload
    # we might have used.
    Thread.current[:env_module_directories] = nil

    # Now close all of our existing http connections, since there's no
    # reason to leave them lying open.
    Puppet::Network::HttpPool.clear_http_instances
    execute_postrun_command

    Puppet::Util::Log.close(report)
    send_report(report, transaction)
  end

  def send_report(report, trans = nil)
    trans.generate_report if trans
    puts report.summary if Puppet[:summarize]
    save_last_run_summary(report)
    if Puppet[:report]
      Puppet::Transaction::Report.indirection.save(report)
    end
  rescue => detail
    puts detail.backtrace if Puppet[:trace]
    Puppet.err "Could not send report: #{detail}"
  end

  def save_last_run_summary(report)
    Puppet::Util::FileLocking.writelock(Puppet[:lastrunfile], 0660) do |file|
      file.print YAML.dump(report.raw_summary)
    end
  rescue => detail
    puts detail.backtrace if Puppet[:trace]
    Puppet.err "Could not save last run local report: #{detail}"
  end

  private

  def self.timeout
    timeout = Puppet[:configtimeout]
    case timeout
    when String
      if timeout =~ /^\d+$/
        timeout = Integer(timeout)
      else
        raise ArgumentError, "Configuration timeout must be an integer"
      end
    when Integer # nothing
    else
      raise ArgumentError, "Configuration timeout must be an integer"
    end

    timeout
  end

  def execute_from_setting(setting)
    return if (command = Puppet[setting]) == ""

    begin
      Puppet::Util.execute([command])
    rescue => detail
      raise CommandHookError, "Could not run command from #{setting}: #{detail}"
    end
  end

  def retrieve_catalog_from_cache(fact_options)
    result = nil
    @duration = thinmark do
      result = Puppet::Resource::Catalog.indirection.find(Puppet[:certname], fact_options.merge(:ignore_terminus => true))
    end
    Puppet.notice "Using cached catalog"
    result
  rescue => detail
    puts detail.backtrace if Puppet[:trace]
    Puppet.err "Could not retrieve catalog from cache: #{detail}"
    return nil
  end

  def retrieve_new_catalog(fact_options)
    result = nil
    @duration = thinmark do
      result = Puppet::Resource::Catalog.indirection.find(Puppet[:certname], fact_options.merge(:ignore_cache => true))
    end
    result
  rescue SystemExit,NoMemoryError
    raise
  rescue Exception => detail
    puts detail.backtrace if Puppet[:trace]
    Puppet.err "Could not retrieve catalog from remote server: #{detail}"
    return nil
  end
end
