# Offline APT bundle

`bundle.lock.json` binds the amd64 bundle image, snapshot, exact download
closure, and upstream source revision. The image exposes `/apt-bundle` with
the original signed Debian and Debian Security indexes and the 65 package
files listed in `debian-packages.txt`. This closure describes downloads, not
every package inherited from the nginx base. `pinned-packages.txt` remains the
installation policy; nginx.org's nginx binary and modules stay in that base.

The Dockerfile copies bundle data through a scratch stage and mounts it read
only during an APT `RUN --network=none`. The reviewed, source-controlled
`prepare-apt.sh` creates isolated, file-only APT configuration. Debian signatures
and package hashes are verified using the pinned base's
`/usr/share/keyrings/debian-archive-keyring.gpg`, never a key from the bundle.
The image's automatic-package state is seeded into isolated APT state and
persisted back after installation. The helper configuration, cache, lists, and
logs are removed in the same RUN.

The lock currently records a locally assembled OCI manifest digest.
The approved source helper is present, with its SHA-256 recorded in the lock.
Publication and anonymous public pulls remain pending. Do not replace the
digest with a mutable tag or fetch a helper from the bundle. The shared
assembler and publication commands are delivered separately; this repository
adds no automatic publisher.

For regeneration, retain the signed original indexes, fetch the exact closure
against the pinned base and package policy, verify signatures and hashes, and
reassemble the OCI artifact. Review manifest changes and update both the
Dockerfile reference and lock to the computed manifest digest. Before release,
CI must verify anonymous public pulls, the locked closure and trust chain,
offline APT installation, existing nginx configuration/security tests, and
full application reproducibility with the established build script/options.
This creates a new application image candidate requiring a new Brave-approved
application digest. Do not deploy before public bundle availability and a
successful full reproducibility check.
