# Carbon Credit Staking NFT Contract
A Clarity smart contract for managing carbon credits through NFT representation and staking mechanisms on the Stacks blockchain.

## Features
NFT Minting: Mint NFTs representing staked carbon credits
Project Management: Track multiple carbon credit projects with details
Staking System: Stake carbon credits with minimum duration requirements
Status Management: NFTs can have different statuses:
-- Pending
-- Verified
-- Completed
-- Expired

### Core Functions

##### User Functions
stake-carbon: Stake carbon credits and receive an NFT
stake-multiple-carbon: Batch stake multiple carbon credits
unstake-carbon: Unstake carbon credits and burn the NFT
transfer: Transfer NFTs between users (only for verified/completed status)


#### Admin Functions
admin-update-status: Update NFT status
update-admin: Change contract administrator
update-project-info: Update project details


#### Read-Only Functions
get-nft-info: Get details of a staked NFT
get-user-nft-count: Get number of NFTs owned by user
get-staking-duration: Get staking duration in blocks
get-project-info: Get project details
can-transfer: Check if an NFT can be transferred


#### Technical Details
Minimum Staking Duration: 144 blocks (~1 day)
Maximum Batch Size: 10 NFTs per batch
Maximum User NFTs: 100 NFTs per user
SIP-009 Compliant: Implements standard NFT trait


#### Security Features
Contract pausability
Admin-only functions
Status validation
Transfer restrictions
Duration checks


#### Requirements
Stacks blockchain
Clarity-compatible wallet
Admin privileges for administrative functions


This contract is designed for the Stacks blockchain and requires proper deployment and configuration for production use.

