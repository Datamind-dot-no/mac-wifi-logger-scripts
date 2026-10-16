# Mac Wi-Fi logger (scripts)

> **Status: Pre-alpha** — Testing has only just started; the tool and its output are not yet validated or confirmed to be working as intended.

Lightweight, continuous gateway ping, Wi-Fi association sampling, and macOS
Wi-Fi events on a shared UTC timeline. Run on 2–3 affected office Macs for
several days, then give the merged CSV to the Wi-Fi infrastructure team.
No GUI, `airport`, third-party packages, or network uploads.

This repository is the dependency-free shell/Perl implementation: no compiled
binary, no third-party packages, and nothing to sign or notarise. A companion
Swift tool is planned for data the script-only approach cannot reach.

## Known limitation: SSID/BSSID redaction

**The script-only approach cannot reliably obtain SSID/BSSID, even with
`sudo`.** macOS keys the Location Services TCC grant to the **calling binary**
that accesses CoreWLAN, not the shell script invoking `wdutil` or
`system_profiler`. The script is not a grantable app identity, so these values
can come back `<redacted>` regardless of privilege level. Running as root
does **not** work around this, and neither does any flag this toolkit could
add. This is the specific gap the planned Swift helper is intended to close.

Blank fields and `association=unknown` are honest missing data, **not evidence
of a disconnect**. Confirm BSSID is populated on the affected Macs; if
unavailable, the Wi-Fi team must use controller/AP logs to identify roams
and AP changes.

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
| `OUTPUT_DIR` | `$HOME/Library/Logs/mac-wifi-logger-scripts` | Absolute output path |
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

**The collectors write CSV files to `$OUTPUT_DIR` and print nothing to
stdout.** A silent terminal is normal and does not mean the tool has failed or
stalled. By default the files are written to
`~/Library/Logs/mac-wifi-logger-scripts/`. Verify collection is actually
happening from a second terminal:

```sh
ls -la ~/Library/Logs/mac-wifi-logger-scripts/
tail -f ~/Library/Logs/mac-wifi-logger-scripts/*.csv
```

Expect a header row plus roughly one ping row per second. If the directory is
empty or missing, check that `route -n get default` returns a gateway and that
the collector process is still running (`pgrep -fl logger.pl`).

Use the same explicit `OUTPUT_DIR` for all three: sudo may change HOME.
Because of this, the privileged state and event collectors can write to a
**different directory** than the unprivileged ping logger — if you find ping
data but no state or event data under `~/Library/Logs/...`, this is why.
For example, first set `OUTPUT_DIR` in `config.sh` to
`/Library/Logs/mac-wifi-logger-scripts`, or prefix each invocation with
`env OUTPUT_DIR=/absolute/path` (after `sudo` for privileged invocations).
Use a fresh directory or consistent ownership when switching to/from root.
Ctrl-C or SIGTERM stops the collector and its child process; records are
flushed individually. Only one collector of each type can run per directory.

`wdutil info` requires root and is preferred. Without root or when it fails,
the sampler uses `system_profiler SPAirPortDataType`. This fallback is slower,
may lack BSSID, and may take longer than the sampling interval: the sampler
never overlaps commands or invents missed samples. Each command has a
20-second timeout. Test a short capture before multi-day deployment.

`log stream` also redacts private messages. It captures info/debug events
actually emitted by the OS, including reason codes when available; it cannot
recover suppressed/private events.

The ping process discovers its gateway once at startup. Restart it after a
network/default-route change. Apple ping reports timeouts when subsequent
requests detect unanswered sequences; their timestamps are observation
times, not exact packet transmission times. Sleep produces a capture gap,
not synthetic loss; use an awake Mac. Enable macOS automatic time sync.

## Start at boot with launchd

The supplied **LaunchDaemons** run as root so wdutil and unified logs work
without an interactive password. All installed scripts/config must be
root-owned and not writable by regular users. From the repository:

```sh
sudo ./bin/install-launchd.sh
```

The installer validates the plists, stops any existing jobs before restarting
them, and sets the required ownership and permissions. It is safe to rerun:
an existing installed `config.sh` is preserved, with a notice. Boot jobs read
`/Library/mac-wifi-logger-scripts/config.sh`, **not the checkout's config**.
Edit it with `sudo nano /Library/mac-wifi-logger-scripts/config.sh`.

Jobs start immediately and at boot, and restart on exit (10-second throttle).
The plists explicitly set `OUTPUT_DIR=/Library/Logs/mac-wifi-logger-scripts`.
No unrotated stderr files are created; launchd diagnostics go to macOS logs.
Collector warnings/errors are sent through `/usr/bin/logger` with the tag
`mac-wifi-logger-scripts` when the supplied jobs set `WIFI_LAUNCHD=1`.
Inspect status with `sudo launchctl print system/no.datamind.wifi-logger-state`.
If a job keeps restarting, run its command in a terminal to see the error.
After changing installed config, restart each job:
`sudo launchctl kickstart -k system/no.datamind.wifi-logger-state` (also ping/event).

Stop and uninstall (retains captured logs):

```sh
sudo ./bin/uninstall-launchd.sh
```

Run this from the checkout. Already-stopped jobs and missing plists are
harmless. The install tree is removed, but captured CSVs in
`/Library/Logs/mac-wifi-logger-scripts` are retained for hand-off.

Stop manual collectors before enabling launchd and vice versa.

## Export and CSV schema

Stop collectors first, or copy a consistent snapshot of all active and rotated
CSV files to a separate directory. Do not merge a file currently being written,
and do not put the output CSV among the inputs.

```sh
sudo sh -c "/Library/mac-wifi-logger-scripts/bin/merge-logs.sh \
  /Library/Logs/mac-wifi-logger-scripts/*.csv > /tmp/office-wifi-merged.csv"
```

The `sh -c` wrapper is what makes this work: it moves the `*.csv` glob
expansion and the `>` redirection into the root shell. Without it both are
handled by your own shell before `sudo` runs, and since
`/Library/Logs/mac-wifi-logger-scripts` is root-owned and mode 700 an
unprivileged shell matches no files — zsh then aborts with
`no matches found`. Check root can see the files with
`sudo ls -la /Library/Logs/mac-wifi-logger-scripts/`.

For logs written to your home directory by manually run collectors, no `sudo`
or wrapper is needed:

```sh
./bin/merge-logs.sh ~/Library/Logs/mac-wifi-logger-scripts/*.csv \
  > /tmp/office-wifi-merged.csv
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
