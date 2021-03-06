require 'puppet/util/instance_loader'
require 'fileutils'

# Manage Reference Documentation.
class Puppet::Util::Reference
  include Puppet::Util
  include Puppet::Util::Docs

  extend Puppet::Util::InstanceLoader

  instance_load(:reference, 'puppet/reference')

  def self.footer
    "\n\n----------------\n\n*This page autogenerated on #{Time.now}*\n"
  end

  def self.modes
    %w{pdf text}
  end

  def self.newreference(name, options = {}, &block)
    ref = self.new(name, options, &block)
    instance_hash(:reference)[symbolize(name)] = ref

    ref
  end

  def self.page(*sections)
    depth = 4
    # Use the minimum depth
    sections.each do |name|
      section = reference(name) or raise "Could not find section #{name}"
      depth = section.depth if section.depth < depth
    end
  end

  def self.pdf(text)
    puts "creating pdf"
    Puppet::Util.secure_open("/tmp/puppetdoc.txt", "w") do |f|
      f.puts text
    end
    rst2latex = which('rst2latex') || which('rst2latex.py') || raise("Could not find rst2latex")
    cmd = %{#{rst2latex} /tmp/puppetdoc.txt > /tmp/puppetdoc.tex}
    Puppet::Util.secure_open("/tmp/puppetdoc.tex","w") do |f|
      # If we get here without an error, /tmp/puppetdoc.tex isn't a tricky cracker's symlink
    end
    output = %x{#{cmd}}
    unless $CHILD_STATUS == 0
      $stderr.puts "rst2latex failed"
      $stderr.puts output
      exit(1)
    end
    $stderr.puts output

    # Now convert to pdf
    Dir.chdir("/tmp") do
      %x{texi2pdf puppetdoc.tex >/dev/null 2>/dev/null}
    end

  end

  def self.references
    instance_loader(:reference).loadall
    loaded_instances(:reference).sort { |a,b| a.to_s <=> b.to_s }
  end

  HEADER_LEVELS = [nil, "#", "##", "###", "####", "#####"]

  attr_accessor :page, :depth, :header, :title, :dynamic
  attr_writer :doc

  def doc
    if defined?(@doc)
      return "#{@name} - #{@doc}"
    else
      return @title
    end
  end

  def dynamic?
    self.dynamic
  end

  def h(name, level)
    "#{HEADER_LEVELS[level]} #{name}\n\n"
  end

  def initialize(name, options = {}, &block)
    @name = name
    options.each do |option, value|
      send(option.to_s + "=", value)
    end

    meta_def(:generate, &block)

    # Now handle the defaults
    @title ||= "#{@name.to_s.capitalize} Reference"
    @page ||= @title.gsub(/\s+/, '')
    @depth ||= 2
    @header ||= ""
  end

  # Indent every line in the chunk except those which begin with '..'.
  def indent(text, tab)
    text.gsub(/(^|\A)/, tab).gsub(/^ +\.\./, "..")
  end

  def option(name, value)
    ":#{name.to_s.capitalize}: #{value}\n"
  end

  def paramwrap(name, text, options = {})
    options[:level] ||= 5
    #str = "#{name} : "
    str = h(name, options[:level])
    str += "- **namevar**\n\n" if options[:namevar]
    str += text
    #str += text.gsub(/\n/, "\n    ")

    str += "\n\n"
  end

  # Remove all trac links.
  def strip_trac(text)
    text.gsub(/`\w+\s+([^`]+)`:trac:/) { |m| $1 }
  end

  def text
    puts output
  end

  def to_rest(withcontents = true)
    # First the header
    text = h(@title, 1)
    text += "\n\n**This page is autogenerated; any changes will get overwritten** *(last generated on #{Time.now.to_s})*\n\n"

    text += @header

    text += generate

    text += self.class.footer if withcontents

    text
  end

  def to_text(withcontents = true)
    strip_trac(to_rest(withcontents))
  end
end
