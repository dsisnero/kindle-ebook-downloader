# Kindle eBook Download Automation Tool

A Ruby-based solution for securely downloading purchased Kindle eBooks from Amazon's content console.

![Workflow Diagram](https://via.placeholder.com/800x400.png?text=Download+Workflow)

## ✨ Features

- **Multi-threaded downloads** (3-10 concurrent sessions)
- **Smart deduplication** using SHA-256 content hashing
- **Headless browser support** with Firefox/geckodriver
- **Automatic authentication** with TOTP/MFA support
- **Resilient retry logic** for Amazon's anti-bot measures
- **Comprehensive logging** with thread-safe operations

## ⚙️ Installation

```bash
# Install system dependencies
brew install firefox geckodriver  # macOS
sudo apt-get install firefox-geckodriver  # Ubuntu

# Clone repository
git clone https://github.com/yourusername/kindle-downloader.git
cd kindle-downloader

# Install Ruby dependencies
bundle install

# Configure environment
cp .env.example .env
```

## 🔑 Configuration

Edit `.env` file:
```ini
AMAZON_USERNAME="your@email.com"
AMAZON_PASSWORD="your_password"
AMAZON_DEVICE="Your Kindle Name"  # Exact device name from Amazon
AMAZON_TOTP_SECRET="BASE32SECRET"  # For MFA-enabled accounts
DOWNLOAD_PATH="ebooks"  # Default download directory
```

## 🚀 Usage

```bash
# Basic download with 5 concurrent threads
ruby main.rb -c 5

# Force redownload all books (ignore existing)
ruby main.rb --disable-idempotency

# Debug mode with visible browser
ruby main.rb --headless=false --debug
```

### Full Options List:
```text
Options:
  -u, --username=USERNAME    Amazon login email
  -p, --password=PASSWORD    Amazon password
  -d, --device=DEVICE       Your Kindle device name
  --path=DOWNLOAD_PATH      Custom download directory
  --disable-idempotency     Force redownload existing books
  -c, --concurrency=NUM     Concurrent downloads (1-10)
  --headless                Run in background (default: true)
  --debug                   Enable debug mode
  -h, --help                Show help message
```

## 🧹 Maintenance

**Rebuild Download Index** (After manual file operations):
```bash
ruby -e "index_file=File.join('ebooks','.download_index'); \
FileUtils.rm_f(index_file); \
Dir.glob('ebooks/*').each { |f| next if File.basename(f).start_with?('.'); \
clean_title=File.basename(f).gsub(/_.{13}$/, ''); \
File.open(index_file,'a') { |io| io.puts \"#{clean_title}::#{File.mtime(f).iso8601}\" } }"
```

## 📂 File Structure
```bash
.
├── ebooks/
│   ├── clean_title_<hash13>.<ext>  # Downloaded eBooks
│   ├── .download_index            # Download history
│   └── kindle_downloader.log      # Operation logs
├── main.rb                        # Core application
├── .env                           # Configuration
└── README.md                      # This document
```

## 🛠️ Troubleshooting

**Common Issues**:

1. **Authentication Failures**
   ```bash
   # Verify TOTP setup
   ruby -r 'rotp' -e "puts ROTP::TOTP.new(ENV['AMAZON_TOTP_SECRET']).now"
   ```

2. **Popup Handling Errors**
   ```bash
   # Increase notification timeout
   sed -i '' 's/wait_until(15)/wait_until(30)/' main.rb
   ```

3. **Partial Downloads**
   ```bash
   # Clean incomplete files
   find ebooks/ -size -100k -name '*.*' -delete
   ```

**View Live Logs**:
```bash
tail -f ebooks/kindle_downloader.log
```

---

📘 **Note**: Amazon may throttle excessive concurrent requests. If experiencing timeouts:
1. Reduce concurrency (`-c 3`)
2. Add random delays in `process_page_content`
3. Rotate user agents if needed
