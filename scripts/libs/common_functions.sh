#!/bin/bash

# Define ANSI color ~

# Define ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print info messages (green)
echo_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

# Function to print error messages (red)
echo_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Function to print warning messages (yellow)
echo_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to print debug messages (blue)
echo_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to log messages to a file
log_message() {
    local message="$1"
    local log_file="${2:-/tmp/script.log}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$log_file"
}

# Function to retry a command up to n times
retry_command() {
    local max_attempts="$1"
    shift
    local attempt=1
    while [ $attempt -le "$max_attempts" ]; do
        echo_debug "Attempt $attempt of $max_attempts"
        if "$@"; then
            echo_info "Command succeeded"
            return 0
        else
            echo_warning "Command failed, retrying..."
            sleep 1
        fi
        ((attempt++))
    done
    echo_error "Command failed after $max_attempts attempts"
    return 1
}