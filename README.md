# Mac Wi-Fi troubleshooter

Lightweight, continuous gateway ping, Wi-Fi association sampling, and macOS
Wi-Fi events on a shared UTC timeline. Run on 2–3 affected office Macs for
several days, then give the merged CSV to the Wi-Fi infrastructure team.
No GUI, `airport`, third-party packages, or network uploads.

## Requirements and configuration

macOS with its shipped `/bin/bash`, `/usr/bin/perl` (core Time::HiRes and
JSON::PP), `route`, `ping`, `log`, and either `wdutil` or `system_profiler`.
Missing commands and failed data sources produce errors. An IPv4 default
gateway is required. Connect to the office Wi-Fi, disconnect Ethernet/VPN if
they replace the default route, and verify `route -n get default`: this tool
pings the **system default gateway**, not an arbitrary hardcoded router.

Edit `config.sh`, or export overrides:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PING_INTERVAL` | `1` | Seconds between ICMP requests |
| `SAMPLE_INTERVAL` | `5` | Seconds between Wi-Fi sample starts |
| `OUTPUT_DIR` | `$HOME/Library/Logs/mac-wifi-troubleshooter` | Absolute output path |
| `RETENTION_DAYS` | `7` | Rotated file retention in days |
| `MAX_LOG_BYTES` | `10485760` | Rotate each stream at approximately 10 MiB |
| `MACHINE_ID` | hostname | Stable machine/asset identifier for pooling logs |

The three streams rotate independently at the size threshold or UTC day
boundary. Each rotated file retains the header. Expired rotated files are
pruned once per minute when data arrives; idle event logs are pruned on their
next event. Active files remain. Disk use is bounded by retention **and event
volume**, not a hard total disk quota; choose retention/size for your fleet.
One oversized event may exceed the file threshold. Files are private (umask
077). Don't share an output directory between Macs.

## Run and stop manually

From the checked-out repository, in three terminals:

```sh
./bin/wifi-ping-logger.sh
sudo ./bin/wifi-state-sampler.sh
sudo ./bin/wifi-event-logger.sh
```

Use the same explicit `OUTPUT_DIR` for all three: sudo may change HOME.
For example, first set `OUTPUT_DIR` in `config.sh` to
`/Library/Logs/mac-wifi-troubleshooter`, or prefix each invocation with
`env OUTPUT_DIR=/absolute/path` (after `sudo` for privileged invocations).
Use a fresh directory or consistent ownership when switching to/from root.
Ctrl-C or SIGTERM stops the collector and its child process; records are
flushed individually. Only one collector of each type can run per directory.

`wdutil info` requires root and is preferred. Without root or when it fails,
the sampler uses `system_profiler SPAirPortDataType`. This fallback is slower,
may lack BSSID, and may take longer than the sampling interval: the sampler
never overlaps commands or invents missed samples. Each command has a
20-second timeout. Test a short capture before multi-day deployment.

**macOS privacy restrictions can redact SSID/BSSID even with sudo.** Location
Services/terminal permissions and OS version affect availability. Root does
not guarantee BSSID access, and this toolkit cannot bypass privacy controls.
Blank fields and `association=unknown` are honest missing data, **not a
disconnect**. Confirm BSSID is populated on the affected Macs; if unavailable,
the Wi-Fi team must use controller/event logs to identify AP changes.
`log stream` also redacts private messages. It captures info/debug events
actually emitted by the OS, including reason codes when available; it cannot
recover suppressed/private events.

The ping process discovers its gateway once at startup. Restart it after a
network/default-route change. Apple ping reports timeouts when subsequent
requests detect unanswered sequences; their timestamps are observation
times, not exact packet transmission times. Sleep produces a capture gap,
not synthetic loss; use an awake Mac. Enable macOS automatic time sync.

## Start at boot with launchd

The supplied **LaunchDaemons** run as root so `wdutil` and unified logs work
without an interactive password. From the repository, install and start them
with `sudo ./bin/install-launchd.sh`. This copies root-owned, non-user-writable
files into `/Library/mac-wifi-troubleshooter`, installs and bootstraps the
LaunchDaemons, and starts collection immediately and at boot. Edit the installed
`/Library/mac-wifi-troubleshooter/config.sh` to change collector settings.
Installation and removal require sudo.

Jobs start immediately and at boot, and restart on exit (10-second throttle).
Logs are written to `/Library/Logs/mac-wifi-troubleshooter`; the plists
explicitly set `OUTPUT_DIR` there.
No unrotated stderr files are created; launchd diagnostics go to macOS logs.
Collector warnings/errors are sent through `/usr/bin/logger` with the tag
`mac-wifi-troubleshooter` when the supplied jobs set `WIFI_LAUNCHD=1`.
Inspect status with `sudo launchctl print system/no.datamind.wifi-state`.
If a job keeps restarting, run its command in a terminal to see the error.
After changing installed config, restart each job:
`sudo launchctl kickstart -k system/no.datamind.wifi-state` (also ping/event).

Stop and uninstall with `sudo ./bin/uninstall-launchd.sh`. It removes the
installed scripts and plists but **retains captured logs** for hand-off.

Stop manual collectors before enabling launchd and vice versa.

## Export and CSV schema

Stop collectors first, or copy a consistent snapshot of all active and rotated
CSV files to a separate directory. Do not merge a file currently being written,
and do not put the output CSV among the inputs.

```sh
sudo /Library/mac-wifi-troubleshooter/bin/merge-logs.sh \
  /Library/Logs/mac-wifi-troubleshooter/*.csv > /tmp/office-wifi-merged.csv
```

The merger validates the schema and orders rows by UTC timestamp then machine.
It uses macOS external `sort` to avoid loading multi-day logs into memory.
It preserves individual observations rather than guessing state between
samples. For pooled captures, pass CSV paths from each machine's directory.
Securely transfer the export; SSIDs, BSSIDs, hostnames, and event messages may
identify internal infrastructure.

All files use this stable header (irrelevant/unavailable fields are empty):

```text
timestamp_utc,machine_id,stream,gateway,status,icmp_seq,rtt_ms,association,ssid,bssid,rssi_dbm,noise_dbm,channel,tx_rate_mbps,source,message
```

Fields are always CSV-quoted; quotes are doubled. Embedded newlines/CR in
messages/identifiers become literal `\n`/`\r`, keeping one record per line.

* `timestamp_utc`: `YYYY-MM-DDTHH:MM:SS.ffffffZ`. Ping uses receipt time,
  state uses query-start time, and events use Apple's original timestamp,
  converted from its explicit timezone offset to UTC. Clock/source accuracy
  is not guaranteed merely by emitting six fractional digits.
* `machine_id`: configured asset ID or hostname; `stream`: `ping`, `state`, `event`.
* Ping: `gateway`, `status` (`reply`, `timeout`, `error`, `info`), `icmp_seq`,
  `rtt_ms`. Startup/statistics lines are `info`, not packet results.
* State: `association` (`associated`, `disconnected`, `unknown`), `ssid`,
  `bssid`, signal/noise in dBm, channel (as reported, including band/width),
  TX rate in Mbps. `source` identifies `wdutil` or `system_profiler`.
* Events: `source=log`, `status=event`, `message` includes Apple's message/reason
  code unchanged except CSV escaping. Non-JSON startup lines are `info`.
  `timestamp_unparsed` means receipt time was used; the raw JSON is retained
  in `message` so the original timestamp is not lost.

## How the Wi-Fi team should interpret the timeline

Filter by machine and incident window; correlate authoritative UTC timestamps
with AP/controller logs. Ping loss alone **does not prove disassociation**.

* **BSSID changes beside loss:** candidate roam problem. Find roam/deauth events
  and reason codes; a BSSID change by itself can be a normal roam.
* **RSSI collapses beside loss:** candidate coverage/interference issue; compare
  noise, channel, TX rate, and controller RF telemetry.
* **Strong/stable RSSI and association with sustained gateway loss:** candidate
  upstream forwarding, DHCP/addressing, gateway, or ICMP filtering issue—not
  proof of a Wi-Fi disconnect. Check wired/controller and DHCP logs.
* **Explicit disconnected state plus disconnect event:** evidence the Mac lost
  association. Redacted/blank BSSID is not equivalent.

Five-second samples can miss short disconnects/roams; the event stream fills
that gap when macOS exposes the events. The gateway responding only proves
local ICMP reachability, not DNS, Internet, or application availability.
