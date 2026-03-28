#!/usr/bin/env bash
set -euo pipefail

case "${1:-help}" in
  check|build)
    echo "==> Building Docker image..."
    docker build -t agentic-base-image:local .
    echo "==> Build succeeded."
    ;;
  help|*)
    echo "Usage: ./do <command>"
    echo ""
    echo "Commands:"
    echo "  check   Build the Docker image locally"
    echo "  build   Alias for check"
    ;;
esac
