#!/bin/bash
# dashboard.sh — 生成 Agent Teams 实时仪表盘 HTML
#
# 用法: ./dashboard.sh [project_dir]
# 输出: $PROJECT_DIR/.claude/state/dashboard.html

set -uo pipefail

PROJECT_DIR="${1:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
STATE_DIR="$PROJECT_DIR/.claude/state"
OUTPUT="$STATE_DIR/dashboard.html"
USAGE_FILE="$STATE_DIR/usage.jsonl"

mkdir -p "$STATE_DIR"

# HTML-encode a string for safe injection into HTML context
html_escape() { printf '%s' "$1" | sed "s/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/\"/\&quot;/g; s/'/\&#39;/g"; }

# 收集 Teammate 状态
TEAMMATES_JSON="[]"
if command -v jq &>/dev/null; then
    if compgen -G "$STATE_DIR/status-*.json" > /dev/null 2>&1; then
        TEAMMATES_JSON=$(jq -s '.' "$STATE_DIR"/status-*.json 2>/dev/null || echo "[]")
    else
        TEAMMATES_JSON="[]"
    fi
fi

# 收集用量统计
TOTAL_EVENTS=0 PASS=0 FAIL=0 TOTAL_DURATION=0
if [ -f "$USAGE_FILE" ] && command -v jq &>/dev/null; then
    TOTAL_EVENTS=$(wc -l < "$USAGE_FILE")
    PASS=$(jq -r 'select(.action=="pass") | .action' "$USAGE_FILE" 2>/dev/null | wc -l || echo 0)
    FAIL=$(jq -r 'select(.action=="fail") | .action' "$USAGE_FILE" 2>/dev/null | wc -l || echo 0)
    TOTAL_DURATION=$(jq -r '.duration_s // 0' "$USAGE_FILE" 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)
fi
TOTAL_DURATION="${TOTAL_DURATION:-0}"

cat > "$OUTPUT" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Agent Teams Dashboard</title>
<meta http-equiv="refresh" content="5">
<style>
:root { --bg:#0a0a10; --s1:#12121e; --s2:#1a1a2e; --bd:#252540; --t:#b0b0cc; --td:#6060a0; --tb:#e0e0f0; --g:#00e87b; --b:#3b82f6; --r:#ff4466; --y:#ffb224; --m:JetBrains Mono,monospace; }
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--t);padding:20px;min-height:100vh}
h1{font-size:18px;color:var(--tb);margin-bottom:16px;font-weight:700;letter-spacing:1px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:20px}
.stat{background:var(--s1);border:1px solid var(--bd);border-radius:8px;padding:16px}
.stat-val{font-family:var(--m);font-size:28px;font-weight:700;color:var(--tb)}
.stat-val.g{color:var(--g)} .stat-val.r{color:var(--r)} .stat-val.b{color:var(--b)} .stat-val.y{color:var(--y)}
.stat-label{font-size:11px;color:var(--td);text-transform:uppercase;letter-spacing:1px;margin-top:4px}
.card{background:var(--s1);border:1px solid var(--bd);border-radius:8px;margin-bottom:16px;overflow:hidden}
.card-h{padding:12px 16px;border-bottom:1px solid var(--bd);font-size:12px;font-weight:700;color:var(--td);text-transform:uppercase;letter-spacing:1px}
.teammate{display:flex;align-items:center;gap:12px;padding:12px 16px;border-bottom:1px solid var(--bd)}
.teammate:last-child{border-bottom:none}
.tm-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.tm-dot.working{background:var(--g);animation:pulse 1.5s infinite}
.tm-dot.idle{background:var(--td)}
.tm-dot.fail{background:var(--r)}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
.tm-name{font-weight:700;color:var(--tb);font-size:13px;min-width:120px}
.tm-role{font-family:var(--m);font-size:10px;color:var(--b);background:rgba(59,130,246,.15);padding:2px 8px;border-radius:4px}
.tm-action{font-size:12px;color:var(--t);flex:1}
.tm-ts{font-family:var(--m);font-size:10px;color:var(--td)}
.evt{padding:6px 16px;font-family:var(--m);font-size:11px;color:var(--td);border-bottom:1px solid rgba(255,255,255,.03)}
.evt .pass{color:var(--g)} .evt .fail{color:var(--r)} .evt .skip{color:var(--y)}
.footer{text-align:center;font-size:10px;color:var(--td);margin-top:20px}
</style>
</head>
<body>
<h1>AGENT TEAMS DASHBOARD</h1>
HTMLHEAD

# Stats
cat >> "$OUTPUT" << EOF
<div class="grid">
<div class="stat"><div class="stat-val b">$TOTAL_EVENTS</div><div class="stat-label">Total Events</div></div>
<div class="stat"><div class="stat-val g">$PASS</div><div class="stat-label">Tests Passed</div></div>
<div class="stat"><div class="stat-val r">$FAIL</div><div class="stat-label">Tests Failed</div></div>
<div class="stat"><div class="stat-val y">${TOTAL_DURATION}s</div><div class="stat-label">Total Duration</div></div>
</div>
EOF

# Teammates
echo '<div class="card"><div class="card-h">Teammates</div>' >> "$OUTPUT"
if command -v jq &>/dev/null; then
    echo "$TEAMMATES_JSON" | jq -r '.[] | "<div class=\"teammate\"><div class=\"tm-dot \(.status // "idle" | @html)\"></div><div class=\"tm-name\">\(.teammate // "?" | @html)</div><div class=\"tm-role\">\(.role // .action // "?" | @html)</div><div class=\"tm-action\">\(.detail // .task // .action // "" | @html)</div><div class=\"tm-ts\">\(.ts // "" | @html)</div></div>"' 2>/dev/null >> "$OUTPUT"
fi
NO_STATUS=$(find "$STATE_DIR" -maxdepth 1 -name 'status-*.json' 2>/dev/null | wc -l)
if [ "$NO_STATUS" -eq 0 ]; then
    echo '<div class="teammate"><div class="tm-dot idle"></div><div class="tm-name">Waiting...</div><div class="tm-action">No teammates active yet. Run /claude-autopilot to start.</div></div>' >> "$OUTPUT"
fi
echo '</div>' >> "$OUTPUT"

# Recent events
echo '<div class="card"><div class="card-h">Recent Events (last 20)</div>' >> "$OUTPUT"
if [ -f "$USAGE_FILE" ] && command -v jq &>/dev/null; then
    tail -20 "$USAGE_FILE" | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) print lines[i]}' | while IFS= read -r line; do
        TS=$(html_escape "$(echo "$line" | jq -r '.ts // ""' 2>/dev/null)")
        HOOK=$(html_escape "$(echo "$line" | jq -r '.hook // ""' 2>/dev/null)")
        TM=$(html_escape "$(echo "$line" | jq -r '.teammate // ""' 2>/dev/null)")
        ACTION=$(echo "$line" | jq -r '.action // .outcome // ""' 2>/dev/null)
        DUR=$(html_escape "$(echo "$line" | jq -r '.duration_s // ""' 2>/dev/null)")
        CLS="skip"
        [ "$ACTION" = "pass" ] && CLS="pass"
        if [ "$ACTION" = "fail" ] || [ "$ACTION" = "test_fail" ] || [ "$ACTION" = "lint_fail" ]; then CLS="fail"; fi
        ACTION_ESC=$(html_escape "$ACTION")
        CLS_ESC=$(html_escape "$CLS")
        echo "<div class=\"evt\"><span class=\"${CLS_ESC}\">${TS}</span>  ${TM}  ${HOOK}  ${ACTION_ESC}  ${DUR}s</div>" >> "$OUTPUT"
    done
else
    echo '<div class="evt">No events yet</div>' >> "$OUTPUT"
fi
echo '</div>' >> "$OUTPUT"

# Footer
cat >> "$OUTPUT" << 'HTMLFOOT'
<div class="footer">Auto-refreshes every 5 seconds. Generated by /claude-autopilot skill.</div>
</body>
</html>
HTMLFOOT

echo "Dashboard: $OUTPUT"
echo "Open in browser: file://$OUTPUT"
