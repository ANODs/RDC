# RDC relay

When a phone and a computer cannot connect directly — both behind strict NAT, as on mobile data or a VPN — RDC sends the session through a relay: a small Cloudflare Worker that passes messages between the two. RDC uses its own relay by default. You can run your own on your Cloudflare account, free, in a couple of minutes, and point RDC at it.

The relay cannot see your screen or your input. Both ends derive a random room name and an AES-256-GCM key from the link; the worker only hands sealed bytes from one end to the other. Every message is numbered, so it cannot drop, repeat or reorder them unnoticed either.

## Deploy your own

**With a button:** [![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/ANODs/RDC/tree/main/relay)

Sign in to Cloudflare (a free account is enough), confirm, and wait for the deploy to finish. Your relay's address is shown at the end: `https://rdc-relay.<your-subdomain>.workers.dev`.

**Or from a terminal** (Node.js 20+):

```sh
git clone https://github.com/ANODs/RDC.git
cd RDC/relay
npx wrangler login
npx wrangler deploy
```

## Use it

In RDC on the computer: **Settings → Relay → My own relay**, paste the address and press Return. RDC checks that the relay answers and uses it from then on. **Off** turns the relay off: only direct connections.

From a terminal: `rdc --relay https://rdc-relay.<your-subdomain>.workers.dev` (or `--relay off`) for one run.

## Limits

The free Workers plan covers a few hours of relayed sessions a day: a relayed session counts Durable Object requests (one per 20 messages) and duration. Direct connections never touch the relay. If you open the viewer from a page other than `https://anods.github.io/RDC/`, add its origin to `ORIGINS` in `wrangler.toml`.

Check it: `https://<your relay>/` answers `{"rdc_relay":1}`.
