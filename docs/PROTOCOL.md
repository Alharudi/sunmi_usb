# POS Link protocol v1

How the cashier (e.g. Sunmi Flex 3) and the payment terminal (e.g. Sunmi P3) talk over a USB
cable (Android Open Accessory) or TCP. The same bytes are used on both transports.

## Frame

```
| STX 0x02 | version | type | seq (u16 BE) | length (u16 BE) | payload | CRC16 (u16 BE) |
```

- `version` = `1`.
- `payload` = UTF-8 JSON object, up to 8192 bytes; may be empty.
- CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`) over `version … payload`. Check value for
  `"123456789"` is `0x29B1`.
- If a whole frame is an exact multiple of 64 bytes, one `0x00` byte is appended. USB bulk pipes
  otherwise wait for a zero-length packet. Receivers skip any byte that isn't `STX` between frames.
- Example: `SALE_REQUEST`-type frame, seq 7, payload `{"amount":12500}`:
  `020120000700107b22616d6f756e74223a31323530307dbe65`

## Message types

| Code | Name | Direction | Payload |
|---|---|---|---|
| 0x01 | `HELLO` | both | `role` (`cashier`/`terminal`), `protocol`, `sessionId`, `manufacturer`, `model`, `appVersion`, `needReply` |
| 0x03 | `PING` | both | none |
| 0x04 | `PONG` | both | none (same seq as the PING) |
| 0x05 | `ACK` | both | none; `seq` = the acknowledged frame |
| 0x06 | `NAK` | both | `code` |
| 0x10 | `STATUS` | terminal → cashier | `state`: `idle` / `busy` |
| 0x20 | `SALE_REQUEST` | cashier → terminal | `txnId` (UUID), `amount` (int, minor units), `currency` (ISO 4217), `reference`?, `createdAt` (ISO 8601) |
| 0x21 | `READY_TO_PAY` | terminal → cashier | `txnId`, `amount`, `currency` |
| 0x22 | `PROGRESS` | terminal → cashier | `txnId`, `stage`: `waitingCard` / `cardRead` / `pinEntry` / `authorizing` / `printing` |
| 0x23 | `SALE_RESULT` | terminal → cashier | `txnId`, `outcome` (`approved`/`declined`/`cancelled`/`timeout`/`error`), `amount`, `currency`, `timestamp`, `responseCode`?, `message`?, `authCode`?, `rrn`?, `stan`?, `maskedPan`?, `cardScheme`?, `terminalId`?, `merchantId`? |
| 0x24 | `CANCEL` | cashier → terminal | `txnId` |
| 0x25 | `TXN_STATUS_QUERY` | cashier → terminal | `txnId` |
| 0x26 | `TXN_STATUS` | terminal → cashier | `txnId`, `state` (`notFound`/`inProgress`/`completed`/`interrupted`), `result`? (when completed), `stage`? |
| 0x7F | `ERROR` | both | `code`, `message`, `txnId`? |

Amounts are integers in the currency's minor unit. LYD has 3 decimals, so `12.500 LYD` is `12500`.

Card data rule: only a **masked** PAN may cross the link. Never full PAN, track data or PIN.

### Error codes

`BUSY`, `CANNOT_CANCEL`, `UNKNOWN_TXN`, `TXN_INTERRUPTED`, `BAD_REQUEST`, `UNKNOWN_TYPE`,
`BAD_PAYLOAD`, `UNSUPPORTED_VERSION`.

## Link rules

1. **Handshake.** When the transport connects, each side sends `HELLO` with `needReply: true`
   every heartbeat until it receives the peer's `HELLO`. It answers a `needReply` HELLO with its
   own (`needReply: false`). The link is online once a HELLO with the same protocol and the
   *opposite* role has arrived. A new `sessionId` means the peer app restarted.
2. **Reliability.** Every non-link-level frame (types `0x10` and up) carries a fresh `seq`
   (1…65535) and must be ACKed. The sender retries after 1.5 s, up to 3 times. The receiver ACKs
   duplicates again but delivers each `seq` only once per peer session.
3. **Heartbeat.** `PING` every 3 s. After 10 s of silence the link is "not responding"; after
   20 s the transport is reset.
4. **Back-pressure.** A USB accessory write blocks while the host isn't reading (e.g. the cashier
   app is closed but the cable is in). While any earlier frame is still waiting to leave, a side
   skips heartbeats (`HELLO`, `PING`, `PONG`) and doesn't queue a second copy of a message for a
   retry. A host that starts reading late gets a few queued frames, not every heartbeat it
   missed. The native writer also refuses sends past 32 queued frames.

## Payment rules

1. **One charge per `txnId`.** If the terminal gets a `SALE_REQUEST` for a `txnId` it already
   finished, it re-sends the stored `SALE_RESULT` and does not charge again.
2. **One sale at a time.** A different `txnId` during a running sale gets `ERROR BUSY`.
3. **Cancel** works only before a card is presented; otherwise the answer is `ERROR CANNOT_CANCEL`.
4. **Never assume the outcome.** If the cashier loses the link or gets no answer, the sale is
   *unknown*, not *declined*. The cashier sends `TXN_STATUS_QUERY` when the link is back:
   - `notFound`: the terminal never got it, no money moved, safe to charge again.
   - `inProgress`: wait.
   - `completed`: apply the included result.
   - `interrupted`: the terminal app restarted mid-payment; check the terminal report by hand.
5. **Result delivery.** The terminal keeps every result until the cashier ACKs it, and re-sends
   unacknowledged results (from the last 24 h) when the link comes back.

## Typical sale

```
cashier                                  terminal
  │ SALE_REQUEST #12 {txnId, 12500 LYD} ─►│
  │◄──────────────────────────── ACK #12  │
  │◄────────────── READY_TO_PAY #40 {txnId}│  terminal shows "Tap / insert card"
  │ ACK #40 ─────────────────────────────►│
  │◄──────── PROGRESS #41 {cardRead}      │
  │◄──────── PROGRESS #42 {pinEntry}      │
  │◄──────── PROGRESS #43 {authorizing}   │
  │◄──────── SALE_RESULT #44 {approved…}  │
  │ ACK #44 ─────────────────────────────►│  terminal marks result delivered
```
