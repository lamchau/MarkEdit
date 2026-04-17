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

# Remove build artifacts
clean:
    rm -rf build
