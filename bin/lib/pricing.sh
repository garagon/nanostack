#!/usr/bin/env bash
# pricing.sh — Shared pricing table for token cost calculation
# Source this file, then call: pricing <model>
# Returns: "input_price output_price" per 1M tokens

pricing() {
  case "$1" in
    opus-4|opus-4-6)     echo "15.0 75.0" ;;
    sonnet-4|sonnet-4-6) echo "3.0 15.0" ;;
    haiku-4-5)           echo "0.80 4.0" ;;
    gpt-4o)              echo "2.5 10.0" ;;
    gpt-4.1)             echo "2.0 8.0" ;;
    o3)                  echo "2.0 8.0" ;;
    *)                   echo "3.0 15.0" ;; # default to sonnet pricing
  esac
}
