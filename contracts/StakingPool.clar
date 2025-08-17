;; Carbon Credit Staking NFT Contract
;; A comprehensive staking system for carbon credits with NFT representation

(define-non-fungible-token carbon-credit-nft uint)
(define-fungible-token reward-token)

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
(define-constant ERR_INSUFFICIENT_FUNDS (err u411))
(define-constant ERR_INVALID_PRICE (err u412))
(define-constant ERR_NOT_FOR_SALE (err u413))
(define-constant ERR_INVALID_BID (err u414))
(define-constant ERR_AUCTION_ENDED (err u415))
(define-constant ERR_AUCTION_ACTIVE (err u416))
(define-constant ERR_INVALID_VERIFICATION (err u417))

;; Constants
(define-constant MIN_STAKING_DURATION u144) ;; ~1 day in blocks (10 min blocks)
(define-constant MAX_BATCH_SIZE u10)
(define-constant MAX_USER_NFTS u100)
(define-constant REWARD_RATE u10) ;; 10 reward tokens per 1000 carbon units per day
(define-constant LOYALTY_MULTIPLIER u2) ;; 2x rewards after 1 year
(define-constant MILESTONE_BLOCKS u52560) ;; ~1 year in blocks
(define-constant AUCTION_DURATION u1440) ;; ~10 days in blocks

;; Contract state variables
(define-data-var next-nft-id uint u1)
(define-data-var admin principal tx-sender)
(define-data-var contract-paused bool false)
(define-data-var next-auction-id uint u1)

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

;; Reward system maps
(define-map user-rewards
    principal
    {
        total-earned: uint,
        last-claim-block: uint,
        loyalty-points: uint,
        referral-count: uint,
    }
)

(define-map reward-claims
    {
        user: principal,
        nft-id: uint,
    }
    uint ;; last claim block
)

;; Marketplace maps
(define-map nft-listings
    uint
    {
        seller: principal,
        price: uint,
        listed-block: uint,
        active: bool,
    }
)

(define-map auctions
    uint
    {
        nft-id: uint,
        seller: principal,
        start-price: uint,
        current-bid: uint,
        highest-bidder: (optional principal),
        start-block: uint,
        end-block: uint,
        active: bool,
    }
)

(define-map auction-bids
    {
        auction-id: uint,
        bidder: principal,
    }
    uint ;; bid amount
)

;; Environmental verification maps
(define-map verification-data
    uint ;; project-id
    {
        satellite-verified: bool,
        iot-verified: bool,
        third-party-audited: bool,
        verification-score: uint,
        last-verification-block: uint,
        verification-source: (string-ascii 50),
    }
)

(define-map oracle-data
    {
        project-id: uint,
        data-type: (string-ascii 20),
    }
    {
        value: uint,
        timestamp: uint,
        verified: bool,
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

;; ========================================
;; REWARD SYSTEM FUNCTIONS
;; ========================================

(define-private (calculate-rewards (nft-id uint))
    (match (map-get? staked-nfts nft-id)
        nft-info (let (
                (duration (- stacks-block-height (get stake-block nft-info)))
                (carbon-amount (get carbon-amount nft-info))
                (days-staked (/ duration u144))
                (base-reward (/ (* carbon-amount REWARD_RATE days-staked) u1000))
                (is-loyalty (>= duration MILESTONE_BLOCKS))
            )
            (if is-loyalty
                (* base-reward LOYALTY_MULTIPLIER)
                base-reward
            )
        )
        u0
    )
)

(define-public (claim-rewards (nft-id uint))
    (let (
            (nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND))
            (last-claim (default-to u0
                (map-get? reward-claims {
                    user: tx-sender,
                    nft-id: nft-id,
                })
            ))
            (reward-amount (calculate-rewards nft-id))
        )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts! (> reward-amount u0) (err u400))
        (asserts! (> stacks-block-height (+ last-claim u144)) (err u400))
        ;; 1 day cooldown

        (try! (ft-mint? reward-token reward-amount tx-sender))

        (map-set reward-claims {
            user: tx-sender,
            nft-id: nft-id,
        }
            stacks-block-height
        )

        (let ((current-rewards (default-to {
                total-earned: u0,
                last-claim-block: u0,
                loyalty-points: u0,
                referral-count: u0,
            }
                (map-get? user-rewards tx-sender)
            )))
            (map-set user-rewards tx-sender
                (merge current-rewards {
                    total-earned: (+ (get total-earned current-rewards) reward-amount),
                    last-claim-block: stacks-block-height,
                    loyalty-points: (+ (get loyalty-points current-rewards) (/ reward-amount u10)),
                })
            )
        )

        (ok reward-amount)
    )
)

(define-public (add-referral (referrer principal))
    (let ((referrer-rewards (default-to {
            total-earned: u0,
            last-claim-block: u0,
            loyalty-points: u0,
            referral-count: u0,
        }
            (map-get? user-rewards referrer)
        )))
        (asserts! (not (is-eq tx-sender referrer)) (err u400))

        (map-set user-rewards referrer
            (merge referrer-rewards {
                referral-count: (+ (get referral-count referrer-rewards) u1),
                loyalty-points: (+ (get loyalty-points referrer-rewards) u100),
            })
        )

        (try! (ft-mint? reward-token u50 referrer))
        ;; Referral bonus
        (ok true)
    )
)

;; ========================================
;; MARKETPLACE FUNCTIONS
;; ========================================

(define-public (list-nft-for-sale
        (nft-id uint)
        (price uint)
    )
    (let ((nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts! (> price u0) ERR_INVALID_PRICE)
        (asserts! (can-transfer nft-id) ERR_INVALID_TRANSFER)

        (map-set nft-listings nft-id {
            seller: tx-sender,
            price: price,
            listed-block: stacks-block-height,
            active: true,
        })

        (ok true)
    )
)

(define-public (buy-nft (nft-id uint))
    (let (
            (listing (unwrap! (map-get? nft-listings nft-id) ERR_NOT_FOR_SALE))
            (nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND))
        )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (get active listing) ERR_NOT_FOR_SALE)
        (asserts! (not (is-eq tx-sender (get seller listing))) ERR_UNAUTHORIZED)

        (try! (stx-transfer? (get price listing) tx-sender (get seller listing)))
        (try! (transfer nft-id (get seller listing) tx-sender))

        (map-set nft-listings nft-id (merge listing { active: false }))

        (ok true)
    )
)

(define-public (cancel-listing (nft-id uint))
    (let ((listing (unwrap! (map-get? nft-listings nft-id) ERR_NOT_FOR_SALE)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get seller listing)) ERR_UNAUTHORIZED)
        (asserts! (get active listing) ERR_NOT_FOR_SALE)

        (map-set nft-listings nft-id (merge listing { active: false }))
        (ok true)
    )
)

(define-public (create-auction
        (nft-id uint)
        (start-price uint)
    )
    (let (
            (nft-info (unwrap! (map-get? staked-nfts nft-id) ERR_NOT_FOUND))
            (auction-id (var-get next-auction-id))
        )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender (get staker nft-info)) ERR_UNAUTHORIZED)
        (asserts! (> start-price u0) ERR_INVALID_PRICE)
        (asserts! (can-transfer nft-id) ERR_INVALID_TRANSFER)

        (map-set auctions auction-id {
            nft-id: nft-id,
            seller: tx-sender,
            start-price: start-price,
            current-bid: start-price,
            highest-bidder: none,
            start-block: stacks-block-height,
            end-block: (+ stacks-block-height AUCTION_DURATION),
            active: true,
        })

        (var-set next-auction-id (+ auction-id u1))
        (ok auction-id)
    )
)

(define-public (place-bid
        (auction-id uint)
        (bid-amount uint)
    )
    (let ((auction (unwrap! (map-get? auctions auction-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (get active auction) ERR_AUCTION_ENDED)
        (asserts! (< stacks-block-height (get end-block auction))
            ERR_AUCTION_ENDED
        )
        (asserts! (> bid-amount (get current-bid auction)) ERR_INVALID_BID)
        (asserts! (not (is-eq tx-sender (get seller auction))) ERR_UNAUTHORIZED)

        ;; Refund previous highest bidder
        (match (get highest-bidder auction)
            previous-bidder (try! (stx-transfer? (get current-bid auction) (as-contract tx-sender)
                previous-bidder
            ))
            true
        )

        ;; Hold new bid in escrow
        (try! (stx-transfer? bid-amount tx-sender (as-contract tx-sender)))

        (map-set auctions auction-id
            (merge auction {
                current-bid: bid-amount,
                highest-bidder: (some tx-sender),
            })
        )

        (map-set auction-bids {
            auction-id: auction-id,
            bidder: tx-sender,
        }
            bid-amount
        )
        (ok true)
    )
)

(define-public (finalize-auction (auction-id uint))
    (let ((auction (unwrap! (map-get? auctions auction-id) ERR_NOT_FOUND)))
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (get active auction) ERR_AUCTION_ENDED)
        (asserts! (>= stacks-block-height (get end-block auction))
            ERR_AUCTION_ACTIVE
        )

        (match (get highest-bidder auction)
            winner
            (begin
                (try! (stx-transfer? (get current-bid auction) (as-contract tx-sender)
                    (get seller auction)
                ))
                (try! (transfer (get nft-id auction) (get seller auction) winner))
            )
            ;; No bids, return NFT to seller
            true
        )

        (map-set auctions auction-id (merge auction { active: false }))
        (ok true)
    )
)

;; ========================================
;; ENVIRONMENTAL VERIFICATION FUNCTIONS
;; ========================================

(define-public (submit-verification-data
        (project-id uint)
        (satellite-verified bool)
        (iot-verified bool)
        (third-party-audited bool)
        (verification-source (string-ascii 50))
    )
    (begin
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)

        (let ((verification-score (+
                (if satellite-verified
                    u30
                    u0
                )
                (if iot-verified
                    u30
                    u0
                )
                (if third-party-audited
                    u40
                    u0
                ))))
            (map-set verification-data project-id {
                satellite-verified: satellite-verified,
                iot-verified: iot-verified,
                third-party-audited: third-party-audited,
                verification-score: verification-score,
                last-verification-block: stacks-block-height,
                verification-source: verification-source,
            })
        )

        (ok true)
    )
)

(define-public (submit-oracle-data
        (project-id uint)
        (data-type (string-ascii 20))
        (value uint)
    )
    (begin
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)

        (map-set oracle-data {
            project-id: project-id,
            data-type: data-type,
        } {
            value: value,
            timestamp: stacks-block-height,
            verified: true,
        })

        (ok true)
    )
)

(define-public (verify-project-impact (project-id uint))
    (let ((verification (map-get? verification-data project-id)))
        (asserts! (is-eq tx-sender (var-get admin)) ERR_ADMIN_ONLY)

        (match verification
            data (if (>= (get verification-score data) u70)
                (ok true)
                ERR_INVALID_VERIFICATION
            )
            ERR_NOT_FOUND
        )
    )
)

;; ========================================
;; ORIGINAL PUBLIC FUNCTIONS
;; ========================================

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

;; ========================================
;; READ-ONLY FUNCTIONS
;; ========================================

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

;; New read-only functions for enhanced features

(define-read-only (get-user-rewards (user principal))
    (map-get? user-rewards user)
)

(define-read-only (get-pending-rewards (nft-id uint))
    (ok (calculate-rewards nft-id))
)

(define-read-only (get-nft-listing (nft-id uint))
    (map-get? nft-listings nft-id)
)

(define-read-only (get-auction-info (auction-id uint))
    (map-get? auctions auction-id)
)

(define-read-only (get-verification-data (project-id uint))
    (map-get? verification-data project-id)
)

(define-read-only (get-oracle-data
        (project-id uint)
        (data-type (string-ascii 20))
    )
    (map-get? oracle-data {
        project-id: project-id,
        data-type: data-type,
    })
)

(define-read-only (is-auction-active (auction-id uint))
    (match (map-get? auctions auction-id)
        auction (and (get active auction) (< stacks-block-height (get end-block auction)))
        false
    )
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
