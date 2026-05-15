# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-05-15

### Added
- Opt-in JSONL chat archive in `irc-bridge-go`: when `CHAT_LOG_DIR`
  is set, every PRIVMSG is persisted to
  `<CHAT_LOG_DIR>/chat-YYYY-MM-DD.jsonl` with deployment-salted
  SHA256(client IP) for pseudonymisation. Disabled by default — the
  default behaviour remains in-memory only (replay buffer).

### Changed
- README simplified down to a short description, hardware requirements,
  quick install, configuration essentials, and troubleshooting basics.
- Documentation cleanup: removed internal-spec cross-references from
  README and CHANGELOG; moved capacity-planning notes out of the
  public tree into the maintainer workspace.

## [1.0.0] - 2026-05-14

Initial tagged release. Covers the full delivery scope of the project:
mesh networking (802.11s + batman-adv) on Raspberry Pi nodes, WiFi access
point with `max_num_sta=8` cap and ACS on channels {1, 6}, ngircd + Go
WebSocket bridge, captive-portal-friendly HTTP endpoints, watchdog with
restart → USB reset → reboot escalation, gratuitous ARP refresh on
station association, navigator.onLine fast-reconnect on the frontend,
LED status indicator with five distinct patterns, `make sdcard` with
anti-erasure safeguards, and `make wipe-logs` to scrub host journals at
end of exposition.

See `README.md` for the operator-facing documentation.

### Versioning policy

- `MAJOR` is bumped when a documented critère vérifiable changes in a
  non-backward-compatible way (rare).
- `MINOR` is bumped when a new feature is added.
- `PATCH` is bumped for bug fixes and internal refactors.

The notification of mise à disposition cites the exact tag of the
delivered version.
