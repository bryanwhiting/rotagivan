# Automatic encrypted sync (historical)

Superseded in 1.1.248 by [sync.md](sync.md). The design below (device-enrolled
vault keys, per-field journals with Lamport stamps, approval codes) shipped in
1.1.207–1.1.247 and was replaced because two Macs could not reliably reach the
same state and enrolment was invisible. The current implementation derives the
key from the account password and syncs the whole document, last edit wins.
