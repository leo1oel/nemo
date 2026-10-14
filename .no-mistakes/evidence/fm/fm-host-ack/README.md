# fm-host-ack: supervision-host engine leaves granted wake rows unacked (TZ identity mismatch)

Machine: system zone Asia/Shanghai (CST); login shell exports TZ=America/New_York.
Claude Code's Bash tool takes TZ from the login-shell snapshot, so the real engine's
drain runs in EDT while a host started without TZ runs in CST.

| file | what it shows |
|---|---|
| live-claude-engine-host-tz-unset-before-fix.log | REAL Claude engine, pre-fix code (8c9c67d): `failed rc=0 reports=1 unacked=1 2`, rows left queued — the production signature |
| live-claude-engine-host-tz-unset-after-fix.log | same live setup, fixed code (b416d88): both wakes `handled`, outcome stored, queue empty, main never woken |
| live-claude-engine-same-zone-control-{before,after}-fix.log | control: host TZ=America/New_York matches the engine's Bash TZ; both pass (bug needs a zone mismatch) |
| before-fix-host-tz-test.log / after-fix-host-tz-test.log | stub-engine host test `test_engine_in_another_time_zone_handles_its_granted_rows` fails pre-fix with the same signature, passes after; neighbours (handled-on-engine, report-without-ack→main) pass |
| pid-identity-across-tz.txt | fm_pid_identity on one live pid under 5 zones: fixed output constant (UTC), pre-fix output shifts per zone |
| extension-binding-tz-shanghai.log | fm-extension.mjs regression suite under TZ=Asia/Shanghai with the fix: passes |
