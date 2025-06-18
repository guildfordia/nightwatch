#!/bin/bash

# Environment preparation script for Nightwatch project
# Usage: ./prepare-env.sh

set -e

ENV_FILE=".env"
ENV_EXAMPLE_FILE=".env.example"

echo "[+] Preparing environment..."

if [ ! -f "$ENV_FILE" ]; then
    if [ -f "$ENV_EXAMPLE_FILE" ]; then
        echo "[+] Creating $ENV_FILE from $ENV_EXAMPLE_FILE..."
        cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
        echo "[+] Please edit $ENV_FILE with your specific configuration."
    else
        echo "[!] $ENV_EXAMPLE_FILE not found. Cannot create $ENV_FILE."
        exit 1
    fi
else
    echo "[+] $ENV_FILE already exists."
fi

echo "[+] Environment preparation completed!" 