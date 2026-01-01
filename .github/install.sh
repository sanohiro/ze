#!/bin/sh
# ze apt repository installer
# Usage: curl -fsSL https://sanohiro.github.io/ze/install.sh | sudo sh

set -e

# Add GPG key
curl -fsSL https://sanohiro.github.io/ze/ze.gpg | gpg --dearmor -o /usr/share/keyrings/ze.gpg

# Add repository
echo "deb [signed-by=/usr/share/keyrings/ze.gpg] https://sanohiro.github.io/ze stable main" > /etc/apt/sources.list.d/ze.list

# Update package list
apt update

echo "Done! Run 'apt install ze' to install."
