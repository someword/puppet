require 'puppet'
require 'puppet/application'
require 'puppet/ssl/certificate_authority'

Puppet::Application.new(:ca) do

    should_parse_config

    attr_accessor :mode, :all, :ca, :digest

    def find_mode(opt)
        modes = Puppet::SSL::CertificateAuthority::Interface::INTERFACE_METHODS
        tmp = opt.sub("--", '').to_sym
        @mode = modes.include?(tmp) ? tmp : nil
    end

    option("--clean", "-c") do
        @mode = :destroy
    end

    option("--all", "-a") do
        @all = true
    end

    option("--digest DIGEST") do |arg|
        @digest = arg
    end

    option("--debug", "-d") do |arg|
        Puppet::Util::Log.level = :debug
    end

    Puppet::SSL::CertificateAuthority::Interface::INTERFACE_METHODS.reject {|m| m == :destroy }.each do |method|
        option("--#{method}", "-#{method.to_s[0,1]}") do
            find_mode("--#{method}")
        end
    end

    option("--verbose", "-v") do
        Puppet::Util::Log.level = :info
    end

    command(:main) do
        if @all
            hosts = :all
        else
            hosts = ARGV.collect { |h| puts h; h.downcase }
        end
        begin
            @ca.apply(:revoke, :to => hosts) if @mode == :destroy
            @ca.apply(@mode, :to => hosts, :digest => @digest)
        rescue => detail
            puts detail.backtrace if Puppet[:trace]
            puts detail.to_s
            exit(24)
        end
    end

    setup do
        exit(Puppet.settings.print_configs ? 0 : 1) if Puppet.settings.print_configs?

        Puppet::Util::Log.newdestination :console

        Puppet::SSL::Host.ca_location = :only

        begin
            @ca = Puppet::SSL::CertificateAuthority.new
        rescue => detail
            puts detail.backtrace if Puppet[:trace]
            puts detail.to_s
            exit(23)
        end
    end
end
