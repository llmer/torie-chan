# Homebrew cask for Torie-chan. Published in the llmer/homebrew-tap repository; scripts/update-cask.sh
# rewrites version and sha256 for each release.
cask "torie-chan" do
  version "0.1.3"
  sha256 "6fc42a48e19bc3f80fddc2cfe30429aee61af816165de37d13e9c97e206bfd82"

  url "https://github.com/llmer/torie-chan/releases/download/v#{version}/Torie-chan-#{version}.dmg"
  name "Torie-chan"
  desc "Kawaii guard that watches your laptop while you step away"
  homepage "https://github.com/llmer/torie-chan"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Torie-chan.app"

  uninstall launchctl: "com.mostperfectsip.toriechan.helper",
            quit:      "com.mostperfectsip.toriechan"

  zap trash: [
    "~/Library/Application Support/Torie-chan",
    "~/Library/Caches/com.mostperfectsip.toriechan",
    "~/Library/HTTPStorages/com.mostperfectsip.toriechan",
    "~/Library/Preferences/com.mostperfectsip.toriechan.plist",
  ]
end
