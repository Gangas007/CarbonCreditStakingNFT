;; Carbon Credit Staking NFT Contract
;; A comprehensive staking system for carbon credits with NFT representation

(define-non-fungible-token carbon-credit-nft uint)

;; Error constants
(define-constant ERR_NOT_FOUND (err u404))
(define-constant ERR_UNAUTHORIZED (err u403))
(define-constant ERR_ADMIN_ONLY (err u401))
(define-constant ERR_INVALID_TRANSFER (err u405))
(define-constant ERR_BATCH_LIMIT_EXCEEDED (err u406))
(define-constant ERR_EMPTY_BATCH (err u407))
(define-constant ERR_ALREADY_EXISTS (err u408))
(define-constant ERR_INVALID_DURATION (err u409))
(define-constant ERR_CONTRACT_PAUSED (err u410))

;; Constants
(define-constant MIN_STAKING_DURATION u144) ;; ~1 day in blocks (10 min blocks)
(define-constant MAX_BATCH_SIZE u10)
(define-constant MAX_USER_NFTS u100)

;; Contract state variables
(define-data-var next-nft-id uint u1)
(define-data-var admin principal tx-sender)
(define-data-var contract-paused bool false)

;; Data maps
(define-map staked-nfts
    uint
    {
        staker: principal,
        stake-block: uint,
        project-id: uint,
        status: (string-ascii 20),
        carbon-amount: uint,
    }
)

(define-map user-nft-count
    principal
    uint
)

(define-map user-nft-list
    {
        user: principal,
        index: uint,
    }
    uint
)

(define-map project-info
    uint
    {
        name: (string-ascii 50),
        location: (string-ascii 50),
        verification-standard: (string-ascii 30),
        total-staked: uint,
    }
)

;; Valid status list for validation
(define-constant VALID_STATUSES (list
    "pending                "     "verified              "
    "completed             "
    "expired               "
))
(define-constant TRANSFERABLE_STATUSES (list "verified              " "completed             "))

;; Private helper functions

(define-private (is-valid-status (status (string-ascii 20)))
    (is-some (index-of VALID_STATUSES status))
)

(define-private (is-transferable-status (status (string-ascii 20)))
    (is-some (index-of TRANSFERABLE_STATUSES status))
)

(define-private (add-nft-to-user
        (user principal)
        (nft-id uint)
    )
    (let ((current-count (default-to u0 (map-get? user-nft-count user))))
        (if (< current-count MAX_USER_NFTS)
            (begin
                (map-set user-nft-list {
                    user: user,
                    index: current-count,
                }
                    nft-id
                )
                (map-set user-nft-count user (+ current-count u1))
                (ok true)
            )
            (err u999) ;; Too many NFTs for user
        )
    )
)

(define-private (remove-nft-from-user
        (user principal)
        (nft-id uint)
    )
    (let ((user-count (default-to u0 (map-get? user-nft-count user))))
        (if (> user-count u0)
            (let ((new-count (- user-count u1)))
                ;; Find and remove the NFT (simplified approach)
                (map-delete user-nft-list {
                    user: user,
                    index: new-count,
                })
                (map-set user-nft-count user new-count)
                (ok true)
            )
            ERR_NOT_FOUND
        )
    )
)

(define-private (update-project-stats
        (project-id uint)
        (carbon-amount uint)
        (add bool)
    )
    (let ((current-info (map-get? project-info project-id)))
        (match current-info
            info
            (map-set project-info project-id
                (merge info { total-staked: (if add
                    (+ (get total-staked info) carbon-amount)
                    (if (>= (get total-staked info) carbon-amount)
                        (- (get total-staked info) carbon-amount)
                        u0
                    )
                ) }
                ))
            ;; If project doesn't exist, create it
            (if add
                (map-set project-info project-id {
                    name: "Unknown Project",
                    location: "Unknown",
                    verification-standard: "Unknown",
                    total-staked: carbon-amount,
                })
                false
            )
        )
    )
)

;; Public functions

(define-public (stake-carbon
        (project-id uint)
        (carbon-amount uint)
    )
    (let ((nft-id (var-get next-nft-id)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (> carbon-amount u0) (err u400))

        (try! (nft-mint? carbon-credit-nft nft-id tx-sender))

        (map-set staked-nfts nft-id {
            staker: tx-sender,
            stake-block: stacks-block-height,
            project-id: project-id,
            status: "pending",
            carbon-amount: carbon-amount,
        })

        (try! (add-nft-to-user tx-sender nft-id))
        (update-project-stats project-id carbon-amount true)
        (var-set next-nft-id (+ nft-id u1))

        (ok nft-id)
    )
)

(define-public (stake-multiple-carbon (stakes (list 10 {
    project-id: uint,
    carbon-amount: uint,
})))
    (let ((batch-size (len stakes)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (> batch-size u0) ERR_EMPTY_BATCH)
        (asserts! (<= batch-size MAX_BATCH_SIZE) ERR_BATCH_LIMIT_EXCEEDED)

        (fold stake-carbon-batch-helper stakes (ok (list u0)))
    )
)

(define-private (stake-carbon-batch-helper
        (stake-info {
            project-id: uint,
            carbon-amount: uint,
        })
        (acc-result (response (list 10 uint) uint))
    )
    (match acc-result
        acc-list (match (stake-carbon (get project-id stake-info) (get carbon-amount stake-info))
            success (match (as-max-len? (unwrap! (ok (append acc-list success)) (err u999)) u10)
                result (ok result)
                (err u999)
            )
            error (err error)
        )
        error (err error)
    )
)

(define-public (update-status
        (nft-id uint)
        (new-status (string-ascii 20))
    )
    (let ((nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts! (is-valid-status new-status) (err u400))

        (map-set staked-nfts nft-id (merge nft-info { status: new-status }))
        (ok true)
    )
)

(define-public (transfer
        (nft-id uint)
        (sender principal)
        (recipient principal)
    )
    (let ((nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts! (or (is-eq tx-sender sender) (is-eq tx-sender (var-get admin)))
            ERR_UNAUTHORIZED
        )
        (asserts!
            (>= (- stacks-block-height (get stake-block nft-info))
                MIN_STAKING_DURATION
            )
            ERR_INVALID_TRANSFER
        )
        (asserts! (is-transferable-status (get status nft-info))
            ERR_INVALID_TRANSFER
        )

        (try! (nft-transfer? carbon-credit-nft nft-id sender recipient))

        (map-set staked-nfts nft-id (merge nft-info { staker: recipient }))
        (try! (remove-nft-from-user sender nft-id))
        (try! (add-nft-to-user recipient nft-id))

        (ok true)
    )
)

(define-public (unstake-carbon (nft-id uint))
    (let ((nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts!
            (>= (- stacks-block-height (get stake-block nft-info))
                MIN_STAKING_DURATION
            )
            ERR_INVALID_DURATION
        )

        (try! (nft-burn? carbon-credit-nft nft-id (get staker nft-info)))
        (try! (remove-nft-from-user tx-sender nft-id))
        (update-project-stats (get project-id nft-info)
            (get carbon-amount nft-info) false
        )
        (map-delete staked-nfts nft-id)

        (ok true)
    )
)

;; Admin functions

(define-public (admin-update-status
        (nft-id uint)
        (new-status (string-ascii 20))
    )
    (let ((nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND)))
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)
        (asserts! (is-valid-status new-status) (err u400))

        (map-set staked-nfts nft-id (merge nft-info { status: new-status }))
        (ok true)
    )
)

(define-public (update-admin (new-admin principal))
    (begin
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)
        (ok (var-set admin new-admin))
    )
)

(define-public (update-project-info
        (project-id uint)
        (name (string-ascii 50))
        (location (string-ascii 50))
        (verification-standard (string-ascii 30))
    )
    (begin
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)
        (map-set project-info project-id {
            name: name,
            location: location,
            verification-standard: verification-standard,
            total-staked: (match (map-get? project-info project-id)
                existing-info (get total-staked existing-info)
                u0
            ),
        })
        (ok true)
    )
)

;; Read-only functions

(define-read-only (get-nft-info (nft-id uint))
    (map-get? staked-nfts nft-id)
)

(define-read-only (get-user-nft-count (user principal))
    (default-to u0 (map-get? user-nft-count user))
)

(define-read-only (get-user-nft-at-index
        (user principal)
        (index uint)
    )
    (map-get? user-nft-list {
        user: user,
        index: index,
    })
)

(define-read-only (get-staking-duration (nft-id uint))
    (match (map-get? staked-nfts nft-id)
        nft-info (ok (- stacks-block-height (get stake-block nft-info)))
        ERR_NOT_FOUND
    )
)

(define-read-only (get-staking-duration-days (nft-id uint))
    (match (get-staking-duration nft-id)
        duration (ok (/ duration u144))
        error (err error)
    )
)

(define-read-only (can-transfer (nft-id uint))
    (match (map-get? staked-nfts nft-id)
        nft_info (and
            (>= (- stacks-block-height (get stake-block nft_info))
                MIN_STAKING_DURATION
            )
            (is-transferable-status (get status nft_info))
        )
        false
    )
)

(define-read-only (get-project-info (project-id uint))
    (map-get? project-info project-id)
)

(define-read-only (get-total-nfts)
    (- (var-get next-nft-id) u1)
)

(define-read-only (get-admin)
    (var-get admin)
)

(define-read-only (is-contract-paused)
    (var-get contract-paused)
)

(define-read-only (get-nft-owner (nft-id uint))
    (nft-get-owner? carbon-credit-nft nft-id)
)

;; SIP-009 NFT trait implementation
(define-read-only (get-last-token-id)
    (ok (- (var-get next-nft-id) u1))
)

(define-read-only (get-token-uri (nft-id uint))
    (ok none)
)

(define-read-only (get-owner (nft-id uint))
    (ok (nft-get-owner? carbon-credit-nft nft-id))
)
