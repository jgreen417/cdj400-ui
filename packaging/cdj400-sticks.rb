cask "cdj400-sticks" do
  version "0.1.0"
  sha256 "997de226d5cc9a6aa39789c24246dd83a91a37b2a44cc9a239a3b0f93273bd0a"

  url "https://github.com/jgreen417/cdj400-ui/releases/download/v#{version}/CDJ-400-Sticks-#{version}.zip"
  name "CDJ-400 Sticks"
  desc "Manage Rekordbox USB sticks for Pioneer CDJ-400 decks"
  homepage "https://github.com/jgreen417/cdj400-ui"

  depends_on macos: :tahoe

  app "CDJ-400 Sticks.app"

  zap trash: [
    "~/Library/Application Support/CDJ400UI",
    "~/Library/Preferences/io.github.jgreen417.cdj400sticks.plist",
  ]

  caveats <<~EOS
    CDJ-400 Sticks isn't notarized by Apple, so macOS blocks the first launch.
    Open it once, then allow it in System Settings → Privacy & Security → Open Anyway.

    Exporting from your Rekordbox library needs pyrekordbox:
      python3 -m venv ~/venvs/rekordbox
      ~/venvs/rekordbox/bin/pip install pyrekordbox
  EOS
end
