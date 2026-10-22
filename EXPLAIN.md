# How this works, in plain words

Sending: a user approves the bridge to spend their tokens and calls
`bridge`. The bridge pulls the tokens into itself (the lock), bumps the
outbound nonce for that destination chain, adds the amount to the daily
volume counter, and hands a payload of (nonce, sender, receiver, amount)
to the endpoint.

Receiving: the endpoint on the other chain calls `lzReceive`. The
bridge checks the caller really is the endpoint, checks the source
address against the trusted remote stored for that chain, then checks
the nonce. Nonce checking is the heart of this rebuild: inbound nonces
must come in sequence, and each one is written down before any minting.
That single require is what stops a replayed message from minting twice.
The original code accepted the nonce parameter and never looked at it.

## What got re scoped from the original

- Replay protection was claimed but not implemented. Now it is
  implemented and pinned by tests, including a replay test and an out of
  order test.
- The claimed load test (a large simulated volume, zero fund loss, full
  delivery reliability) never existed. Deleted. What exists is 7 local
  tests, all passing.
- The claimed 45 second median completion time was never observed
  anywhere. Deleted. Message timing belongs to live networks, and this
  contract has never been on one.
- Scope stated honestly: one direction only (lock and mint), mock
  endpoint and tokens in tests, ungated trusted remote setter flagged in
  the code.
