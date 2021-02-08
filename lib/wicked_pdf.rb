# wkhtml2pdf Ruby interface
# http://wkhtmltopdf.org/

require 'logger'
require 'digest/md5'
require 'rbconfig'
require 'chrome_remote'
require 'base64'
require 'tempfile'
require 'open3'

require 'active_support/core_ext/module/attribute_accessors'
require 'active_support/core_ext/object/blank'

require 'wicked_pdf/version'
require 'wicked_pdf/railtie'
require 'wicked_pdf/option_parser'
require 'wicked_pdf/tempfile'
# require 'wicked_pdf/binary'
require 'wicked_pdf/middleware'
require 'wicked_pdf/progress'

class WickedPdf
  DEFAULT_BINARY_VERSION = Gem::Version.new('0.9.9')
  BINARY_VERSION_WITHOUT_DASHES = Gem::Version.new('0.12.0')
  EXE_NAMES = ['google-chrome', 'Google Chrome Canary', 'Google Chrome'].freeze
  @@config = {}
  cattr_accessor :config
  attr_accessor :binary_version

  include Progress

  def initialize(chrome_binary_path = nil)
    @exe_path = chrome_binary_path || find_chrome_binary_path
    raise "Location of #{EXE_NAMES[1]} unknown" if @exe_path.empty?
    raise "Bad #{EXE_NAMES[1]}'s path: #{@exe_path}" unless File.exist?(@exe_path)
    raise "#{EXE_NAMES[1]} is not executable" unless File.executable?(@exe_path)
  end

  def binary_version
    ''
  end

  def pdf_from_html_file(filepath, options = {})
    pdf_from_url("file:///#{filepath}", options)
  end

  def pdf_from_string(string, options = {})
    options = options.dup
    options.merge!(WickedPdf.config) { |_key, option, _config| option }
    string_file = WickedPdf::Tempfile.new('wicked_pdf.html', options[:temp_path])
    string_file.write_in_chunks(string)
    pdf_from_html_file(string_file.path, options)
  ensure
    string_file.close if string_file
  end

  def generate_port_number
    rand(65_000 - 9222) + 9222
  end

  def try_to_connect(host, port)
    @client = ChromeRemote.client host: host, port: port
  end

  def find_available_port(host)
    port = generate_port_number
    begin
      t = TCPServer.new(host, port)
    rescue Errno::EADDRINUSE
      port = generate_port_number
      retry
    end
    t.close
    port
  end

  # Launch Chrome headless
  def launch_chrome(host, port, debug=false)
    options = "--headless --disable-gpu --remote-debugging-port=#{port} about:blank"
    cmd = @exe_path.gsub(' ', '\ ') + ' ' + options
    print_command(cmd.inspect) if in_development_mode?

    pid = spawn(cmd)
    Rails.logger.info "Chrome running with pid: #{pid}, remote debugging port: #{port}"
    # Wait a bit for Chrome to be fully awake
    sleep 2
    pid
  end

  def connect_to_chrome(host, port)
    connected = false
    retry_count = 0
    Rails.logger.info 'Trying to connect...'
    until connected && retry_count < 30
      begin
        retry_count += 1
        try_to_connect(host, port)
        connected = true
      rescue Errno::ECONNREFUSED, SocketError
        sleep 0.1
      end
    end

    if connected
      Rails.logger.info '  Connected!'
      sleep 0.1 # Need to wait a bit here before sending commands
    else
      Rails.logger.info ' Error: can\'t connect to Chrome'
      raise "Couldn't connect to Chrome"
    end
  end

  def pdf_from_url(url, options = {})
    # merge in global config options
    options.merge!(WickedPdf.config) { |_key, option, _config| option }

    host = '127.0.0.1'
    port = find_available_port(host)

    pid = launch_chrome(host, port)

    cmd = @exe_path.gsub(' ', '\ ') + ' ' + url
    if options[:debug] && in_development_mode?
      Rails.logger.info "Debug mode - opening web page as well"
      print_command(cmd.inspect) if in_development_mode?
      spawn(cmd)
    end

    connect_to_chrome(host, port)

    @client.send_cmd "Page.enable"
    @client.send_cmd "Network.enable"
    @client.send_cmd "Page.navigate", url: url
    time = Time.now
    Rails.logger.info 'Waiting for page to load...'
    @client.wait_for "Page.loadEventFired"
    Rails.logger.info "  #{Time.now - time}s"

    Rails.logger.info 'Printing to PDF...'
    t = Time.now
    pdf_options = {
      printBackground: options[:printBackground] || true,
      landscape: options[:landscape] || false,
      paperHeight: options[:paperHeight] || 11,
      paperWidth: options[:paperWidth] || 8.5,
      marginTop: options[:marginTop] || 0.4,
      marginBottom: options[:marginBottom] || 0.4,
      marginLeft: options[:marginLeft] || 0.4,
      marginRight: options[:marginRight] || 0.4,
      scale: options[:scale] || 1.0,
      displayHeaderFooter: options[:displayHeaderFooter] || false,
      pageRanges: options[:pageRanges] || '',
      headerTemplate: options[:header] && options[:header][:html] ? options[:header][:html][:string] : '',
      footerTemplate: options[:footer] && options[:footer][:html] ? options[:footer][:html][:string] : ''
    }

    data = @client.send_cmd 'Page.printToPDF', pdf_options
    pdf = Base64.decode64(data['data'])
    Rails.logger.info "  PDF generated in #{Time.now - t} sec"

    Process.kill 'TERM', pid
    Rails.logger.info 'Closing Chrome!'
    pid = nil

    raise "PDF could not be generated!\n Command Error: #{err}" if pdf && pdf.rstrip.empty?
    pdf
  ensure
    Process.kill 'TERM', pid unless pid.nil?
  end

  private

  def in_development_mode?
    return Rails.env == 'development' if defined?(Rails.env)

    RAILS_ENV == 'development' if defined?(RAILS_ENV)
  end

  def on_windows?
    RbConfig::CONFIG['target_os'] =~ /mswin|mingw/
  end

  def print_command(cmd)
    Rails.logger.debug '[wicked_pdf]: ' + cmd
  end

  def parse_options(options)
    OptionParser.new(binary_version).parse(options)
  end

  def find_chrome_binary_path
    possible_locations = (ENV['PATH'].split(':') + %w(/usr/bin /usr/local/bin /Applications/Google\ Chrome\ Canary.app/Contents/MacOS /Applications/Google\ Chrome.app/Contents/MacOS)).uniq
    possible_locations += %w(~/bin) if ENV.key?('HOME')
    exe_path ||= WickedPdf.config[:chrome_path] unless WickedPdf.config.empty?
    EXE_NAMES.each do |exe_name|
      exe_path ||= possible_locations.map { |l| File.expand_path("#{l}/#{exe_name}") }.find { |location| File.exist?(location) }
    end
    exe_path || ''
  end
end
