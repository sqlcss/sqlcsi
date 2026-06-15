# XEvent Login Timer Analysis — Key Knowledge

## Two Login XEvents

| Event | Source | Captures | Fires on |
|-------|--------|----------|----------|
| `connectivity_ring_buffer_recorded` | system_health (built-in) | Login timers + SNI errors + connection metadata | **Failed/abnormal close only** |
| `process_login_finish` | Custom XEvent session (must be created) | All above + fedauth + app_name + driver + is_success | **All logins (success + failure)** |

## Field Name Differences Between Events

The two events use **different field names** for the same timers:

| Concept | connectivity_ring_buffer_recorded | process_login_finish |
|---------|----------------------------------|---------------------|
| Total login time | `total_login_time_ms` | `total_time_ms` |
| Enqueue wait | `login_task_enqueued_ms` | `enqueue_time_ms` |
| Network read | `network_reads_ms` | `netread_time_ms` |
| Network write | `network_writes_ms` | `netwrite_time_ms` |
| SSL total | `ssl_processing_ms` | `ssl_time_ms` |
| SSL API calls | `ssl_secure_calls_ms` | `ssl_secure_call_time_ms` |
| SSPI total | `sspi_processing_ms` | `sspi_time_ms` |
| SSPI API calls | `sspi_secure_calls_ms` | `sspi_secure_call_time_ms` |
| Logon triggers | `logon_triggers_ms` | `logon_triggers_time_ms` |

## Tables in import_xel_to_sql.sql

- `xe.connectivity` — from connectivity_ring_buffer_recorded, 18 login timer fields + SNI errors
- `xe.login_timers` — from process_login_finish, 18 login timers + fedauth (7 fields) + app/driver metadata

## Version Differences

- **Version 1-2** (older SQL): `ssl_processing_ms` and `sspi_processing_ms` are aggregate only (no sub-breakdown)
- **Version 3** (SQL 2022+): Full sub-breakdown for SSL and SSPI (net_reads/writes, secure_calls, enqueue)

## AD Slow Login Diagnosis

Focus fields for AD/Kerberos/NTLM slow login:
1. `sspi_processing_ms` — total SSPI time
2. `sspi_secure_calls_ms` — time calling DC (AcceptSecurityContext)
3. `sspi_net_reads_ms` / `sspi_net_writes_ms` — network to DC
4. If `sspi_processing_ms` dominates → AD auth bottleneck (DC slow, network to DC slow, Kerberos ticket issues)

## Customer Collection Script

For successful login timing (since system_health doesn't capture it):
```sql
CREATE EVENT SESSION [LoginTimerCapture] ON SERVER
ADD EVENT sqlserver.process_login_finish (
    ACTION (sqlserver.client_hostname, sqlserver.client_app_name, sqlserver.session_id)
)
ADD TARGET package0.event_file (SET filename = N'LoginTimerCapture.xel', max_file_size = 100)
WITH (MAX_MEMORY = 4096 KB, MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF);
ALTER EVENT SESSION [LoginTimerCapture] ON SERVER STATE = START;
```

## sqlcmd XPath Escaping

- SSMS: `@name="field_name"` ✅
- sqlcmd: `@name=''field_name''` ✅ (doubled single quotes)
- sqlcmd: `@name=""field_name""` ❌ (returns NULL)

## Correlate Connectivity with Security Errors

```sql
SELECT c.event_time, c.total_login_time_ms, c.sspi_processing_ms,
    c.sni_consumer_error, c.state, c.remote_host,
    s.error_code, s.api_name, s.calling_api
FROM xe.connectivity c
LEFT JOIN xe.security_errors s ON ABS(DATEDIFF(SECOND, c.event_time, s.event_time)) < 2
WHERE c.total_login_time_ms > 1000
ORDER BY c.event_time DESC
```
