default:
    @just --list

# Build MarkEdit.app for personal use (ad-hoc signed, no distribution)
build:
    xcodebuild \
        -project MarkEdit.xcodeproj \
        -scheme MarkEditMac \
        -configuration Release \
        -derivedDataPath build \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO

# Build and install to /Applications
install: build
    cp -R build/Build/Products/Release/MarkEdit.app /Applications/MarkEdit.app

# Install CLI tools (markedit + markedit-plugins) to ~/.local/bin
install-cli:
    bin/install-cli.sh

# Upgrade CLI tools without confirmation prompts
upgrade-cli:
    bin/install-cli.sh --upgrade

# Install Hammerspoon quick-switch module (requires Hammerspoon)
install-switcher:
    @if [ -d "$$HOME/.hammerspoon" ]; then \
        ln -sf "$(pwd)/bin/markedit-switcher.lua" "$$HOME/.hammerspoon/markedit-switcher.lua"; \
        grep -q 'require("markedit-switcher")' "$$HOME/.hammerspoon/init.lua" 2>/dev/null || \
            echo 'require("markedit-switcher")' >> "$$HOME/.hammerspoon/init.lua"; \
        echo "installed markedit-switcher.lua"; \
    else \
        echo "hammerspoon not found, skipping"; \
    fi

# Remove build artifacts
clean:
    rm -rf build
