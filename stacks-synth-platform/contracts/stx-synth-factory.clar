;; SatSynth: Satoshi-Backed Synthetic Assets Protocol
;; A decentralized financial platform enabling creation of synthetic assets 
;; collateralized by Bitcoin through Stacks blockchain

;; Error constants
(define-constant contract-admin tx-sender)
(define-constant ERR-ADMIN-ONLY (err u100))
(define-constant ERR-COLLATERAL-BELOW-THRESHOLD (err u101))
(define-constant ERR-MINT-AMOUNT-TOO-SMALL (err u102))
(define-constant ERR-MINT-AMOUNT-TOO-LARGE (err u103))
(define-constant ERR-ASSET-NOT-SUPPORTED (err u104))
(define-constant ERR-COLLATERAL-RATIO-UNSAFE (err u105))
(define-constant ERR-POSITION-NOT-FOUND (err u106))
(define-constant ERR-USER-NOT-AUTHORIZED (err u107))
(define-constant ERR-PRICE-DATA-EXPIRED (err u108))
(define-constant ERR-TOKEN-TRANSFER-FAILED (err u109))
(define-constant ERR-POSITION-STILL-ACTIVE (err u110))
(define-constant ERR-FEE-OUT-OF-RANGE (err u111))
(define-constant ERR-NOT-GOVERNANCE-MEMBER (err u112))
(define-constant ERR-NOT-AUTHORIZED-ORACLE (err u113))
(define-constant ERR-PROTOCOL-PAUSED (err u114))
(define-constant ERR-WITHIN-COOLDOWN-PERIOD (err u115))
(define-constant ERR-INVALID-PRINCIPAL (err u116))
(define-constant ERR-INVALID-PARAMETER (err u117))
(define-constant ERR-INVALID-ASSET-SYMBOL (err u118))

;; Protocol safety parameters
(define-constant minimum-collateral-ratio u150) ;; 150% minimum collateralization
(define-constant minimum-mint-value u100000000) ;; 1 STX minimum
(define-constant maximum-mint-value u10000000000000) ;; 100,000 STX maximum
(define-constant price-validity-duration u144) ;; ~24 hours in blocks (10-min blocks)

;; Fee structure (in basis points - 100 = 1%)
(define-data-var synthetic-creation-fee uint u50) ;; 0.5% fee on minting
(define-data-var synthetic-redemption-fee uint u25) ;; 0.25% fee on redemption
(define-data-var position-liquidation-penalty uint u500) ;; 5% penalty on liquidation

;; Protocol accounting
(define-data-var treasury-balance-accumulated uint u0)

;; Emergency controls
(define-data-var system-emergency-paused bool false)

;; Time restrictions
(define-data-var withdrawal-timelock-blocks uint u10) ;; ~100 minutes

;; Governance structure
(define-map dao-members
  { member-address: principal }
  { can-modify-parameters: bool }
)

;; Oracle network members
(define-map authorized-data-providers
  { provider-address: principal }
  { can-update-price-feeds: bool }
)

;; Supported synthetic asset registry
(define-map registered-synthetic-assets
  { asset-symbol: (string-ascii 10) }
  { 
    is-active-for-trading: bool,
    decimal-precision: uint
  }
)

;; Price oracle data
(define-map asset-market-prices
  { asset-symbol: (string-ascii 10) }
  {
    current-price: uint,
    updated-at-block: uint,
    provider-identity: principal
  }
)

;; Individual user collateralized positions
(define-map user-synthetic-positions
  { user-address: principal, asset-symbol: (string-ascii 10) }
  {
    collateral-amount-locked: uint,
    synthetic-tokens-issued: uint,
    position-open-block: uint,
    last-activity-block: uint
  }
)

;; Protocol-wide asset statistics
(define-map global-asset-metrics
  { asset-symbol: (string-ascii 10) }
  {
    total-collateral-locked: uint,
    total-synthetic-issued: uint
  }
)

;; Validation functions
(define-read-only (is-valid-principal (address principal))
  (not (is-eq address contract-admin))
)

(define-read-only (is-valid-asset-symbol (asset-symbol (string-ascii 10)))
  (is-some (map-get? registered-synthetic-assets { asset-symbol: asset-symbol }))
)

;; GOVERNANCE FUNCTIONS
;; Register a new governance member
(define-public (add-dao-member (member principal))
  (begin
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    ;; Validate member principal
    (asserts! (is-valid-principal member) ERR-INVALID-PRINCIPAL)
    
    (map-set dao-members
      { member-address: member }
      { can-modify-parameters: true }
    )
    (ok true)
  )
)

;; Remove governance privileges
(define-public (remove-dao-member (member principal))
  (begin
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    ;; Validate member principal
    (asserts! (is-valid-principal member) ERR-INVALID-PRINCIPAL)
    
    (map-delete dao-members { member-address: member })
    (ok true)
  )
)

;; Register a new price oracle
(define-public (register-price-provider (provider principal))
  (begin
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    ;; Validate provider principal
    (asserts! (is-valid-principal provider) ERR-INVALID-PRINCIPAL)
    
    (map-set authorized-data-providers
      { provider-address: provider }
      { can-update-price-feeds: true }
    )
    (ok true)
  )
)

;; Remove oracle privileges
(define-public (deactivate-price-provider (provider principal))
  (begin
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    ;; Validate provider principal
    (asserts! (is-valid-principal provider) ERR-INVALID-PRINCIPAL)
    
    (map-delete authorized-data-providers { provider-address: provider })
    (ok true)
  )
)

;; Emergency protocol pause
(define-public (set-emergency-pause (paused bool))
  (begin
    (asserts! (has-governance-authority) ERR-NOT-GOVERNANCE-MEMBER)
    (var-set system-emergency-paused paused)
    (ok paused)
  )
)

;; Modify protocol fee structure
(define-public (update-fee-structure 
    (new-creation-fee uint) 
    (new-redemption-fee uint) 
    (new-liquidation-penalty uint))
  (begin
    (asserts! (has-governance-authority) ERR-NOT-GOVERNANCE-MEMBER)
    ;; Validate fee parameters are within acceptable ranges
    (asserts! (and (<= new-creation-fee u500) (<= new-redemption-fee u500)) ERR-FEE-OUT-OF-RANGE)
    (asserts! (<= new-liquidation-penalty u1000) ERR-FEE-OUT-OF-RANGE)
    
    (var-set synthetic-creation-fee new-creation-fee)
    (var-set synthetic-redemption-fee new-redemption-fee)
    (var-set position-liquidation-penalty new-liquidation-penalty)
    (ok true)
  )
)

;; Modify time restriction parameters
(define-public (update-timelock-duration (new-timelock-blocks uint))
  (begin
    (asserts! (has-governance-authority) ERR-NOT-GOVERNANCE-MEMBER)
    ;; Validate timelock parameter
    (asserts! (> new-timelock-blocks u0) ERR-INVALID-PARAMETER)
    (asserts! (< new-timelock-blocks u1000) ERR-INVALID-PARAMETER)
    
    (var-set withdrawal-timelock-blocks new-timelock-blocks)
    (ok true)
  )
)

;; Protocol revenue distribution
(define-public (withdraw-treasury-funds (recipient principal))
  (let
    (
      (treasury-amount (var-get treasury-balance-accumulated))
    )
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    (asserts! (> treasury-amount u0) ERR-COLLATERAL-BELOW-THRESHOLD)
    ;; Validate recipient principal
    (asserts! (is-valid-principal recipient) ERR-INVALID-PRINCIPAL)
    
    ;; Reset accumulated revenue
    (var-set treasury-balance-accumulated u0)
    
    ;; Transfer revenue to designated recipient
    (try! (as-contract (stx-transfer? treasury-amount (as-contract tx-sender) recipient)))
    
    (ok treasury-amount)
  )
)

;; ASSET MANAGEMENT
;; Add support for a new synthetic asset
(define-public (register-new-asset (asset-symbol (string-ascii 10)) (decimal-precision uint))
  (begin
    (asserts! (is-eq tx-sender contract-admin) ERR-ADMIN-ONLY)
    ;; Validate asset symbol and decimal precision
    (asserts! (not (is-valid-asset-symbol asset-symbol)) ERR-ASSET-NOT-SUPPORTED) ;; Asset shouldn't already exist
    (asserts! (and (>= decimal-precision u1) (<= decimal-precision u18)) ERR-INVALID-PARAMETER)
    
    (map-set registered-synthetic-assets
      { asset-symbol: asset-symbol }
      {
        is-active-for-trading: true,
        decimal-precision: decimal-precision
      }
    )
    (map-set global-asset-metrics
      { asset-symbol: asset-symbol }
      {
        total-collateral-locked: u0,
        total-synthetic-issued: u0
      }
    )
    (ok true)
  )
)

;; Oracle price update function
(define-public (submit-price-update (asset-symbol (string-ascii 10)) (new-price uint))
  (let
    (
      (asset-data (unwrap! (get-registered-asset-info asset-symbol) ERR-ASSET-NOT-SUPPORTED))
      (existing-price-data (default-to 
                            { current-price: u0, updated-at-block: u0, provider-identity: contract-admin }
                            (map-get? asset-market-prices { asset-symbol: asset-symbol })))
    )
    ;; Verify oracle authorization
    (asserts! (has-oracle-authority) ERR-NOT-AUTHORIZED-ORACLE)
    (asserts! (is-eq (get is-active-for-trading asset-data) true) ERR-ASSET-NOT-SUPPORTED)
    ;; Validate price
    (asserts! (> new-price u0) ERR-INVALID-PARAMETER)
    
    ;; Record updated price information
    (map-set asset-market-prices
      { asset-symbol: asset-symbol }
      {
        current-price: new-price,
        updated-at-block: block-height,
        provider-identity: tx-sender
      }
    )
    
    (ok new-price)
  )
)

;; CORE USER FUNCTIONS
;; Fee calculation helper
(define-read-only (compute-fee-amount (amount uint) (fee-rate uint))
  (/ (* amount fee-rate) u10000)
)

;; Create new synthetic position
(define-public (mint-synthetic-asset 
    (asset-symbol (string-ascii 10)) 
    (collateral-amount uint) 
    (synthetic-amount uint))
  (let
    (
      (asset-data (unwrap! (get-registered-asset-info asset-symbol) ERR-ASSET-NOT-SUPPORTED))
      (price-info (unwrap! (get-verified-price asset-symbol) ERR-ASSET-NOT-SUPPORTED))
      (market-price (get current-price price-info))
    )
    ;; Protocol safety checks
    (asserts! (not (var-get system-emergency-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (>= synthetic-amount minimum-mint-value) ERR-MINT-AMOUNT-TOO-SMALL)
    (asserts! (<= synthetic-amount maximum-mint-value) ERR-MINT-AMOUNT-TOO-LARGE)
    (asserts! (is-eq (get is-active-for-trading asset-data) true) ERR-ASSET-NOT-SUPPORTED)
    (asserts! (> collateral-amount u0) ERR-COLLATERAL-BELOW-THRESHOLD)
    
    (let
      (
        (protocol-fee (compute-fee-amount collateral-amount (var-get synthetic-creation-fee)))
        (effective-collateral (- collateral-amount protocol-fee))
        (collateral-value (* effective-collateral u100000000))
        (synthetic-value (* synthetic-amount market-price))
        (health-ratio (/ (* collateral-value u100) synthetic-value))
        (position-key { user-address: tx-sender, asset-symbol: asset-symbol })
        (metrics-key { asset-symbol: asset-symbol })
        (global-metrics (default-to { total-collateral-locked: u0, total-synthetic-issued: u0 } 
                       (map-get? global-asset-metrics metrics-key)))
        (existing-position (map-get? user-synthetic-positions position-key))
      )
      ;; Additional safety check
      (asserts! (>= health-ratio minimum-collateral-ratio) ERR-COLLATERAL-BELOW-THRESHOLD)
      
      ;; Transfer collateral to contract
      (try! (stx-transfer? collateral-amount tx-sender (as-contract tx-sender)))
      
      ;; Record protocol revenue - safe because protocol-fee is derived from validated collateral-amount
      (var-set treasury-balance-accumulated (+ (var-get treasury-balance-accumulated) protocol-fee))
      
      ;; Process position creation or update
      (match existing-position
        existing-pos ;; Add to existing position
        (let
          (
            (new-collateral (+ (get collateral-amount-locked existing-pos) effective-collateral))
            (new-synthetic (+ (get synthetic-tokens-issued existing-pos) synthetic-amount))
          )
          (map-set user-synthetic-positions
            position-key
            {
              collateral-amount-locked: new-collateral,
              synthetic-tokens-issued: new-synthetic,
              position-open-block: (get position-open-block existing-pos),
              last-activity-block: block-height
            }
          )
        )
        ;; Create new position record
        (map-set user-synthetic-positions
          position-key
          {
            collateral-amount-locked: effective-collateral,
            synthetic-tokens-issued: synthetic-amount,
            position-open-block: block-height,
            last-activity-block: block-height
          }
        )
      )
      
      ;; Update global statistics - safe because effective-collateral is derived from validated collateral-amount
      (map-set global-asset-metrics
        metrics-key
        {
          total-collateral-locked: (+ (get total-collateral-locked global-metrics) effective-collateral),
          total-synthetic-issued: (+ (get total-synthetic-issued global-metrics) synthetic-amount)
        }
      )
      
      (ok synthetic-amount)
    )
  )
)

;; Add collateral to existing position
(define-public (add-position-collateral (asset-symbol (string-ascii 10)) (additional-amount uint))
  (let
    (
      (position-key { user-address: tx-sender, asset-symbol: asset-symbol })
      (current-position (unwrap! (map-get? user-synthetic-positions position-key) ERR-POSITION-NOT-FOUND))
      (metrics-key { asset-symbol: asset-symbol })
      (global-metrics (default-to { total-collateral-locked: u0, total-synthetic-issued: u0 }
                      (map-get? global-asset-metrics metrics-key)))
    )
    ;; Check protocol status and validate input
    (asserts! (not (var-get system-emergency-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> additional-amount u0) ERR-INVALID-PARAMETER)
    
    (let
      (
        (updated-collateral (+ (get collateral-amount-locked current-position) additional-amount))
      )
      ;; Transfer additional collateral
      (try! (stx-transfer? additional-amount tx-sender (as-contract tx-sender)))
      
      ;; Update position data - safe because updated-collateral is derived from validated additional-amount
      (map-set user-synthetic-positions
        position-key
        {
          collateral-amount-locked: updated-collateral,
          synthetic-tokens-issued: (get synthetic-tokens-issued current-position),
          position-open-block: (get position-open-block current-position),
          last-activity-block: block-height
        }
      )
      
      ;; Update protocol statistics - safe because additional-amount is validated
      (map-set global-asset-metrics
        metrics-key
        {
          total-collateral-locked: (+ (get total-collateral-locked global-metrics) additional-amount),
          total-synthetic-issued: (get total-synthetic-issued global-metrics)
        }
      )
      
      (ok updated-collateral)
    )
  )
)

;; Redeem synthetic assets for collateral
(define-public (redeem-position (asset-symbol (string-ascii 10)) (synthetic-amount uint))
  (let
    (
      (position-key { user-address: tx-sender, asset-symbol: asset-symbol })
      (current-position (unwrap! (map-get? user-synthetic-positions position-key) ERR-POSITION-NOT-FOUND))
      (metrics-key { asset-symbol: asset-symbol })
      (global-metrics (default-to { total-collateral-locked: u0, total-synthetic-issued: u0 }
                      (map-get? global-asset-metrics metrics-key)))
      (position-total-synthetic (get synthetic-tokens-issued current-position))
      (position-total-collateral (get collateral-amount-locked current-position))
      (last-activity (get last-activity-block current-position))
      (blocks-since-update (- block-height last-activity))
    )
    ;; Check protocol status and requirements
    (asserts! (not (var-get system-emergency-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (>= blocks-since-update (var-get withdrawal-timelock-blocks)) ERR-WITHIN-COOLDOWN-PERIOD)
    (asserts! (<= synthetic-amount position-total-synthetic) ERR-COLLATERAL-BELOW-THRESHOLD)
    (asserts! (> synthetic-amount u0) ERR-INVALID-PARAMETER)
    
    ;; Calculate proportional collateral for redemption
    (let
      (
        (redemption-ratio (/ (* synthetic-amount u100000000) position-total-synthetic))
        (collateral-share (/ (* position-total-collateral redemption-ratio) u100000000))
        (redemption-fee (compute-fee-amount collateral-share (var-get synthetic-redemption-fee)))
        (net-collateral (- collateral-share redemption-fee))
        (remaining-synthetic (- position-total-synthetic synthetic-amount))
        (remaining-collateral (- position-total-collateral collateral-share))
      )
      ;; Record protocol revenue
      (var-set treasury-balance-accumulated (+ (var-get treasury-balance-accumulated) redemption-fee))
      
      ;; Process position update or close
      (if (is-eq remaining-synthetic u0)
        (begin
          ;; Close position completely
          (map-delete user-synthetic-positions position-key)
          
          ;; Update protocol statistics
          (map-set global-asset-metrics
            metrics-key
            {
              total-collateral-locked: (- (get total-collateral-locked global-metrics) position-total-collateral),
              total-synthetic-issued: (- (get total-synthetic-issued global-metrics) position-total-synthetic)
            }
          )
        )
        (begin
          ;; Update position with remaining balances
          (map-set user-synthetic-positions
            position-key
            {
              collateral-amount-locked: remaining-collateral,
              synthetic-tokens-issued: remaining-synthetic,
              position-open-block: (get position-open-block current-position),
              last-activity-block: block-height
            }
          )
          
          ;; Update protocol statistics
          (map-set global-asset-metrics
            metrics-key
            {
              total-collateral-locked: (- (get total-collateral-locked global-metrics) collateral-share),
              total-synthetic-issued: (- (get total-synthetic-issued global-metrics) synthetic-amount)
            }
          )
        )
      )
      
      ;; Transfer collateral to user
      (try! (as-contract (stx-transfer? net-collateral (as-contract tx-sender) tx-sender)))
      
      (ok {
        synthetic-amount-burned: synthetic-amount,
        collateral-returned: net-collateral,
        fee-paid: redemption-fee
      })
    )
  )
)

;; HELPER & READ-ONLY FUNCTIONS
;; Calculate health ratio of a position
(define-read-only (calculate-collateral-health-ratio (collateral-amount uint) (synthetic-amount uint) (asset-price uint))
  (let
    (
      (collateral-value (* collateral-amount u100000000))
      (synthetic-value (* synthetic-amount asset-price))
    )
    (/ (* collateral-value u100) synthetic-value)
  )
)

;; Authorization check helpers
(define-read-only (has-governance-authority)
  (or 
    (is-eq tx-sender contract-admin)
    (is-some (map-get? dao-members { member-address: tx-sender }))
  )
)

(define-read-only (has-oracle-authority)
  (or 
    (is-eq tx-sender contract-admin)
    (is-some (map-get? authorized-data-providers { provider-address: tx-sender }))
  )
)

;; Get asset price safely with freshness check
(define-read-only (get-verified-price (asset-symbol (string-ascii 10)))
  (let
    (
      (price-data (unwrap! (map-get? asset-market-prices { asset-symbol: asset-symbol }) ERR-ASSET-NOT-SUPPORTED))
      (update-block (get updated-at-block price-data))
      (block-age (- block-height update-block))
    )
    ;; Verify price freshness
    (asserts! (< block-age price-validity-duration) ERR-PRICE-DATA-EXPIRED)
    
    (ok {
      current-price: (get current-price price-data),
      updated-at-block: update-block
    })
  )
)

;; PUBLIC ACCESS FUNCTIONS
;; Retrieve user position details
(define-read-only (get-position-details (owner principal) (asset-symbol (string-ascii 10)))
  (map-get? user-synthetic-positions { user-address: owner, asset-symbol: asset-symbol })
)

;; Get detailed position information
(define-read-only (get-user-position-status (owner principal) (asset-symbol (string-ascii 10)))
  (let
    (
      (position (unwrap! (map-get? user-synthetic-positions 
                         { user-address: owner, asset-symbol: asset-symbol }) 
                ERR-POSITION-NOT-FOUND))
    )
    (ok {
      collateral-amount-locked: (get collateral-amount-locked position),
      synthetic-tokens-issued: (get synthetic-tokens-issued position),
      position-open-block: (get position-open-block position),
      last-activity-block: (get last-activity-block position)
    })
  )
)

;; Public function to evaluate position health
(define-public (check-position-health (owner principal) (asset-symbol (string-ascii 10)))
  (let
    (
      (position (unwrap! (map-get? user-synthetic-positions 
                         { user-address: owner, asset-symbol: asset-symbol }) 
                ERR-POSITION-NOT-FOUND))
      (price-data (unwrap! (get-verified-price asset-symbol) ERR-ASSET-NOT-SUPPORTED))
      (market-price (get current-price price-data))
    )
    (ok (calculate-collateral-health-ratio 
          (get collateral-amount-locked position) 
          (get synthetic-tokens-issued position) 
          market-price))
  )
)

;; Get asset details
(define-read-only (get-registered-asset-info (asset-symbol (string-ascii 10)))
  (map-get? registered-synthetic-assets { asset-symbol: asset-symbol })
)

;; Get asset statistics
(define-read-only (get-asset-global-metrics (asset-symbol (string-ascii 10)))
  (map-get? global-asset-metrics { asset-symbol: asset-symbol })
)

;; Retrieve current price data
(define-read-only (get-raw-price-data (asset-symbol (string-ascii 10)))
  (map-get? asset-market-prices { asset-symbol: asset-symbol })
)

;; PROTOCOL INFORMATION FUNCTIONS
;; Get protocol revenue information
(define-read-only (get-treasury-balance)
  (var-get treasury-balance-accumulated)
)

;; Get current fee structure
(define-read-only (get-current-fees)
  {
    synthetic-creation-fee: (var-get synthetic-creation-fee),
    synthetic-redemption-fee: (var-get synthetic-redemption-fee),
    position-liquidation-penalty: (var-get position-liquidation-penalty)
  }
)

;; Get protocol configuration
(define-read-only (get-protocol-parameters)
  {
    emergency-pause-active: (var-get system-emergency-paused),
    minimum-collateral-ratio: minimum-collateral-ratio,
    withdrawal-timelock-blocks: (var-get withdrawal-timelock-blocks),
    price-validity-duration: price-validity-duration
  }
)