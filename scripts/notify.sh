#!/usr/bin/env bash
# notify.sh - Send learning loop notifications via wake-gateway
# Usage: ./scripts/notify.sh <event-type> [--key value ...]
# Events: variant-created, variant-promoted, variant-discarded, score-regression, weekly-report
# Env: WAKE_GATEWAY (path to wake-gateway.sh), NOTIFY_ENABLED (true/false)
set -euo pipefail

WAKE_GATEWAY="${WAKE_GATEWAY:-${WORKSPACE_DIR:-$HOME/.openclaw/workspace}/scripts/wake-gateway.sh}"
NOTIFY_ENABLED="${NOTIFY_ENABLED:-true}"

usage() {
  echo "Usage: $0 <event-type> [options]"
  echo "Events:"
  echo "  variant-created   --template T --variant V --trigger R --pass-rate N"
  echo "  variant-promoted  --variant V --original O --variant-score N --original-score N"
  echo "  variant-discarded --variant V --original O --variant-score N --original-score N"
  echo "  score-regression  --template T --old-score N --new-score N"
  echo "  weekly-report     --summary TEXT"
  echo "Options:"
  echo "  --dry-run  Show message without sending"
  echo "  --help     Show this message"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

EVENT="$1"
shift

if [[ "$EVENT" == "--help" || "$EVENT" == "-h" ]]; then
  usage
  exit 0
fi

# Parse args
DRY_RUN=false
TEMPLATE="" VARIANT="" TRIGGER="" PASS_RATE="" ORIGINAL=""
VARIANT_SCORE="" ORIGINAL_SCORE="" OLD_SCORE="" NEW_SCORE="" SUMMARY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --trigger) TRIGGER="$2"; shift 2 ;;
    --pass-rate) PASS_RATE="$2"; shift 2 ;;
    --original) ORIGINAL="$2"; shift 2 ;;
    --variant-score) VARIANT_SCORE="$2"; shift 2 ;;
    --original-score) ORIGINAL_SCORE="$2"; shift 2 ;;
    --old-score) OLD_SCORE="$2"; shift 2 ;;
    --new-score) NEW_SCORE="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) shift ;;
  esac
done

# Build message based on event type
case "$EVENT" in
  variant-created)
    MSG="Learning Loop: Created variant $VARIANT for $TEMPLATE (trigger: $TRIGGER, pass_rate: $PASS_RATE)"
    ;;
  variant-promoted)
    MSG="Learning Loop: Promoted $VARIANT over $ORIGINAL (scores: $VARIANT_SCORE vs $ORIGINAL_SCORE)"
    ;;
  variant-discarded)
    MSG="Learning Loop: Discarded $VARIANT — did not beat $ORIGINAL (scores: $VARIANT_SCORE vs $ORIGINAL_SCORE)"
    ;;
  score-regression)
    MSG="Learning Loop: Score regression for $TEMPLATE ($OLD_SCORE → $NEW_SCORE)"
    ;;
  weekly-report)
    MSG="Learning Loop: $SUMMARY"
    ;;
  *)
    echo "Unknown event type: $EVENT" >&2
    usage >&2
    exit 1
    ;;
esac

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] $MSG"
  exit 0
fi

if [[ "$NOTIFY_ENABLED" != "true" ]]; then
  exit 0
fi

# Send via wake-gateway (don't crash on failure)
if ! "$WAKE_GATEWAY" "$MSG" 2>/dev/null; then # REASON: Gateway stderr is noisy in cron context; failure is handled with warning below.
  echo "Warning: notification failed (gateway unreachable), message was: $MSG" >&2
fi
