
require "optparse"
require "ostruct"
require "timeout"
require "rotp"
require "rqrcode"

require "rubygems"
require "selenium-webdriver"
require "capybara"
require "capybara/dsl"
require "concurrent"

options = {
  download_path: File.join(File.absolute_path(__dir__), "ebooks"),
  password: ENV["AMAZON_PASSWORD"],
  username: ENV["AMAZON_USERNAME"],
  device: ENV["AMAZON_DEVICE"],
  totp_secret: ENV["AMAZON_TOTP_SECRET"]
}


OptionParser.new do |opts|
  opts.banner = "Usage: main.rb [options]"

  opts.on("-uUSERNAME", "--username=USERNAME", "Amazon Username") do |username|
    options[:username] = username
  end

  opts.on("-pPASSWORD", "--password=PASSWORD", "Amazon Password, defaults to the AMAZON_PASSWORD environment variable (#{options[:password]})") do |password|
    options[:password] = password
  end

  opts.on("-dDEVICE", "--device=DEVICE", "Kindle Device") do |device|
    options[:device] = device
  end

  opts.on("-p", "--path=DOWNLOAD_PATH", "Where to store downloaded books, default: '#{options[:download_path]}'") do |download_path|
    options[:download_path] = download_path
  end

  opts.on("--disable-idempotency", "Download every book regardless of if it has already been downloaded.") do |disable_idempotency|
    options[:disable_idempotency] = true
  end

  opts.on("-h", "--help", "Print this help") do
    puts opts
    exit
  end
end.parse!

class KindleDownloader
  attr_accessor :username, :password, :device, :download_path, :disable_idempotency

  include Capybara::DSL

  def initialize(download_path:, username: nil, password: nil, device: nil, 
    disable_idempotency: false, totp_secret: nil, clean_debug: false)
    self.username = username
    self.password = password
    self.device = device
    self.download_path = download_path
    self.disable_idempotency = disable_idempotency
    @clean_debug = clean_debug

    @page_cache = {}
    @semaphore = ::Concurrent::Semaphore.new(3)
    @cache_mutex = Mutex.new
    @totp = totp_secret ? ROTP::TOTP.new(totp_secret) : nil
    @valid_page_selector = nil
  end


  def sanitize_title(title)
    title.downcase
      .gsub(/[^a-z0-9\s]/, '') # Remove special chars except spaces/numbers
      .gsub(/\s+/, '_')        # Convert spaces to underscores
      .gsub(/_+/, '_')         # Remove duplicate underscores
      .chomp('_')
  end

  def book_downloaded?(clean_title)
    @cache_mutex.synchronize {
      Dir.glob("#{download_path}/*").any? do |path|
        filename = File.basename(path, '.*')
        sanitize_title(filename).include?(clean_title)
      end
    }
  end

  def download_ebooks
    visit("/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/")
    sign_in
    page_cache = build_page_cache
    binding.irb
    process_cache_concurrently
  end

  def process_cache_concurrently
  end

  def do_download_ebooks
    visit("/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/")
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
    return nil if row.text.include?("This title is unavailable for download and transfer")
    row.find(".digital_entity_title").text
  end

  def build_page_cache
    page_cache = {}

    page_number = 1

    loop do
      begin
      page_number = next_page(page_number)
      break unless page_number
      titles = book_rows.map do |book_row|
        sanitize_title( title_from_row(book_row))
      end.compact
      page_cache[page_number] = titles
      rescue => ex
         puts "error #{ex.message}"
         next
      end
    end
    page_cache
  ensure
    binding.irb
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

  def book_rows
    return to_enum(__callee__) unless block_given?
    find_all(".ListItem-module_row__3orql").each do |book_row|
      yield book_row
    end
  end

  def download_page
    find_all(".ListItem-module_row__3orql").each do |book_row|
      download_book(book_row)
    end
  end

  def download_book(book_row)
    return if book_row.text.include?("This title is unavailable for download and transfer")
    book_title = book_row.find(".digital_entity_title").text
    if already_downloaded?(book_title) && !disable_idempotency
      puts "Skipping #{book_title}"
      return
    end

    puts "Downloading #{book_title}..."

    book_row.find(".dropdown_title").click
    book_row.find("span", text: "Download & transfer via USB").click
    find("li", text: device).find("input", visible: false).click
    find_all("span", text: "Download").last.click
    find("#notification-close").click
  rescue Capybara::ElementNotFound => _
    if page.text.include?("You do not have any compatible devices")
      find("span", text: "Cancel").click
    end
    puts "No download for this one #{book_title}"
  rescue => _
    binding.irb
    raise $1
  end

  def sign_in
    return unless username && password

    fill_in("ap_email", with: username)
    fill_in("ap_password", with: password)
    click_button("signInSubmit")

    # Handle TOTP if required
    if has_selector?("#auth-mfa-otpcode", wait: 10)
      handle_totp_verification
    end

    find("#nav-tools", wait: 10) # Wait for login completion
  end

  def handle_totp_verification
    if @totp
      3.times do |attempt| # Retry up to 3 times
        code = @totp.now
        fill_in("auth-mfa-otpcode", with: code)
        click_button("auth-signin-button")

        break unless has_selector?("#auth-error-message-box", wait: 2)
        puts "⚠️  TOTP verification failed, retrying..." if attempt < 2
      end
    else
      puts "❌ TOTP required but no secret configured. Set AMAZON_TOTP_SECRET"
      exit 1
    end
  end

end

Capybara.register_driver :custom_download_path do |app|
  profile = Selenium::WebDriver::Firefox::Profile.new
  profile["browser.download.dir"] = options[:download_path]
  profile["browser.download.folderList"] = 2
  # Enable browser console logging
  profile['devtools.console.stdout.content'] = true

  firefox_options = Selenium::WebDriver::Firefox::Options.new(profile:)

  Capybara::Selenium::Driver.new(app, browser: :firefox, options: firefox_options)
end

if options[:analyze_debug]
  PageAnalyzer.analyze_debug_directory(options[:analyze_debug])
elsif options[:setup_totp]
  # Existing TOTP setup code
else
  Capybara.current_driver = :custom_download_path
  Capybara.app_host = "https://www.amazon.com"
  KindleDownloader.new(**options.except(:setup_totp), clean_debug: options[:clean_debug]).download_ebooks
end
