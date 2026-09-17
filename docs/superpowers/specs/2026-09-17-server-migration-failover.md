# Server Migration And Firmware/App Failover

## Goal

Move the production API, OTA metadata, official animations, and app artifacts to `47.108.204.22` while keeping `60.205.122.153` as a working fallback, and preserve separate S3 and P4 asset pipelines.

## Requirements

- New server is the primary endpoint; old server remains a fallback and receives the same release artifacts.
- Client, S3 firmware, and P4 firmware must retry the fallback when the primary endpoint is unreachable or returns a transport failure.
- The app must keep the server-transcode workflow and pass the target hardware so S3 and P4 packages are never mixed.
- Official factory assets are read-only; user assets remain deletable and offline deletion state must not be lost.
- Existing server data must be backed up before any remote overwrite.
- Public service traffic should use TCP 80 for legacy HTTP OTA compatibility; TCP 443 is recommended for the new deployment, TCP 22 is administrative only, and application port 8787 should not be public when reverse-proxied.
- Credentials are never committed to source, scripts, or logs.

## Architecture

The app owns an ordered list of backend bases and retries each API/native transcode/download operation in order, preferring the new server on every fresh operation. Firmware uses the same primary/fallback ordering for OTA manifest and factory catalog requests. The server accepts an explicit hardware target and validates package format before returning a download URL; S3 uses the legacy indexed package path and P4 uses the JPEG-capable path.

## Migration Safety

Remote migration is blocked until authenticated access to the new ECS is available. Once authenticated, the migration procedure is: inventory and checksum the destination, create a timestamped backup, upload artifacts to a staging directory, validate manifests and hashes, atomically switch metadata, then run read-only API checks.
