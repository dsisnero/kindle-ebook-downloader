require "optparse"
require "ostruct"

require "rubygems"
require "selenium-webdriver"
require "capybara"
require "capybara/dsl"

require "byebug"

options = {
  download_path: File.join(File.absolute_path(__dir__), "ebooks"),
  password: ENV["AMAZON_PASSWORD"]
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

  def initialize(download_path:, username: nil, password: nil, device: nil, disable_idempotency: false)
    self.username = username
    self.password = password
    self.device = device
    self.download_path = download_path
    self.disable_idempotency = disable_idempotency
  end

  def download_ebooks
    visit("/hz/mycd/digital-console/contentlist/booksPurchases/titleAsc/")
    sign_in

    page_number = 1

    loop do
      page_number = next_page(page_number)
      download_page
    end
  ensure
    byebug
  end

  def next_page(page_number)
    return 2 if page_number == 1
    find("#page-#{page_number}").click
    page_number + 1
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
    byebug
    raise $1
  end

  def sign_in
    if username
      fill_in("Email or mobile phone number", with: username)
    end

    if password
      fill_in("Password", with: password)
    end

    if username && password
      find("#signInSubmit").click
    else
      byebug
    end
  end

  def already_downloaded?(book_title)
    book_title = book_title.delete("?")
    downloaded_books = Dir[File.join(download_path, "*")].map do |book|
      book.gsub("#{download_path}/", "").gsub(".azw3", "").gsub(".azw", "").gsub(".tpz", "").delete("_")
    end

    return true if downloaded_books.include?(book_title)

    return true if !downloaded_books.select { |b| b.gsub(/ \(.*\)/, "").include?(book_title.gsub(/ \(.*\)/, "")) }.empty?

    return true if !downloaded_books.select { |b| b.include?(book_title.split(":").first) }.empty?

    false
  end
end

Capybara.register_driver :custom_download_path do |app|
  profile = Selenium::WebDriver::Firefox::Profile.new
  profile["browser.download.dir"] = options[:download_path]
  profile["browser.download.folderList"] = 2

  firefox_options = Selenium::WebDriver::Firefox::Options.new(profile:)

  Capybara::Selenium::Driver.new(app, browser: :firefox, options: firefox_options)
end

Capybara.current_driver = :custom_download_path
Capybara.app_host = "https://www.amazon.com"

KindleDownloader.new(**options).download_ebooks
