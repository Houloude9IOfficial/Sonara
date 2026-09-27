# Security

Please report vulnerabilities privately to the repository owner. Do not include real pairing invitations, identity keys, device addresses, or unredacted diagnostics.

Discovery names and addresses are untrusted. During the two-minute pairing window, LAN discovery advertises the short-lived invitation so a listener can connect without copy/paste. Another peer on the same broadcast domain can observe that invitation and race the intended receiver; use discovery only on a trusted LAN until host-side receiver approval is implemented. Invitations pin the exact TLS certificate and contain a random 256-bit, single-use token with a host-enforced two-minute lifetime. Live test-tone and process-capture paths use encrypted QUIC and disable 0-RTT. Windows host keys persist encrypted for the current user with DPAPI; the decrypted key is process memory and is not claimed to be hardware-bound. Persistent receiver identities, reconnect-time mutual TLS, revocation storage, and Android Keystore protection are not implemented yet.

Audio is never stored by default. Diagnostic exports exclude invitation tokens and key material.
