# Security policy

## Reporting

Use GitHub's private vulnerability reporting:
[Report a vulnerability](https://github.com/immineal/tidal-wave/security/advisories/new),
under the repository's Security tab. The draft advisory is visible only to you
and the maintainer. Please do not open a public issue for a vulnerability.

Useful things to include: what an attacker can do, how to reproduce it, the
version and platform you saw it on, and whether it needs an account.

This is a hobby project with one maintainer and no bounty. Realistically you
will hear back within a week or two. If a fix is warranted it goes into the
next release, and you are credited in the release notes unless you would
rather not be.

## Supported versions

Only the latest release gets fixes. There are no maintenance branches.

## Already known, please don't report these

All of these are documented in the README's privacy section:

* `~/.config/tidal-wave/credentials.json` holds the Tidal access and refresh
  tokens as plain JSON. It is written mode 0600 and is not encrypted or kept in
  a keyring, so anything running as your user can read it and use your Tidal
  account.
* The OAuth client id and secret are compiled into the binary
  (`kClientSecret` in `src/api/Auth.cpp`). Anyone with the binary can extract
  them.
* While a track is casting, the built-in HTTP server
  (`src/cast/CastMediaServer.cpp`) is bound to your LAN address on an ephemeral
  port with no authentication, so anything on your local network that finds it
  is served that track. It stops when casting stops.
* The TLS connection to a Chromecast device does not verify the certificate.
  Chromecasts use self-signed certificates; there is nothing to verify against.
* Discovery is mDNS, which is multicast and visible to the whole LAN.

If you have an attack that goes further than one of these, please do report
it. Suggestions for a better design belong in a feature request.

## Out of scope

Tidal's own service and API, including anything about what their endpoints
return or what a token is entitled to. Attacks that require the attacker to
already be running code as your user. Missing hardening flags with no
demonstrated impact.
