# Homebrew cask for Torie-chan. Published in the llmer/homebrew-tap repository; scripts/update-cask.sh
# rewrites version and sha256 for each release.
cask "torie-chan" do
  version "0.2.0"
  sha256 "ef9c6d533230598fd79e14dade07726517be03e29286d04beb665788bd2e3336"

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
