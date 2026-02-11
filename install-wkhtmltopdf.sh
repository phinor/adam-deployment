#!/bin/bash

# ==============================================================================
# Universal wkhtmltopdf Installer for Ubuntu with Xvfb Wrapper
#
# Description:
# This script automates the installation of wkhtmltopdf on various Ubuntu
# distributions. It detects the OS version, downloads the specific required
# .deb package, installs dependencies, and creates a wrapper script to run
# wkhtmltopdf within a virtual framebuffer (Xvfb). This is essential for
# running it on headless servers.
#
# Supported Distributions:
# - Ubuntu 24.04 (Noble Numbat) - Uses the Jammy package as a workaround
# - Ubuntu 22.04 (Jammy Jellyfish)
# - Ubuntu 20.04 (Focal Fossa)
# - Ubuntu 18.04 (Bionic Beaver)
#
# Usage:
# 1. Save the script (e.g., install.sh)
# 2. Make it executable: chmod +x install.sh
# 3. Run with root privileges: sudo ./install.sh
#
# ==============================================================================

# --- Script Start ---

# Exit immediately if a command exits with a non-zero status.
set -e

# --- 1. Check for Root Privileges ---
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use 'sudo'." >&2
  exit 1
fi

# --- 2. Detect Distribution and Set Package Info ---
DISTRO=$(lsb_release -cs)
ARCH=$(uname -m)
PACKAGE_NAME=""
DOWNLOAD_URL=""

# Ensure architecture is amd64, as all provided links are for it.
if [ "$ARCH" != "x86_64" ]; then
  echo "Error: This script is designed for amd64 (x86_64) architecture only." >&2
  exit 1
fi
ARCH="amd64" # Use the package naming convention

echo "Detected Ubuntu Distribution: $DISTRO"

case "$DISTRO" in
  "noble")
    echo "Ubuntu 24.04 (Noble) detected. Using Jammy package as a workaround."
    PACKAGE_NAME="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    DOWNLOAD_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${PACKAGE_NAME}"
    ;;
  "jammy")
    echo "Ubuntu 22.04 (Jammy) detected."
    PACKAGE_NAME="wkhtmltox_0.12.6.1-2.jammy_amd64.deb"
    DOWNLOAD_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/${PACKAGE_NAME}"
    ;;
  "focal")
    echo "Ubuntu 20.04 (Focal) detected."
    PACKAGE_NAME="wkhtmltox_0.12.6-1.focal_amd64.deb"
    DOWNLOAD_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-1/${PACKAGE_NAME}"
    ;;
  "bionic")
    echo "Ubuntu 18.04 (Bionic) detected."
    PACKAGE_NAME="wkhtmltox_0.12.5-1.bionic_amd64.deb"
    DOWNLOAD_URL="https://downloads.wkhtmltopdf.org/0.12/0.12.5/${PACKAGE_NAME}"
    ;;
  *)
    echo "Error: Unsupported Ubuntu distribution '$DISTRO'." >&2
    exit 1
    ;;
esac

# --- 3. Install Dependencies ---
echo "Updating package lists..."
apt-get update

echo "Installing dependencies..."
# Install a comprehensive list of dependencies needed across versions.
# `apt-get` will gracefully skip any that are not needed or already present.
apt-get install -y --no-install-recommends \
  xvfb \
  libfontconfig1 \
  libxrender1 \
  xfonts-base \
  xfonts-75dpi \
  wget \
  fontconfig \
  xfonts-utils \
  libfontenc1 \
  x11-common \
  xfonts-encodings

# --- 4. Download and Install wkhtmltopdf ---
TEMP_DIR=$(mktemp -d)
echo "Created temporary directory at $TEMP_DIR"

echo "Downloading $PACKAGE_NAME..."
wget -nv -O "$TEMP_DIR/$PACKAGE_NAME" "$DOWNLOAD_URL"

echo "Installing wkhtmltopdf package..."
# Using `apt install` on the local .deb file is preferred as it handles
# any remaining dependencies automatically.
apt install -y "$TEMP_DIR/$PACKAGE_NAME"

# --- 5. Create the Xvfb Wrapper Script ---
WRAPPER_PATH="/usr/local/bin/wkhtmltopdf.sh"
echo "Creating Xvfb wrapper script at $WRAPPER_PATH..."

# This command creates the script that executes wkhtmltopdf inside a virtual screen.
# The "$@" passes all command-line arguments from the script to the binary.
echo 'exec xvfb-run -a -s "-screen 0 1024x768x24" /usr/local/bin/wkhtmltopdf "$@"' > "$WRAPPER_PATH"

# Make the wrapper script executable for all users.
chmod a+x "$WRAPPER_PATH"

echo "Wrapper script created successfully."

# --- 6. Clean Up ---
echo "Cleaning up temporary files..."
rm -rf "$TEMP_DIR"

# --- 7. Verification and Test ---
run_test() {
  echo "--------------------------------------------------"
  echo "Running a quick test to verify installation..."
  TEST_HTML="/tmp/wkhtmltopdf_test.html"
  TEST_PDF="/var/www/adam/wkhtmltopdf_test_output.pdf"

  # Create a simple test HTML file
  echo "<html><body><h1 style='color: green;'>Success!</h1><div style='width:100px; height:100px; background-color:black; border: 3px solid red;'></div></body></html>" > "$TEST_HTML"

  echo "Generating PDF from test file..."
  # Use the wrapper script for the test
  if "$WRAPPER_PATH" "$TEST_HTML" "$TEST_PDF"; then
    if [ -f "$TEST_PDF" ]; then
      echo "âœ… Test PDF successfully created at $TEST_PDF"
    else
      echo "âŒ Test Failed: The command ran but did not create a PDF."
    fi
  else
    echo "âŒ Test Failed: The wkhtmltopdf.sh command failed to execute."
  fi

  # Clean up test files
  rm -f "$TEST_HTML" "$TEST_PDF"
  echo "Test complete."
  echo "--------------------------------------------------"
}

run_test

# --- Final Message ---
echo "=================================================="
echo "âœ… Installation Complete!"
echo "To use, run the wrapper script:"
echo "   wkhtmltopdf.sh [OPTIONS]... <input.html> <output.pdf>"
echo "=================================================="

exit 0
