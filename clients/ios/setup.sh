#!/bin/bash
# NanoClaw iOS — Project Setup Script
# Run this on your Mac after unzipping the archive.
set -e

echo "🦀 NanoClaw iOS Setup"
echo "====================="

# 1. Check Xcode
if ! xcode-select -p &>/dev/null; then
  echo "❌ Xcode not found. Install from App Store."
  exit 1
fi
echo "✅ Xcode found: $(xcode-select -p)"

# 2. Install XcodeGen via Homebrew
if ! command -v xcodegen &>/dev/null; then
  echo "📦 Installing XcodeGen..."
  if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew not found. Install from https://brew.sh"
    exit 1
  fi
  brew install xcodegen
fi
echo "✅ XcodeGen: $(xcodegen --version)"

# 3. Generate .xcodeproj
echo "⚙️  Generating Xcode project..."
xcodegen generate

# 4. Open in Xcode
echo ""
echo "✅ Done! Opening in Xcode..."
echo ""
echo "📋 Next steps:"
echo "  1. In Xcode → Signing & Capabilities → set your Team"
echo "  2. Connect your iPhone"
echo "  3. Select your iPhone as build target"
echo "  4. Press ▶ Run (Cmd+R)"
echo ""
echo "🔑 First launch: go to Settings tab and enter:"
echo "   • Host: nanoclaw (or your Tailscale IP)"
echo "   • Port: 8080"
echo "   • Token: (your IOS_CHANNEL_SECRET)"
echo ""

open NanoClaw.xcodeproj
