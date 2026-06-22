cask "sidecar-travel" do
  version "1.0.0"
  sha256 "ff4f7ad9860db3f7ea4f28abce2a7a61ba4edfed23c50095619a7dda5bfac2af"

  url "https://github.com/zonya/sidecar-travel/releases/download/v#{version}/Sidecar-Travel.zip"
  name "Sidecar Travel"
  desc "Auto-connect an iPad as a headless Mac's display via Sidecar"
  homepage "https://github.com/zonya/sidecar-travel"

  depends_on macos: ">= :ventura"

  app "Sidecar Travel.app"

  zap trash: [
    "~/Library/Application Support/SidecarTravel",
    "~/Library/LaunchAgents/io.github.sidecartravel.plug.plist",
  ]

  caveats <<~EOS
    Sidecar Travel uses the private SidecarCore framework and is ad-hoc signed.
    On first launch, right-click the app and choose Open to bypass Gatekeeper.
  EOS
end
