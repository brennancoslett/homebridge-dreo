# Branch notes: `improve-power-logic-and-sync`

Reliability work on Dreo fan control, plus reverse-direction support for DR-HCF
ceiling fans. Commits are ordered so the reliability fixes sit below the ceiling-fan
feature and can be upstreamed independently.

Supersedes `REVERSE_TOGGLE_IMPLEMENTATION.md`.

---

## The core problem: server acks are not device confirmations

The Dreo cloud replies to every control message with `control-reply` whether or not
the hardware ever applies it. The device sends a separate `control-report` when a
change actually takes effect. The plugin originally treated a send as success, so
HomeKit could sit indefinitely showing a state the fan never reached.

Two independent failure modes came out of this, both fixed on this branch:

1. **Concurrent writes** — HomeKit writes every characteristic of a scene at once.
   The plugin relayed each as its own WebSocket message within ~30 ms and the device
   dropped all but one.
2. **Dropped speed on off-to-on** — a bare power-on racing a combined power-on +
   windlevel command made the device drop the windlevel half.

Evidence from three days of `homebridge.log` for a DR-HCF ceiling fan:

| What was sent | `control-report` back? |
| --- | --- |
| 3 messages in the same second (`lighton`, `brightness`, `windlevel`+`fanon`) | never |
| commands spaced ≥ 500 ms apart | always, within ~1 s |

No exceptions in either direction.

---

## Commits

### `b412d97` — Improve power control reliability and WebSocket reconnection state sync

- Removed the `if (currState.on !== value)` guards on explicit power (`Active`)
  commands across Fan, Heater, and Humidifier. The guard suppressed a real command
  whenever the cached state had drifted, which is exactly when the command is needed.
- Command setters update cached state immediately, so rapid changes and automation
  triggers do not read a stale value mid-flight.
- Added `updateState()` to each accessory, and refreshed every device over the HTTP
  API whenever the WebSocket connects or reconnects.
- Exposed the device serial and accessory handlers on the platform to support that
  refresh.

### `4f69bf7` — Only send WebSocket keepalive while the socket is open

The 15-second keepalive called `send('2')` unconditionally.
`ReconnectingWebSocket` buffers sends made while disconnected, so a long outage
queued up keepalives that all flushed at once on reconnect. Now gated on
`readyState === OPEN`.

### `5c6367c` — Fix fan speed being dropped during off-to-on transitions

- Track `confirmedWindlevel` from `control-report` / `report` only, never from
  `control-reply`.
- Re-send the speed command (up to two retries, 2 s apart) if the device never
  confirms it.
- Cancel in-flight verification on power-off so a retry cannot turn the fan back on.

Note the limit of this check: it compares windlevel only. A DR-HCF retains its
windlevel while powered off, so a command that failed to apply *power* still looks
confirmed. `f63e38a` covers that gap.

### `93cfabe` — Add reverse toggle support for ceiling fans

On DR-HCF fans `mode` selects blade direction, not auto/manual:

| `mode` | Meaning |
| --- | --- |
| 1 | Normal / straight wind |
| 2 | Natural wind |
| 3 | Sleep wind |
| 4 | **Reverse direction** |

- Ceiling fans are detected with `model.startsWith('DR-HCF')`.
- Reverse is exposed as its own `Switch` service rather than `TargetFanState`.
- `TargetFanState` is no longer registered on ceiling fans, and a stale one is
  actively removed from cached accessories. Leaving it in place let scenes send
  conflicting `mode` commands during power-on, and selecting "Auto" in the Home app
  would have reversed the fan.
- `setReverse()` skips no-op writes. Scenes write every characteristic they capture,
  and a redundant `mode` command during power-on made the device drop the
  accompanying speed change.
- Reverse state syncs from the Dreo app via WebSocket and survives restarts.

### `ff26a04` — Add prepare script so git installs build dist automatically

`"prepare": "npm run build"` in `package.json`, so installing the plugin straight
from the git branch produces a built `dist/`.

### `f63e38a` — Pace outgoing commands so the device stops dropping concurrent writes

Root fix for failure mode 1.

**`src/DreoAPI.ts`** — outgoing commands are queued per device instead of written
straight to the socket:

- Writes to the same subsystem merge into a single message. `COMMAND_GROUPS` maps
  `lighton` / `brightness` / `colortemp` to a `light` group; everything else shares
  the default `device` group.
- A 100 ms coalescing window catches the whole HomeKit write burst before anything
  is sent.
- Messages are spaced `MIN_COMMAND_GAP_MS` (750 ms) apart. The gap is measured
  against the device, not the current drain pass, so a command arriving just after a
  batch finishes is still spaced out.
- `waitForOpenSocket()` holds sends until the socket is open, rather than letting
  `ReconnectingWebSocket` buffer them and flush a burst carrying stale timestamps.

**`src/platform.ts`** — `reconcileDevice(sn)` pulls authoritative state over the HTTP
API 5 s after commands settle and pushes it into HomeKit. This is the safety net: it
does not matter *why* the device ignored a command, HomeKit gets corrected either
way. It sits in `DreoAPI.control`, so heater and humidifier get it too.

**`src/accessories/FanAccessory.ts`**

- Handle `device-online` messages, which carry a full flat state snapshot when the
  device rejoins the cloud.
- Removed the `pendingPowerOnTimer` / `lastSpeedCommandTime` suppression hack. The
  queue merges the bare power-on into the power-on + windlevel command on its own.

Effect on the failing burst:

```
before:  3 messages in ~30ms   ->  0 control-report, HomeKit stuck "on"
after:   +102ms  {"brightness":100,"lighton":true}
         +853ms  {"fanon":true,"windlevel":12}
```

---

## Verification

Simulated (stubbed socket, `dist/DreoAPI.js`):

- Scene burst of 4 setter calls collapses to 2 messages, 751 ms apart, with the bare
  power-on merged into the windlevel command.
- Power-on with no speed change stays a single message.
- A command arriving 150 ms after a batch drained still waits for the full gap.

On-device, three DR-HCF ceiling fans:

- Speed changes while running confirmed by `control-report` within ~350 ms.
- Off-to-on at a new speed from the fan tile: single combined command, speed applied
  first try.
- Scenes turning fans off/on with speeds: no redundant `mode:1` commands; when the
  device dropped a speed, the retry re-sent it and the fan self-corrected within ~3 s.
- Reverse switch toggles blade direction and syncs from the Dreo app.
- **2026-07-22, light + fan on together** — the case that motivated `f63e38a`:

  ```
  +   0ms  control-reply   {"brightness":100,"lighton":true}
  + 385ms  control-report  {"lighton":true}
  + 752ms  control-reply   {"windlevel":12,"fanon":true}
  +1197ms  control-report  {"fanon":true}
  ```

  Both halves confirmed by the device. The off-toggle behaved the same way.

---

## Deployment

```bash
npm run build
rsync -az --delete dist/ hb:/var/lib/homebridge/node_modules/homebridge-dreo/dist/
rsync -az package.json hb:/var/lib/homebridge/node_modules/homebridge-dreo/package.json
ssh hb "sudo hb-service restart"
```

Use `192.168.1.247` in place of `hb` if hostname resolution fails.

Confirm the running install matches the branch:

```bash
# these two must print the same hash
find dist -name '*.js' | sort | xargs shasum | shasum
ssh hb "cd /var/lib/homebridge/node_modules/homebridge-dreo && \
  find dist -name '*.js' | sort | xargs shasum | shasum"

# and Homebridge must have started after the files landed
ssh hb "stat -c '%y %n' /var/lib/homebridge/node_modules/homebridge-dreo/dist/DreoAPI.js; \
  systemctl show homebridge --property=ActiveEnterTimestamp"
```

---

## Tuning

All in `src/DreoAPI.ts`:

| Constant | Value | Why |
| --- | --- | --- |
| `COMMAND_COALESCE_MS` | 100 | Long enough to catch a HomeKit write burst (~30 ms observed) |
| `MIN_COMMAND_GAP_MS` | 750 | Logs show 500 ms is enough; 750 ms leaves headroom |
| `RECONCILE_DELAY_MS` | 5000 | Long enough for cloud state to settle after the last command |

If a device turns out to accept a fully merged payload across subsystems, dropping
`COMMAND_GROUPS` would cut the burst to a single message and remove the 750 ms
latency. Not done here: a rejected merged payload would fail the light *and* the fan,
which is worse than the current behaviour.

## Notes

- Reverse switch only affects DR-HCF ceiling fans.
- No config changes required.
- Backward compatible with existing fan implementations.
