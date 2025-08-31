;; ClarityStream - Decentralized Streaming Payments Protocol
;;
;; A revolutionary smart contract enabling continuous, block-by-block STX 
;; payments on the Bitcoin-secured Stacks blockchain. Perfect for salaries,
;; subscriptions, vesting schedules, and any time-based payment streams.
;;
;; Built for the Bitcoin economy - leveraging Stacks' unique position as
;; the programmable Bitcoin layer to bring streaming finance to the world's
;; most secure and decentralized monetary network.
;;
;; Key Features:
;; - Trustless streaming payments with mathematical precision
;; - Bitcoin-level security through Stacks consensus
;; - Dual-signature stream modifications for enhanced security
;; - Real-time balance calculations based on block progression
;; - Efficient refueling and withdrawal mechanisms

;; ERROR CODES
;; Comprehensive error handling for robust contract interactions

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INVALID_SIGNATURE (err u101))
(define-constant ERR_STREAM_STILL_ACTIVE (err u102))
(define-constant ERR_INVALID_STREAM_ID (err u103))
(define-constant ERR_INSUFFICIENT_BALANCE (err u104))
(define-constant ERR_INVALID_TIMEFRAME (err u105))

;; DATA STORAGE

;; Global stream counter - tracks the next available stream ID
(define-data-var latest-stream-id uint u0)

;; Core stream data structure - the heart of our streaming protocol
;; Each stream represents a continuous payment flow from sender to recipient
(define-map streams
  uint ;; Unique stream identifier
  {
    sender: principal, ;; The party funding the stream
    recipient: principal, ;; The party receiving the stream
    balance: uint, ;; Total STX locked in the stream
    withdrawn-balance: uint, ;; STX already withdrawn by recipient
    payment-per-block: uint, ;; STX amount streamed per Stacks block
    timeframe: {
      ;; Stream duration boundaries
      start-block: uint, ;; Block when streaming begins
      stop-block: uint, ;; Block when streaming ends
    },
  }
)

;; CORE STREAMING FUNCTIONS

;; Create a new streaming payment channel
;; This function establishes a continuous payment flow that automatically
;; distributes STX from sender to recipient based on block progression
(define-public (stream-to
    (recipient principal)
    (initial-balance uint)
    (timeframe {
      start-block: uint,
      stop-block: uint,
    })
    (payment-per-block uint)
  )
  (let (
      ;; Construct the new stream object
      (stream {
        sender: contract-caller,
        recipient: recipient,
        balance: initial-balance,
        withdrawn-balance: u0,
        payment-per-block: payment-per-block,
        timeframe: timeframe,
      })
      (current-stream-id (var-get latest-stream-id))
    )
    ;; Validate timeframe logic
    (asserts! (< (get start-block timeframe) (get stop-block timeframe))
      ERR_INVALID_TIMEFRAME
    )

    ;; Lock STX tokens in the contract - this creates the funding pool
    (try! (stx-transfer? initial-balance contract-caller (as-contract tx-sender)))

    ;; Register the stream in our global registry
    (map-set streams current-stream-id stream)
    (var-set latest-stream-id (+ current-stream-id u1))

    ;; Return the unique stream ID for future reference
    (ok current-stream-id)
  )
)

;; Add additional STX to an existing stream
;; Enables dynamic stream extension and top-ups without creating new streams
(define-public (refuel
    (stream-id uint)
    (amount uint)
  )
  (let ((stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID)))
    ;; Only the original sender can add funds to maintain security
    (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)

    ;; Transfer additional STX to the contract
    (try! (stx-transfer? amount contract-caller (as-contract tx-sender)))

    ;; Update the stream balance atomically
    (map-set streams stream-id
      (merge stream { balance: (+ (get balance stream) amount) })
    )
    (ok amount)
  )
)

;; BALANCE CALCULATION ENGINE

;; Calculate elapsed blocks for accurate payment distribution
;; This is the mathematical core that ensures precise streaming calculations
(define-read-only (calculate-block-delta (timeframe {
  start-block: uint,
  stop-block: uint,
}))
  (let (
      (start-block (get start-block timeframe))
      (stop-block (get stop-block timeframe))
      ;; Smart block delta calculation based on current blockchain state
      (delta (if (<= stacks-block-height start-block)
        ;; Stream hasn't started yet
        u0
        (if (< stacks-block-height stop-block)
          ;; Stream is currently active
          (- stacks-block-height start-block)
          ;; Stream has completed
          (- stop-block start-block)
        )
      ))
    )
    delta
  )
)

;; Real-time balance calculation for any stream participant
;; Returns available balance for withdrawal or refund based on block progression
(define-read-only (balance-of
    (stream-id uint)
    (who principal)
  )
  (let (
      (stream (unwrap! (map-get? streams stream-id) u0))
      (block-delta (calculate-block-delta (get timeframe stream)))
      (total-streamed (* block-delta (get payment-per-block stream)))
    )
    (if (is-eq who (get recipient stream))
      ;; Recipient balance: total streamed minus already withdrawn
      (- total-streamed (get withdrawn-balance stream))
      (if (is-eq who (get sender stream))
        ;; Sender balance: locked funds minus total streamed
        (- (get balance stream) total-streamed)
        ;; Not a stream participant
        u0
      )
    )
  )
)

;; WITHDRAWAL & REFUND MECHANISMS

;; Recipient withdrawal function - claim your streamed STX
;; Enables recipients to withdraw their earned portion at any time
(define-public (withdraw (stream-id uint))
  (let (
      (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
      (available-balance (balance-of stream-id contract-caller))
    )
    ;; Only the designated recipient can withdraw
    (asserts! (is-eq contract-caller (get recipient stream)) ERR_UNAUTHORIZED)
    (asserts! (> available-balance u0) ERR_INSUFFICIENT_BALANCE)

    ;; Update withdrawal tracking to prevent double-spending
    (map-set streams stream-id
      (merge stream { withdrawn-balance: (+ (get withdrawn-balance stream) available-balance) })
    )

    ;; Execute the STX transfer to recipient
    (try! (as-contract (stx-transfer? available-balance tx-sender (get recipient stream))))
    (ok available-balance)
  )
)

;; Sender refund function - reclaim unstreamed STX after completion
;; Allows senders to recover unused funds once the stream timeframe ends
(define-public (refund (stream-id uint))
  (let (
      (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
      (refund-balance (balance-of stream-id (get sender stream)))
    )
    ;; Only the original sender can claim refunds
    (asserts! (is-eq contract-caller (get sender stream)) ERR_UNAUTHORIZED)

    ;; Stream must be completed before refunds are available
    (asserts! (>= stacks-block-height (get stop-block (get timeframe stream)))
      ERR_STREAM_STILL_ACTIVE
    )
    (asserts! (> refund-balance u0) ERR_INSUFFICIENT_BALANCE)

    ;; Update stream balance to reflect the refund
    (map-set streams stream-id
      (merge stream { balance: (- (get balance stream) refund-balance) })
    )

    ;; Transfer unused STX back to sender
    (try! (as-contract (stx-transfer? refund-balance tx-sender (get sender stream))))
    (ok refund-balance)
  )
)

;; CRYPTOGRAPHIC SECURITY LAYER

;; Generate deterministic hash for stream modification proposals
;; Creates tamper-proof message hashes for dual-signature verification
(define-read-only (hash-stream
    (stream-id uint)
    (new-payment-per-block uint)
    (new-timeframe {
      start-block: uint,
      stop-block: uint,
    })
  )
  (let (
      (stream (unwrap! (map-get? streams stream-id) (sha256 0x00)))
      ;; Concatenate all modification parameters for comprehensive hashing
      (message-buffer (concat
        (concat (unwrap-panic (to-consensus-buff? stream))
          (unwrap-panic (to-consensus-buff? new-payment-per-block))
        )
        (unwrap-panic (to-consensus-buff? new-timeframe))
      ))
    )
    (sha256 message-buffer)
  )
)

;; Cryptographic signature validation using secp256k1
;; Ensures both parties consent to stream modifications via Bitcoin-standard signatures
(define-read-only (validate-signature
    (message-hash (buff 32))
    (signature (buff 65))
    (expected-signer principal)
  )
  (is-eq
    (principal-of? (unwrap! (secp256k1-recover? message-hash signature) false))
    (ok expected-signer)
  )
)

;; STREAM MODIFICATION PROTOCOL

;; Update stream parameters with dual-party cryptographic consent
;; Enables secure modification of payment rates and timeframes when both
;; sender and recipient provide cryptographic proof of agreement
(define-public (update-stream-details
    (stream-id uint)
    (new-payment-per-block uint)
    (new-timeframe {
      start-block: uint,
      stop-block: uint,
    })
    (counterparty-signature (buff 65))
  )
  (let (
      (stream (unwrap! (map-get? streams stream-id) ERR_INVALID_STREAM_ID))
      (message-hash (hash-stream stream-id new-payment-per-block new-timeframe))
      ;; Determine who needs to sign based on who initiated the update
      (required-signer (if (is-eq contract-caller (get sender stream))
        (get recipient stream)
        (get sender stream)
      ))
    )
    ;; Verify the counterparty's cryptographic consent
    (asserts!
      (validate-signature message-hash counterparty-signature required-signer)
      ERR_INVALID_SIGNATURE
    )

    ;; Ensure caller is authorized (either sender or recipient)
    (asserts!
      (or
        (is-eq contract-caller (get sender stream))
        (is-eq contract-caller (get recipient stream))
      )
      ERR_UNAUTHORIZED
    )

    ;; Validate new timeframe logic
    (asserts! (< (get start-block new-timeframe) (get stop-block new-timeframe))
      ERR_INVALID_TIMEFRAME
    )

    ;; Apply the modifications atomically
    (map-set streams stream-id
      (merge stream {
        payment-per-block: new-payment-per-block,
        timeframe: new-timeframe,
      })
    )
    (ok true)
  )
)

;; UTILITY & QUERY FUNCTIONS

;; Retrieve complete stream information
;; Public read-only function for transparency and integration
(define-read-only (get-stream (stream-id uint))
  (map-get? streams stream-id)
)

;; Get the current global stream counter
;; Useful for frontend applications and analytics
(define-read-only (get-latest-stream-id)
  (var-get latest-stream-id)
)

;; Check if a stream is currently active based on block height
;; Essential for UI/UX and business logic implementations
(define-read-only (is-stream-active (stream-id uint))
  (match (map-get? streams stream-id)
    stream (let (
        (current-block stacks-block-height)
        (start (get start-block (get timeframe stream)))
        (stop (get stop-block (get timeframe stream)))
      )
      (and (>= current-block start) (< current-block stop))
    )
    false
  )
)

;; Calculate total STX that will be streamed over the entire duration
;; Helps with financial planning and stream analysis
(define-read-only (get-total-streaming-amount (stream-id uint))
  (match (map-get? streams stream-id)
    stream (let ((duration (- (get stop-block (get timeframe stream))
        (get start-block (get timeframe stream))
      )))
      (* duration (get payment-per-block stream))
    )
    u0
  )
)
