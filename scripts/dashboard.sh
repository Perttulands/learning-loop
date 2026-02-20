#!/usr/bin/env bash
# dashboard.sh - Generate a static HTML dashboard for learning-loop state
# Usage: SCORES_DIR=path REPORTS_DIR=path ./scripts/dashboard.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SCORES_DIR="${SCORES_DIR:-$PROJECT_DIR/state/scores}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/state/reports}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0"
  echo "Generate state/reports/dashboard.html from current scores and strategy data."
  echo "Env vars: SCORES_DIR, REPORTS_DIR"
  exit 0
fi

mkdir -p "$REPORTS_DIR"

TEMPLATE_SCORES="$SCORES_DIR/template-scores.json"
AGENT_SCORES="$SCORES_DIR/agent-scores.json"
AB_TESTS="$SCORES_DIR/ab-tests.json"

if [[ -f "$TEMPLATE_SCORES" ]]; then
  template_data="$(cat "$TEMPLATE_SCORES")"
else
  template_data='{"templates":[]}'
fi

if [[ -f "$AGENT_SCORES" ]]; then
  agent_data="$(cat "$AGENT_SCORES")"
else
  agent_data='{"agents":[]}'
fi

if [[ -f "$AB_TESTS" ]]; then
  ab_data="$(cat "$AB_TESTS")"
else
  ab_data='{"tests":[]}'
fi

latest_strategy_file="$(ls -1 "$REPORTS_DIR"/strategy-*.json 2>/dev/null | tail -n 1 || true)" # REASON: Dashboard generation must continue when no strategy report exists yet.
if [[ -n "$latest_strategy_file" && -f "$latest_strategy_file" ]]; then
  strategy_data="$(cat "$latest_strategy_file")"
else
  strategy_data='{"summary":"No weekly strategy report available yet.","recommendations":[]}'
fi

total_runs="$(echo "$template_data" | jq '[.templates[].total_runs] | add // 0')"
pass_rate="$(echo "$template_data" | jq '[.templates[] | (.full_pass_rate * .scoreable_runs)] | add // 0')"
scoreable_runs="$(echo "$template_data" | jq '[.templates[].scoreable_runs] | add // 0')"
overall_pass_rate="0"
if [[ "$scoreable_runs" -gt 0 ]]; then
  overall_pass_rate="$(echo "scale=4; $pass_rate / $scoreable_runs" | bc -l)"
fi
active_ab="$(echo "$ab_data" | jq '[.tests[] | select(.status == "active")] | length')"

summary_text="$(echo "$strategy_data" | jq -r '.summary // "No summary available."')"

template_rows="$(echo "$template_data" | jq -r '
  [.templates[] |
    "<tr><td>\(.template)</td><td>\(.total_runs)</td><td>\((.full_pass_rate * 100 | round))%</td><td>\(.score)</td><td>\(.trend)</td></tr>"
  ] | join("\n")')"
if [[ -z "$template_rows" ]]; then
  template_rows='<tr><td colspan="5">No template scores yet.</td></tr>'
fi

agent_rows="$(echo "$agent_data" | jq -r '
  [.agents[] |
    "<tr><td>\(.agent)</td><td>\(.total_runs)</td><td>\((.pass_rate * 100 | round))%</td><td>\(.score)</td></tr>"
  ] | join("\n")')"
if [[ -z "$agent_rows" ]]; then
  agent_rows='<tr><td colspan="4">No agent scores yet.</td></tr>'
fi

ab_rows="$(echo "$ab_data" | jq -r '
  [.tests[] |
    "<tr><td>\(.original)</td><td>\(.variant)</td><td>\(.status)</td><td>\(.original_runs)/\(.target_runs)</td><td>\(.variant_runs)/\(.target_runs)</td></tr>"
  ] | join("\n")')"
if [[ -z "$ab_rows" ]]; then
  ab_rows='<tr><td colspan="5">No A/B tests yet.</td></tr>'
fi

recommendation_items="$(echo "$strategy_data" | jq -r '
  (.recommendations // []) |
  if length == 0 then "<li>No recommendations yet.</li>"
  else [.[] | "<li>" + . + "</li>"] | join("\n") end
')"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
output_file="$REPORTS_DIR/dashboard.html"

cat > "$output_file" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Learning Loop Dashboard</title>
  <style>
    :root {
      --bg-top: #f7f2e8;
      --bg-bottom: #dfe9f3;
      --ink: #13212b;
      --muted: #5c6b75;
      --accent: #0f766e;
      --accent-2: #b45309;
      --card: rgba(255, 255, 255, 0.78);
      --line: rgba(19, 33, 43, 0.12);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      font-family: "IBM Plex Sans", "Segoe UI", sans-serif;
      color: var(--ink);
      background:
        radial-gradient(1200px 600px at 5% -10%, rgba(15, 118, 110, 0.20), transparent),
        radial-gradient(1000px 600px at 110% -20%, rgba(180, 83, 9, 0.20), transparent),
        linear-gradient(180deg, var(--bg-top), var(--bg-bottom));
    }

    .wrap {
      max-width: 1100px;
      margin: 0 auto;
      padding: 24px 16px 32px;
    }

    .hero {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: baseline;
      justify-content: space-between;
      margin-bottom: 18px;
    }

    h1 {
      margin: 0;
      font-size: clamp(1.5rem, 3vw, 2.2rem);
      letter-spacing: 0.02em;
    }

    .timestamp {
      color: var(--muted);
      font-size: 0.95rem;
    }

    .stats {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
      gap: 12px;
      margin-bottom: 16px;
    }

    .stat {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 12px 14px;
      backdrop-filter: blur(2px);
    }

    .stat .k { color: var(--muted); font-size: 0.85rem; }
    .stat .v { font-weight: 700; font-size: 1.45rem; margin-top: 4px; }

    .grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 14px;
    }

    .card {
      background: var(--card);
      border: 1px solid var(--line);
      border-radius: 12px;
      padding: 14px;
      backdrop-filter: blur(2px);
    }

    .card h2 {
      margin: 0 0 10px;
      font-size: 1.05rem;
      color: var(--accent);
      letter-spacing: 0.01em;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.92rem;
    }

    th, td {
      text-align: left;
      padding: 8px 6px;
      border-bottom: 1px solid var(--line);
      vertical-align: top;
    }

    th { color: var(--muted); font-weight: 600; }

    .summary {
      margin: 0;
      line-height: 1.45;
    }

    ul {
      margin: 8px 0 0;
      padding-left: 20px;
    }

    @media (min-width: 900px) {
      .grid {
        grid-template-columns: 1fr 1fr;
      }
      .grid .wide {
        grid-column: span 2;
      }
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="hero">
      <h1>Learning Loop Dashboard</h1>
      <div class="timestamp">Generated: ${generated_at}</div>
    </div>

    <section class="stats">
      <article class="stat"><div class="k">Total Runs</div><div class="v">${total_runs}</div></article>
      <article class="stat"><div class="k">Overall Pass Rate</div><div class="v">$(echo "$overall_pass_rate * 100" | bc -l | awk '{printf "%.1f%%", $1}')</div></article>
      <article class="stat"><div class="k">Active A/B Tests</div><div class="v">${active_ab}</div></article>
      <article class="stat"><div class="k">Latest Strategy</div><div class="v" style="font-size:1.0rem;color:var(--accent-2)">${summary_text}</div></article>
    </section>

    <section class="grid">
      <article class="card">
        <h2>Template Scores</h2>
        <table>
          <thead><tr><th>Template</th><th>Runs</th><th>Pass</th><th>Score</th><th>Trend</th></tr></thead>
          <tbody>
            ${template_rows}
          </tbody>
        </table>
      </article>

      <article class="card">
        <h2>Agent Scores</h2>
        <table>
          <thead><tr><th>Agent</th><th>Runs</th><th>Pass</th><th>Score</th></tr></thead>
          <tbody>
            ${agent_rows}
          </tbody>
        </table>
      </article>

      <article class="card wide">
        <h2>Active and Historical A/B Tests</h2>
        <table>
          <thead><tr><th>Original</th><th>Variant</th><th>Status</th><th>Original Runs</th><th>Variant Runs</th></tr></thead>
          <tbody>
            ${ab_rows}
          </tbody>
        </table>
      </article>

      <article class="card wide">
        <h2>Weekly Recommendations</h2>
        <ul>
          ${recommendation_items}
        </ul>
      </article>
    </section>
  </div>
</body>
</html>
HTML

echo "Dashboard written to: $output_file"
