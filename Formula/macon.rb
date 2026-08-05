class Macon < Formula
  desc "Local CI runner — runs macon.yml pipelines on your Mac"
  homepage "https://github.com/alimusawa313/MaconKit"
  license "MIT"

  # Reference copy. The formula people actually install is published to the tap
  # (alimusawa313/homebrew-macon) by the release workflow on every tag, which
  # fills in url + sha256 + version.
  head "https://github.com/alimusawa313/MaconKit.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/macon"
  end

  test do
    assert_match "macon", shell_output("#{bin}/macon version")
  end
end
