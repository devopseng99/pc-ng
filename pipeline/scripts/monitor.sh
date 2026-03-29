#!/usr/bin/env bash
# Quick monitoring dashboard for the autopilot pipeline

echo "=== Autopilot Pipeline Monitor ==="
echo ""

# Status
if [[ -f /tmp/pc-autopilot/.pipeline-status ]]; then
  echo "Pipeline Status:"
  python3 -c "
import json
with open('/tmp/pc-autopilot/.pipeline-status') as f: s = json.load(f)
print(f'  Completed: {s[\"completed\"]}/{s[\"total\"]}')
print(f'  Current:   {s[\"current\"]}')
print(f'  Updated:   {s[\"updated\"]}')
"
else
  echo "  No status file yet"
fi

echo ""

# Registry
echo "Registry:"
python3 -c "
import json
with open('/tmp/pc-autopilot/registry/deployed.json') as f: d = json.load(f)
apps = d['apps']
deployed = [a for a in apps if a['status'] == 'deployed']
failed = [a for a in apps if 'failed' in a.get('status','')]
print(f'  Total:    {len(apps)}')
print(f'  Deployed: {len(deployed)}')
print(f'  Failed:   {len(failed)}')
if failed:
    print('  Failed apps:')
    for a in failed:
        print(f'    [{a[\"id\"]}] {a[\"name\"]} — {a[\"status\"]}')
"

echo ""

# Disk
echo "Disk (/tmp):"
df -h /tmp | tail -1 | awk '{print "  Used: " $3 "  Free: " $4 "  (" $5 ")"}'

echo ""

# Active processes
echo "Active builds:"
count=$(pgrep -f "claude.*dangerously" 2>/dev/null | wc -l)
echo "  $count claude process(es) running"

echo ""

# Last 5 log lines
LATEST_LOG=$(ls -t /tmp/pc-autopilot/logs/full-run-*.log 2>/dev/null | head -1)
if [[ -n "$LATEST_LOG" ]]; then
  echo "Last 5 pipeline log lines:"
  tail -5 "$LATEST_LOG" | sed 's/^/  /'
fi
