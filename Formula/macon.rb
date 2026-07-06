class Macon < Formula
  desc "Local CI runner — runs macon.yml pipelines on your Mac"
  homepage "https://github.com/alimusawa313/macon"
  license "MIT"

  # Stable release: after you tag & push, set these (see README "Publishing").
  #   url "https://github.com/alimusawa313/macon/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "PASTE_SHASUM_HERE"
  #   version "0.1.0"

  # Until then (or for bleeding edge): `brew install --HEAD macon`
  head "https://github.com/alimusawa313/macon.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    # Monorepo: the Swift package lives in the MaconKit/ subdirectory.
    system "swift", "build", "--disable-sandbox", "-c", "release", "--package-path", "MaconKit"
    bin.install "MaconKit/.build/release/macon"
  end

  test do
    assert_match "macon", shell_output("#{bin}/macon version")
  end
end
