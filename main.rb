require 'optparse'
require 'ostruct'
require 'timeout'
require 'rotp'
require 'rqrcode'
require 'logger'

require 'rubygems'
require 'selenium-webdriver'
require 'capybara'
require 'capybara/dsl'
require 'concurrent'

class ThreadSafeLogger < Logger
  def initialize(*args)
    super
    @mutex = Mutex.new
  end

  def add(severity, message = nil, progname = nil, &block)
    @mutex.synchronize { super }
  end
end

options = {
  download_path: File.join(File.absolute_path(__dir__), 'ebooks'),
  password: ENV['AMAZON_PASSWORD'],
  username: ENV['AMAZON_USERNAME'],
  device: ENV['AMAZON_DEVICE'],
  totp_secret: ENV['AMAZON_TOTP_SECRET'],
  concurrency: 10,
  headless: false
}

OptionParser.new do |opts|
  opts.banner = 'Usage: main.rb [options]'

  opts.on('-uUSERNAME', '--username=USERNAME', 'Amazon Username') do |username|
    options[:username] = username
  end

  opts.on('-pPASSWORD', '--password=PASSWORD',
          "Amazon Password, defaults to the AMAZON_PASSWORD environment variable (#{options[:password]})") do |password|
    options[:password] = password
  end

  opts.on('-dDEVICE', '--device=DEVICE', 'Kindle Device') do |device|
    options[:device] = device
  end

  opts.on('-p', '--path=DOWNLOAD_PATH',
          "Where to store downloaded books, default: '#{options[:download_path]}'") do |download_path|
    options[:download_path] = download_path
  end

  opts.on('--disable-idempotency',
          'Download every book regardless of if it has already been downloaded.') do |_disable_idempotency|
    options[:disable_idempotency] = true
  end

  opts.on('-cCONCURRENCY', '--concurrency=CONCURRENCY', Integer,
          'Number of concurrent downloads (default: 3)') do |c|
    options[:concurrency] = c
  end

  opts.on('--headless', 'Run browser in headless mode') do
    options[:headless] = true
  end

  opts.on('--debug', 'Enable debug mode (forces headless)') do
    options[:clean_debug] = true
    options[:headless] = true
  end

  opts.on('-h', '--help', 'Print this help') do
    puts opts
    exit
  end
end.parse!

class KindleDownloader
  attr_accessor :username, :password, :device, :download_path, :disable_idempotency, :headless, :logger

  include Capybara::DSL

  def initialize(download_path:, username: nil, password: nil, device: nil,
                 disable_idempotency: false, totp_secret: nil, clean_debug: false, concurrency: 3,
                 headless: false)
    self.username = username
    self.password = password
    self.device = device
    self.download_path = download_path
    self.disable_idempotency = disable_idempotency
    @clean_debug = clean_debug
    @concurrency = concurrency
    @page_cache = {}
    @semaphore = ::Concurrent::Semaphore.new(@concurrency)
    @cache_mutex = Mutex.new
    @totp = totp_secret ? ROTP::TOTP.new(totp_secret) : nil
    @valid_page_selector = nil
    self.headless = headless

    log_path = File.join(download_path, 'kindle_downloader.log')
    File.delete(log_path) if clean_debug && File.exist?(log_path)

    self.logger = ThreadSafeLogger.new(log_path)
    logger.formatter = proc do |severity, datetime, _progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{severity}: #{msg}\n"
    end
    logger.level = Logger::INFO
  end

  def sanitize_title(title)
    return '' unless title
    
    title.downcase
         .gsub(/[^a-z0-9\s]/, '') # Remove special chars except spaces/numbers
         .gsub(/\s+/, '_')        # Convert spaces to underscores
         .gsub(/_+/, '_')         # Remove duplicate underscores
         .chomp('_')
  end

  def book_downloaded?(clean_title)
    @cache_mutex.synchronize do
      Dir.glob("#{download_path}/#{clean_title}.*").any?
    end
  end

  def attempt_download(clean_title)
    visit('/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/')
    
    # Find the specific book row using the cached title
    book_row = find('.digital_entity_title', text: /#{Regexp.escape(clean_title)}/i)
                            .ancestor('.ListItem-module_row__3orql')

    book_row.find('.dropdown_title').click
    book_row.find('span', text: 'Download & transfer via USB').click
    find('li', text: device).find('input', visible: false).click
    find_all('span', text: 'Download').last.click
    find('#notification-close').click
  rescue Capybara::ElementNotFound => e
    logger.warn "Skipping unavailable: #{clean_title}"
  rescue => e
    logger.error "Retrying #{clean_title}: #{e.message}"
    page.execute_script('window.location.reload()')
    retry
  end

  def download_ebooks
    visit('/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/')
    sign_in
    @page_cache = build_page_cache # Store in instance variable
    process_cache_concurrently
  end

  def process_cache_concurrently
    logger.info "Starting concurrent processing of #{@page_cache.size} pages"
    
    executor = Concurrent::ThreadPoolExecutor.new(
      max_threads: @concurrency,
      max_queue: @page_cache.size
    )

    # Process all titles from cache instead of visiting pages again
    futures = @page_cache.values.flat_map do |page_data|
      page_data[:titles].map do |clean_title|
        Concurrent::Future.execute(executor: executor) do
          next if book_downloaded?(clean_title) && !disable_idempotency

          Capybara.using_session("download-#{clean_title}") do
            begin
              logger.info "Downloading #{clean_title}"
              attempt_download(clean_title)
            rescue => ex
              logger.error "Failed to download #{clean_title}: #{ex.message}"
            end
          end
        end
      end
    end

    futures.each(&:value)
  ensure
    executor&.shutdown
  end

  def do_download_ebooks
    visit('/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/')
    sign_in
    build_page_cache

    page_number = 1

    loop do
      page_number = next_page(page_number)

      download_page
    end
  ensure
    binding.irb
  end

  def title_from_row(row)
    return nil if row.text.include?('This title is unavailable for download and transfer')

    row.find('.digital_entity_title').text
  end

  def build_page_cache
    logger.info "Building page cache with #{@concurrency} threads"
    
    # Get all page URLs first using main session
    page_urls = [current_url]
    pagination_links = all("[id^='page-']", wait: 10)
    pagination_links.each { |link| page_urls << link[:href] }
    page_urls.uniq!
    logger.info "page count: #{page_urls.count}"
    binding.irb

    # Create completely independent sessions for each thread
    executor = Concurrent::ThreadPoolExecutor.new(
      max_threads: @concurrency,
      max_queue: page_urls.size
    )

    futures = page_urls.map.with_index do |url, index|
      Concurrent::Future.execute(executor: executor) do
        # Create new independent session
        session = Capybara::Session.new(Capybara.current_driver, Capybara.app)
        
        begin
          logger.info "Processing page #{index + 1}/#{page_urls.size}"
          session.visit(url)
          
          titles = session.all('.ListItem-module_row__3orql').map do |row|
            next if row.text.include?('This title is unavailable')
            
            title = row.find('.digital_entity_title').text rescue nil
            sanitize_title(title) if title
          end.compact

          {
            page_number: index + 1,
            url: session.current_url,
            titles: titles
          }
        rescue => ex
          logger.error "Page #{index + 1} error: #{ex.message}"
          nil
        ensure
          session.driver.quit
        end
      end
    end

    page_cache = futures.each_with_object({}) do |future, cache|
      result = future.value
      cache[result[:page_number]] = result if result
    end

    logger.info "Built cache for #{page_cache.size}/#{page_urls.size} pages"
    page_cache
  end

  def next_page(page_number)
    return 2 if page_number == 1

    if page_sel = find("#page-#{page_number}")
      page_sel.click
      page_number + 1
    else
      false
    end
  end

  def book_rows(&block)
    return to_enum(__callee__) unless block_given?

    find_all('.ListItem-module_row__3orql').each(&block)
  end



  def sign_in
    return unless username && password

    fill_in('ap_email', with: username)
    fill_in('ap_password', with: password)
    click_button('signInSubmit')

    # Handle TOTP if required
    handle_totp_verification if has_selector?('#auth-mfa-otpcode', wait: 10)

    find('#nav-tools', wait: 10) # Wait for login completion
  end

  def handle_totp_verification
    if @totp
      3.times do |attempt| # Retry up to 3 times
        code = @totp.now
        fill_in('auth-mfa-otpcode', with: code)
        click_button('auth-signin-button')

        break unless has_selector?('#auth-error-message-box', wait: 2)

        logger.warn 'TOTP verification failed...' if attempt < 2
      end
    else
      logger.error 'TOTP required but not configured'
      exit 1
    end
  end
end

Capybara.register_driver :custom_download_path do |app|
  profile = Selenium::WebDriver::Firefox::Profile.new
  profile['browser.download.dir'] = options[:download_path]
  profile['browser.download.folderList'] = 2
  profile['devtools.console.stdout.content'] = true

  firefox_options = Selenium::WebDriver::Firefox::Options.new(profile:)
  firefox_options.add_argument('-headless') if options[:headless]

  Capybara::Selenium::Driver.new(
    app,
    browser: :firefox,
    options: firefox_options,
    clear_local_storage: true,
    clear_session_storage: true
  )
end

if options[:analyze_debug]
  PageAnalyzer.analyze_debug_directory(options[:analyze_debug])
elsif options[:setup_totp]
  # Existing TOTP setup code
else
  Capybara.current_driver = :custom_download_path
  Capybara.app_host = 'https://www.amazon.com'
  downloader = KindleDownloader.new(
    **options.except(:setup_totp),
    clean_debug: options[:clean_debug],
    concurrency: options[:concurrency],
    headless: options[:headless]
  )
  begin
    downloader.download_ebooks
  ensure
    downloader.logger.close
  end
end
