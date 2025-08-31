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