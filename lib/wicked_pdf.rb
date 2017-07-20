# wkhtml2pdf Ruby interface
# http://wkhtmltopdf.org/

require 'logger'
require 'digest/md5'
require 'rbconfig'
require 'webkit_remote'
require 'base64'
require 'timeout'
require 'pdf-reader'
require 'tempfile'

if (RbConfig::CONFIG['target_os'] =~ /mswin|mingw/) && (RUBY_VERSION < '1.9')
  require 'win32/open3'
else
  require 'open3'
end

begin
  require 'active_support/core_ext/module/attribute_accessors'
rescue LoadError
  require 'active_support/core_ext/class/attribute_accessors'
end

begin
  require 'active_support/core_ext/object/blank'
rescue LoadError
  require 'active_support/core_ext/blank'
end

require 'wicked_pdf/version'
require 'wicked_pdf/railtie'
require 'wicked_pdf/tempfile'
require 'wicked_pdf/middleware'

class WickedPdf
  DEFAULT_BINARY_VERSION = Gem::Version.new('0.9.9')
  BINARY_VERSION_WITHOUT_DASHES = Gem::Version.new('0.12.0')
  EXE_NAMES = ['google-chrome', 'Google Chrome Canary', 'Google Chrome'].freeze
  @@config = {}
  cattr_accessor :config
  attr_accessor :binary_version

  def initialize(chrome_binary_path = nil)
    @exe_path = chrome_binary_path || find_chrome_binary_path
    raise "Location of #{EXE_NAMES[1]} unknown" if @exe_path.empty?
    raise "Bad #{EXE_NAMES[1]}'s path: #{@exe_path}" unless File.exist?(@exe_path)
    raise "#{EXE_NAMES[1]} is not executable" unless File.executable?(@exe_path)

    retrieve_binary_version
  end

  def pdf_from_html_file(filepath, options = {})
    pdf_from_url("file:///#{filepath}", options)
  end

  def pdf_from_string(string, options = {})
    options = options.dup
    options.merge!(WickedPdf.config) { |_key, option, _config| option }
    string_file = WickedPdfTempfile.new('wicked_pdf.html', options[:temp_path])
    string_file.binmode
    string_file.write(string)
    string_file.close

    pdf = pdf_from_html_file(string_file.path, options)
    pdf
  ensure
    string_file.close! if string_file
  end

  def generate_port_number
    rand(65_000 - 9222) + 9222
  end

  def try_to_connect(host, port)
    Timeout::timeout(1) {
      @client = WebkitRemote.remote host: host, port: port
    }
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
  def launch_chrome(host, port)
    options = "--headless --disable-gpu --remote-debugging-port=#{port} about:blank"
    cmd = @exe_path.gsub(' ', '\ ') + ' ' + options
    print_command(cmd.inspect) if in_development_mode?

    pid = spawn(cmd)
    Rails.logger.info "Chrome running with pid: #{pid}, remote debugging port: #{port}"
    sleep 0.2
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
        sleep 0.01
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

    Rails.logger.info "PDF options: #{options.inspect}"

    host = '127.0.0.1'
    port = find_available_port(host)

    pid = launch_chrome(host, port)

    connect_to_chrome(host, port)

    @client.page_events = true
    @client.network_events = true
    @client.navigate_to url
    time = Time.now
    Rails.logger.info 'Waiting for page to load...'
    @client.wait_for(type: WebkitRemote::Event::PageLoaded).last
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
      pageRanges: options[:pageRanges] || ''
    }

    data = @client.rpc.call('Page.printToPDF', pdf_options)
    pdf = Base64.decode64(data['data'])
    Rails.logger.info "  PDF generated in #{Time.now - t} sec"

    if options[:pageCounterFunction]
      # 1. read the PDF to figure out the number of pages
      # > https://github.com/yob/pdf-reader
      Rails.logger.info 'Reading PDF...'
      file = Tempfile.new(['print', '.pdf'])
      file.binmode
      file.write(pdf)
      file.close
      t = Time.now
      reader = PDF::Reader.new(file.path)
      page_count = reader.page_count
      file.unlink
      Rails.logger.info "  PDF has #{page_count} pages. #{Time.now - t} sec"

      Rails.logger.info 'Adding page numbers...'
      # 2. inject the number of pages in javascript and call page_numbering
      javascript_eval = "#{options[:pageCounterFunction]}(#{page_count}, #{pdf_options[:paperWidth]}, #{pdf_options[:paperHeight]}, #{pdf_options[:marginTop]}, #{pdf_options[:marginRight]}, #{pdf_options[:marginBottom]}, #{pdf_options[:marginLeft]});"
      Rails.logger.info '  ' + javascript_eval
      result = @client.remote_eval javascript_eval
      Rails.logger.info "  Done! #{result}"

      # 3. re-print to PDF again
      sleep 0.1
      Rails.logger.info 'Re-printing to PDF...'
      t = Time.now
      data = @client.rpc.call('Page.printToPDF', pdf_options)
      pdf = Base64.decode64(data['data'])
      Rails.logger.info "  PDF generated in #{Time.now - t}s!"
    end

    @client.close
    Process.kill 'TERM', pid
    Rails.logger.info 'Closing Chrome!'
    pid = nil

    raise "PDF could not be generated!\n Command Error: #{err}" if pdf && pdf.rstrip.empty?
    pdf
  rescue => e
    raise "Failed to generate PDF\nError: #{e}"
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

  def retrieve_binary_version
    _stdin, stdout, _stderr = Open3.popen3(@exe_path + ' -V')
    @binary_version = parse_version(stdout.gets(nil))
  rescue
    DEFAULT_BINARY_VERSION
  end

  def parse_version(version_info)
    match_data = /wkhtmltopdf\s*(\d*\.\d*\.\d*\w*)/.match(version_info)
    if match_data && (2 == match_data.length)
      Gem::Version.new(match_data[1])
    else
      DEFAULT_BINARY_VERSION
    end
  end

  def parse_options(options)
    [
      parse_extra(options),
      parse_others(options),
      parse_global(options),
      parse_outline(options.delete(:outline)),
      parse_header_footer(:header => options.delete(:header),
                          :footer => options.delete(:footer),
                          :layout => options[:layout]),
      parse_cover(options.delete(:cover)),
      parse_toc(options.delete(:toc)),
      parse_basic_auth(options)
    ].flatten
  end

  def parse_extra(options)
    return [] if options[:extra].nil?
    return options[:extra].split if options[:extra].respond_to?(:split)
    options[:extra]
  end

  def parse_basic_auth(options)
    if options[:basic_auth]
      user, passwd = Base64.decode64(options[:basic_auth]).split(':')
      ['--username', user, '--password', passwd]
    else
      []
    end
  end

  def make_option(name, value, type = :string)
    if value.is_a?(Array)
      return value.collect { |v| make_option(name, v, type) }
    end
    if type == :name_value
      parts = value.to_s.split(' ')
      ["--#{name.tr('_', '-')}", *parts]
    elsif type == :boolean
      if value
        ["--#{name.tr('_', '-')}"]
      else
        []
      end
    else
      ["--#{name.tr('_', '-')}", value.to_s]
    end
  end

  def valid_option(name)
    if binary_version < BINARY_VERSION_WITHOUT_DASHES
      "--#{name}"
    else
      name
    end
  end

  def make_options(options, names, prefix = '', type = :string)
    return [] if options.nil?
    names.collect do |o|
      if options[o].blank?
        []
      else
        make_option("#{prefix.blank? ? '' : prefix + '-'}#{o}",
                    options[o],
                    type)
      end
    end
  end

  def parse_header_footer(options)
    r = []
    unless options.blank?
      [:header, :footer].collect do |hf|
        next if options[hf].blank?
        opt_hf = options[hf]
        r += make_options(opt_hf, [:center, :font_name, :left, :right], hf.to_s)
        r += make_options(opt_hf, [:font_size, :spacing], hf.to_s, :numeric)
        r += make_options(opt_hf, [:line], hf.to_s, :boolean)
        if options[hf] && options[hf][:content]
          @hf_tempfiles = [] unless defined?(@hf_tempfiles)
          @hf_tempfiles.push(tf = WickedPdfTempfile.new("wicked_#{hf}_pdf.html"))
          tf.write options[hf][:content]
          tf.flush
          options[hf][:html] = {}
          options[hf][:html][:url] = "file:///#{tf.path}"
        end
        unless opt_hf[:html].blank?
          r += make_option("#{hf}-html", opt_hf[:html][:url]) unless opt_hf[:html][:url].blank?
        end
      end
    end
    r
  end

  def parse_cover(argument)
    arg = argument.to_s
    return [] if arg.blank?
    # Filesystem path or URL - hand off to wkhtmltopdf
    if argument.is_a?(Pathname) || (arg[0, 4] == 'http')
      [valid_option('cover'), arg]
    else # HTML content
      @hf_tempfiles ||= []
      @hf_tempfiles << tf = WickedPdfTempfile.new('wicked_cover_pdf.html')
      tf.write arg
      tf.flush
      [valid_option('cover'), tf.path]
    end
  end

  def parse_toc(options)
    return [] if options.nil?
    r = [valid_option('toc')]
    unless options.blank?
      r += make_options(options, [:font_name, :header_text], 'toc')
      r += make_options(options, [:xsl_style_sheet])
      r += make_options(options, [:depth,
                                  :header_fs,
                                  :text_size_shrink,
                                  :l1_font_size,
                                  :l2_font_size,
                                  :l3_font_size,
                                  :l4_font_size,
                                  :l5_font_size,
                                  :l6_font_size,
                                  :l7_font_size,
                                  :level_indentation,
                                  :l1_indentation,
                                  :l2_indentation,
                                  :l3_indentation,
                                  :l4_indentation,
                                  :l5_indentation,
                                  :l6_indentation,
                                  :l7_indentation], 'toc', :numeric)
      r += make_options(options, [:no_dots,
                                  :disable_links,
                                  :disable_back_links], 'toc', :boolean)
      r += make_options(options, [:disable_dotted_lines,
                                  :disable_toc_links], nil, :boolean)
    end
    r
  end

  def parse_outline(options)
    r = []
    unless options.blank?
      r = make_options(options, [:outline], '', :boolean)
      r += make_options(options, [:outline_depth], '', :numeric)
    end
    r
  end

  def parse_margins(options)
    make_options(options, [:top, :bottom, :left, :right], 'margin', :numeric)
  end

  def parse_global(options)
    r = []
    unless options.blank?
      r += make_options(options, [:orientation,
                                  :dpi,
                                  :page_size,
                                  :page_width,
                                  :title])
      r += make_options(options, [:lowquality,
                                  :grayscale,
                                  :no_pdf_compression], '', :boolean)
      r += make_options(options, [:image_dpi,
                                  :image_quality,
                                  :page_height], '', :numeric)
      r += parse_margins(options.delete(:margin))
    end
    r
  end

  def parse_others(options)
    r = []
    unless options.blank?
      r += make_options(options, [:proxy,
                                  :username,
                                  :password,
                                  :encoding,
                                  :user_style_sheet,
                                  :viewport_size,
                                  :window_status])
      r += make_options(options, [:cookie,
                                  :post], '', :name_value)
      r += make_options(options, [:redirect_delay,
                                  :zoom,
                                  :page_offset,
                                  :javascript_delay], '', :numeric)
      r += make_options(options, [:book,
                                  :default_header,
                                  :disable_javascript,
                                  :enable_plugins,
                                  :disable_internal_links,
                                  :disable_external_links,
                                  :print_media_type,
                                  :disable_smart_shrinking,
                                  :use_xserver,
                                  :no_background,
                                  :no_stop_slow_scripts], '', :boolean)
    end
    r
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
