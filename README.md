# Cross Chain Bridge

I built a lock and mint token bridge in Solidity over a LayerZero shaped
endpoint interface. The source side locks an ERC20. The destination side
receives the message and mints a wrapped token to the receiver.

## The replay bug, and the fix

The original version of this contract tracked outbound nonces but the
receiving function ignored the nonce completely. The same delivered
message processed twice would mint twice. That was a real hole and the
README still called it replay protection.

Now `lzReceive` decodes the nonce from the payload and requires it to be
exactly the next expected inbound nonce for that source chain, starting
at 1. Each accepted nonce is recorded before minting. A test delivers
the same message twice and the second delivery reverts, with the
receiver balance unchanged.

## What the contract checks

- Only the endpoint can call `lzReceive`.
- The source address must match the stored trusted remote for that chain.
- The inbound nonce must be the next expected one. Out of order delivery
  reverts too, which is a deliberate trade: simple and safe, at the cost
  of needing ordered delivery.
- `bridge` enforces a daily volume limit of 1,000,000 tokens per
  destination chain as a circuit breaker.

## What it is not

- Never deployed. There is no load test and no timing figure. Earlier
  drafts claimed a load test with simulated volume and a median
  completion time of about 45 seconds. Neither ever happened, so both
  claims are deleted.
- The "two chains" in the tests are two bridge instances on one local
  EVM, with a mock endpoint delivering messages and mock tokens. The
  return path (burn wrapped, unlock original) is not implemented; only
  the outbound lock and mint direction is built and tested here.
- `setTrustedRemote` is ungated in this local version, which the code
  comments flag. A deployed version would need ownership control there.

## Run it

```
forge test
python3 scripts/measure.py
```

## Results

7 tests, 7 passed: lock and mint round trip, replay rejection, out of
order rejection, untrusted remote rejection, endpoint only delivery,
daily limit, and sequential messages minting in order.
