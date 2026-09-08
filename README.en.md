# legion-f9-control

> **Unofficial community project.** Lenovo and Legion are trademarks of their
> respective owners; this project is not affiliated with, endorsed by, or
> connected to Lenovo in any way.

Unofficial, safe and scriptable control for Lenovo Legion F9 BT coolers:

- Low-latency, root-free USB control when docked;
- BLE control on battery power;
- Automatic fixed-gear switching based on host CPU temperature;
- Protects unknown configuration bytes, device flash, and your hardware by default;
- Human and stable JSON output.

[中文文档](README.md) | [Protocol facts](docs/protocol.md) | [Safety model](docs/safety.md)

## Support matrix

| Capability | Linux USB | Linux BLE | Windows USB | Windows BLE |
| --- | --- | --- | --- | --- |
| Discovery / status / 4-gear set / monitor | stable | stable | experimental | unsupported |
| Info read | stable | limited by BLE command set | experimental | unsupported |
| Thermal daemon | stable | stable | unsupported | unsupported |
| Raw debug | stable | stable | experimental | unsupported |

“stable” carries a semver compatibility promise; “experimental” may change in
minor releases (the CLI marks it `experimental`).

## Quick start

```console
sudo install -m755 target/release/f9ctl target/release/f9d /usr/local/bin/
sudo cp packaging/udev/60-legion-f9-control.rules /usr/lib/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger

f9ctl status
f9ctl mode set beast
f9ctl monitor
```

BLE prerequisites: device on battery power (it does not advertise on USB-only
power), BlueZ ≥ 5.55.

## Gears & turbo risk

Gears are `quiet / balanced / beast / turbo`. Every write is
read-modify-write with session open/close and a read-back; setting the gear
that is already active performs **zero** flash writes.

- `turbo` depends on power supply. If RPM does not reach the expected platform,
  the device may fall back on its own — that is **not** a failed write. The CLI
  prints a supply/fallback warning on every direct turbo set.
- The daemon disables turbo by default (`allow_turbo = true` to opt in).

## Daemon quick start

```console
f9ctl daemon install
cp config/f9d.example.toml ~/.config/legion-f9-control/config.toml
f9ctl config validate
f9ctl daemon start
```

Default curve: `<50°C quiet`, `50–<60°C balanced`, `≥60°C beast`, with 3 °C
down-switch hysteresis, 15 s minimum dwell, and a read-only degraded mode after
3 consecutive failures. Restart after config changes (no hot reload in v1).

## JSON automation

```console
$ f9ctl --output json status
{
  "schema_version": 1,
  "ok": true,
  "command": "status",
  "device": { "id": "redacted-stable-session-id", "transport": "usb" },
  "data": { "rpm": 2012, "gear": "balanced" },
  "warnings": []
}
```

Fields are only added or deprecated across minor releases; `monitor
--output json` emits JSON Lines; diagnostics go to stderr. Exit codes:
0 ok; 2 usage/config; 3 no device; 4 permission; 5 busy; 6 timeout/disconnect;
7 invalid protocol response; 8 verification failed/uncertain; 9 unsupported;
10 safety policy denied.

## Raw debug (read-only by default)

```console
f9ctl debug raw --cmd 0x1a --length 6 --offset 0
f9ctl debug raw --cmd 0x06 --length 15 --data "..." --unsafe-write
```

Writes require `--unsafe-write` plus a random confirmation word on a TTY, or
`F9CTL_UNSAFE_WRITE_ACK=<command digest>` in scripts/CI. OTA / report 5 are
**permanently rejected**.

## Privacy & security

- Logs redact BLE addresses, USB serial numbers and user paths by default;
- No network listeners; IPC is a per-user Unix domain socket (0600);
- Report security issues privately: [SECURITY.md](SECURITY.md).

See [docs/troubleshooting.md](docs/troubleshooting.md) for common problems.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). CI enforces `cargo fmt --check`,
`cargo clippy -D warnings`, the full test suite, license/advisory checks
(`cargo-deny`), secret scans and forbidden-file gates.

## License

Distributed under the [MPL-2.0](LICENSE) (Mozilla Public License 2.0): modifications to
this project's source files must be shared under the same license, while integration
into larger works (including proprietary ones) remains free. See also [NOTICE.md](NOTICE.md)
for the unofficial-project and trademark notice.
