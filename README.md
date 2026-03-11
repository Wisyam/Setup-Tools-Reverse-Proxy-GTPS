# Setup Tools Reverse Proxy GTPS

Toolset ini menyiapkan reverse proxy UDP GTPS dengan arsitektur:
- Tencent Cloud sebagai `gate` (router + NAT + rate limit)
- DigitalOcean sebagai `main` (server game utama)
- WireGuard tunnel (`wg0`) antar server

## Files
- `proxy-gate.sh` -> jalankan di server Tencent (gate)
- `proxy-main.sh` -> jalankan di server DigitalOcean (main)
- `proxy-verify.sh` -> validasi + generate laporan bukti
- `.env` -> config runtime
- `.env.example` -> template config

## Interface
- `proxy-main.sh --config /path/.env --mode apply|verify`
- `proxy-gate.sh --config /path/.env --mode apply|verify`
- `proxy-verify.sh --config /path/.env --out /path/report.md [--restart-test true|false]`

## Quick Start
1. Salin template config:
   - `cp .env.example .env`
2. Isi `.env` dengan IP publik server dan WireGuard public keys.
3. Jalankan di server main:
   - `sudo bash ./proxy-main.sh --config ./.env --mode apply`
4. Jalankan di server gate:
   - `sudo bash ./proxy-gate.sh --config ./.env --mode apply`
5. Verifikasi:
   - `sudo bash ./proxy-verify.sh --config ./.env --out ./proxy-setup-summary.md --restart-test true`

## Notes
- `proxy-gate.sh` punya checkpoint manual firewall vendor Tencent sebelum lanjut SSH hardening.
- Rule iptables ditandai `WYSPS_PROXY_*` untuk idempotency dan rollback terarah.
- Script ditargetkan untuk Ubuntu 24.04 dan butuh akses root.