require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'

  gem 'byebug'
  gem 'selenium-webdriver'
  gem 'rotp'
  gem 'rqrcode'
  gem 'capybara'
  gem 'concurrent-ruby'
end
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
  rescue StandardError => e
    logger.error "Retrying #{clean_title}: #{e.message}"
    page.execute_script('window.location.reload()')
    retry
  end

  def download_ebooks
    visit('/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/')
    sign_in
    @page_cache = build_page_cache # Store in instance variable
    binding.irb
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
        binding.irb
        Concurrent::Future.execute(executor: executor) do
          next if book_downloaded?(clean_title) && !disable_idempotency

          Capybara.using_session("download-#{clean_title}") do
            logger.info "Downloading #{clean_title}"
            attempt_download(clean_title)
          rescue StandardError => e
            logger.error "Failed to download #{clean_title}: #{e.message}"
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

  def process_page_content(session)
    session.all('.ListItem-module_row__3orql').map do |row|
      next if unavailable_book?(row)

      title = extract_title(row)
      sanitize_title(title)
    end.compact
  rescue StandardError => e
    logger.error "Content processing error: #{e.message}"
    []
  end

  def unavailable_book?(row)
    row.text.include?('This title is unavailable') ||
      row.text.include?('not available for download')
  end

  def extract_title(row)
    row.find('.digital_entity_title', wait: 10).text.strip
  rescue StandardError => e
    logger.warn "Title extraction failed: #{e.message}"
    nil
  end

  def build_page_cache
    logger.info 'Building complete page cache'

    # Sequential pagination to collect all page URLs
    page_urls = [current_url]
    previous_url = nil

    # Navigate through all pages using Next button
    while true
      begin
        # Check if we're stuck or reached the end
        break if page_urls.last == previous_url || page_urls.size > 500

        previous_url = page_urls.last

        # Attempt to find and click Next button
        if has_selector?('#page-RIGHT_PAGE', wait: 5)
          execute_script("document.querySelector('#page-RIGHT_PAGE').click()")

          # Wait for page load with multiple checks
          Timeout.timeout(15) do
            sleep 0.5 until all('.ListItem-module_row__3orql', minimum: 1, wait: 5) &&
                            current_url != page_urls.last
          end

          page_urls << current_url
          logger.info "Discovered page #{page_urls.size}"
        else
          logger.info 'No more pages found'
          break
        end
      rescue StandardError => e
        logger.error "Pagination error: #{e.message}"
        break
      end
    end

    logger.info "Collected #{page_urls.size} pages through navigation"

    # Get cookies from authenticated main session
    auth_cookies = page.driver.browser.manage.all_cookies

    # Concurrent processing of discovered pages
    executor = Concurrent::ThreadPoolExecutor.new(
      max_threads: [@concurrency, 10].min, # Further reduce to 2 threads
      max_queue: page_urls.size
    )

    logger.info 'about to execute urls with futures'

    futures = page_urls.map.with_index do |url, index|
      Concurrent::Future.execute(executor: executor, args: [url, index]) do |u, idx|
        url = u
        index = idx
        session = Capybara::Session.new(Capybara.current_driver, Capybara.app)
        begin
          logger.info 'In futures code to get session'
          session.visit('https://www.amazon.com')
          # sessing.driver.maximize_window  #  need handle
          # Share authentication cookies with new session
          auth_cookies.select do |c|
            c[:domain] = '.amazon.com'
          end.each { |cookie| session.driver.browser.manage.add_cookie(cookie) }
          session.refresh

          # Add authentication check
          if session.has_selector?('#ap_signin', wait: 5)
            logger.error "Session lost authentication on page #{index + 1}"
            next
          end

          logger.info "Processing page #{index + 1}/#{page_urls.size}"

          # Add more robust retry mechanism
          retries = 0
          max_retries = 3 # Increased from 2
          backoff_base = 3 # Increased from 2

          begin
            logger.info "visiting url: #{url}"
            session.visit(url)
            if session.find('.ListItem-module_row__3orql', wait: 10)
              # Improved page load verification
              # Wait for either content or error messages
              logger.info 'entering process_page_content'
              titles = process_page_content(session)
            elsif session.has_text?('No items to display', wait: 10) ||
                  session.has_text?('Server Busy', wait: 5)
              titles = []
              logger.info "Page #{index + 1} is empty or server busy"
            else
              raise 'Page content not loaded - final check: ' \
                    "Title: #{session.title[0..50]}... " \
                    "URL: #{session.current_url}"
            end

            {
              page_number: index + 1,
              url: session.current_url,
              titles: titles
            }
          rescue StandardError => e
            # Add specific authentication error handling
            if e.message.include?('SignIn')
              logger.error "Authentication failed for page #{index + 1}"
              next
            end

            if retries < max_retries
              retries += 1
              wait_time = backoff_base**retries + rand(1..3) # Add jitter
              logger.warn "Retry #{retries}/#{max_retries} for page #{index + 1}: " \
                          "#{e.message} - Waiting #{wait_time}s"
              sleep wait_time
              session.driver.quit # Clean up before retry
              session = Capybara::Session.new(Capybara.current_driver, Capybara.app)
              retry
            else
              logger.error "Page #{index + 1} failed: #{e.message}"
              nil
            end
          end
        ensure
          session.driver.quit
        end
      end
    end

    # Validate and merge results
    page_cache = futures.each_with_object({}) do |future, cache|
      result = future.value
      cache[result[:page_number]] = result if result && result[:titles].any?
    end

    logger.info "Completed processing #{page_cache.size} valid pages"
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

    # Clear existing cookies first
    page.driver.browser.manage.delete_all_cookies
    visit('/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/')

    fill_in('ap_email', with: username)
    fill_in('ap_password', with: password)
    click_button('signInSubmit')

    # Handle TOTP if required
    handle_totp_verification if has_selector?('#auth-mfa-otpcode', wait: 10)

    find('#nav-tools', wait: 10) # Wait for login completion

    # Verify successful authentication
    raise 'Authentication failed' if has_selector?('#auth-error-message-box', wait: 5)
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
