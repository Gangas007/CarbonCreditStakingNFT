import { describe, expect, it, beforeEach } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;
const wallet2 = accounts.get("wallet_2")!;

describe("Carbon Credit Staking NFT Contract", () => {
  beforeEach(() => {
    // Reset simnet state before each test
    simnet.setEpoch("3.0");
  });

  describe("Basic Staking Functionality", () => {
    it("should allow users to stake carbon credits", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
      
      expect(result).toBeOk(simnet.types.uint(1));
    });

    it("should track NFT information correctly", () => {
      // First stake a carbon credit
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );

      // Check NFT info
      const { result } = simnet.callReadOnlyFn(
        "StakingPool",
        "get-nft-info",
        [simnet.types.uint(1)],
        wallet1
      );

      expect(result).toBeSome();
      const nftInfo = result.expectSome().expectTuple();
      expect(nftInfo.staker).toBeStandardPrincipal(wallet1);
      expect(nftInfo["project-id"]).toBeUint(1);
      expect(nftInfo["carbon-amount"]).toBeUint(100);
      expect(nftInfo.status).toBeAscii("pending");
    });

    it("should increment NFT IDs correctly", () => {
      // Stake first NFT
      const result1 = simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
      expect(result1.result).toBeOk(simnet.types.uint(1));

      // Stake second NFT
      const result2 = simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(2), simnet.types.uint(200)],
        wallet1
      );
      expect(result2.result).toBeOk(simnet.types.uint(2));
    });

    it("should reject staking with zero carbon amount", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(0)],
        wallet1
      );
      
      expect(result).toBeErr(simnet.types.uint(400));
    });
  });

  describe("Batch Staking", () => {
    it("should allow batch staking of multiple carbon credits", () => {
      const stakes = simnet.types.list([
        simnet.types.tuple({
          "project-id": simnet.types.uint(1),
          "carbon-amount": simnet.types.uint(100)
        }),
        simnet.types.tuple({
          "project-id": simnet.types.uint(2),
          "carbon-amount": simnet.types.uint(200)
        })
      ]);

      const { result } = simnet.callPublicFn(
        "StakingPool",
        "stake-multiple-carbon",
        [stakes],
        wallet1
      );

      expect(result).toBeOk();
      const nftIds = result.expectOk().expectList();
      expect(nftIds).toHaveLength(2);
    });

    it("should reject empty batch staking", () => {
      const emptyStakes = simnet.types.list([]);

      const { result } = simnet.callPublicFn(
        "StakingPool",
        "stake-multiple-carbon",
        [emptyStakes],
        wallet1
      );

      expect(result).toBeErr(simnet.types.uint(407)); // ERR_EMPTY_BATCH
    });

    it("should reject batch staking exceeding limit", () => {
      // Create a list with 11 items (exceeds MAX_BATCH_SIZE of 10)
      const stakes = Array.from({ length: 11 }, (_, i) =>
        simnet.types.tuple({
          "project-id": simnet.types.uint(i + 1),
          "carbon-amount": simnet.types.uint(100)
        })
      );

      const { result } = simnet.callPublicFn(
        "StakingPool",
        "stake-multiple-carbon",
        [simnet.types.list(stakes)],
        wallet1
      );

      expect(result).toBeErr(simnet.types.uint(406)); // ERR_BATCH_LIMIT_EXCEEDED
    });
  });

  describe("Status Management", () => {
    beforeEach(() => {
      // Stake an NFT for testing
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
    });

    it("should allow users to update their NFT status", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "update-status",
        [simnet.types.uint(1), simnet.types.ascii("verified")],
        wallet1
      );

      expect(result).toBeOk(simnet.types.bool(true));

      // Verify status was updated
      const nftInfo = simnet.callReadOnlyFn(
        "StakingPool",
        "get-nft-info",
        [simnet.types.uint(1)],
        wallet1
      );
      
      const info = nftInfo.result.expectSome().expectTuple();
      expect(info.status).toBeAscii("verified");
    });

    it("should reject unauthorized status updates", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "update-status",
        [simnet.types.uint(1), simnet.types.ascii("verified")],
        wallet2 // Different user
      );

      expect(result).toBeErr(simnet.types.uint(403)); // ERR_UNAUTHORIZED
    });

    it("should allow admin to update any NFT status", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "admin-update-status",
        [simnet.types.uint(1), simnet.types.ascii("completed")],
        deployer // Admin
      );

      expect(result).toBeOk(simnet.types.bool(true));
    });
  });

  describe("Transfer Functionality", () => {
    beforeEach(() => {
      // Stake and verify an NFT
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
      
      simnet.callPublicFn(
        "StakingPool",
        "update-status",
        [simnet.types.uint(1), simnet.types.ascii("verified")],
        wallet1
      );
    });

    it("should prevent transfer before minimum staking duration", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "transfer",
        [simnet.types.uint(1), simnet.types.principal(wallet1), simnet.types.principal(wallet2)],
        wallet1
      );

      expect(result).toBeErr(simnet.types.uint(405)); // ERR_INVALID_TRANSFER
    });

    it("should allow transfer after minimum duration with correct status", () => {
      // Mine blocks to meet minimum duration (144 blocks)
      simnet.mineEmptyBlocks(150);

      const { result } = simnet.callPublicFn(
        "StakingPool",
        "transfer",
        [simnet.types.uint(1), simnet.types.principal(wallet1), simnet.types.principal(wallet2)],
        wallet1
      );

      expect(result).toBeOk(simnet.types.bool(true));

      // Verify ownership changed
      const owner = simnet.callReadOnlyFn(
        "StakingPool",
        "get-nft-owner",
        [simnet.types.uint(1)],
        wallet1
      );
      
      expect(owner.result).toBeSome(simnet.types.principal(wallet2));
    });

    it("should check transfer eligibility correctly", () => {
      // Before minimum duration
      let canTransfer = simnet.callReadOnlyFn(
        "StakingPool",
        "can-transfer",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(canTransfer.result).toBeBool(false);

      // After minimum duration
      simnet.mineEmptyBlocks(150);
      canTransfer = simnet.callReadOnlyFn(
        "StakingPool",
        "can-transfer",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(canTransfer.result).toBeBool(true);
    });
  });

  describe("Unstaking Functionality", () => {
    beforeEach(() => {
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
    });

    it("should prevent unstaking before minimum duration", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "unstake-carbon",
        [simnet.types.uint(1)],
        wallet1
      );

      expect(result).toBeErr(simnet.types.uint(409)); // ERR_INVALID_DURATION
    });

    it("should allow unstaking after minimum duration", () => {
      simnet.mineEmptyBlocks(150);

      const { result } = simnet.callPublicFn(
        "StakingPool",
        "unstake-carbon",
        [simnet.types.uint(1)],
        wallet1
      );

      expect(result).toBeOk(simnet.types.bool(true));

      // Verify NFT no longer exists
      const nftInfo = simnet.callReadOnlyFn(
        "StakingPool",
        "get-nft-info",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(nftInfo.result).toBeNone();
    });
  });

  describe("Admin Functions", () => {
    it("should allow admin to set project information", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "set-project-info",
        [
          simnet.types.uint(1),
          simnet.types.ascii("Forest Conservation"),
          simnet.types.ascii("Amazon Rainforest"),
          simnet.types.ascii("VCS")
        ],
        deployer
      );

      expect(result).toBeOk(simnet.types.bool(true));

      // Verify project info was set
      const projectInfo = simnet.callReadOnlyFn(
        "StakingPool",
        "get-project-info",
        [simnet.types.uint(1)],
        deployer
      );

      const info = projectInfo.result.expectSome().expectTuple();
      expect(info.name).toBeAscii("Forest Conservation");
      expect(info.location).toBeAscii("Amazon Rainforest");
      expect(info["verification-standard"]).toBeAscii("VCS");
    });

    it("should allow admin to pause and unpause contract", () => {
      // Pause contract
      let result = simnet.callPublicFn(
        "StakingPool",
        "pause-contract",
        [],
        deployer
      );
      expect(result.result).toBeOk(simnet.types.bool(true));

      // Verify contract is paused
      let isPaused = simnet.callReadOnlyFn(
        "StakingPool",
        "is-contract-paused",
        [],
        deployer
      );
      expect(isPaused.result).toBeBool(true);

      // Try to stake while paused (should fail)
      result = simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
      expect(result.result).toBeErr(simnet.types.uint(410)); // ERR_CONTRACT_PAUSED

      // Unpause contract
      result = simnet.callPublicFn(
        "StakingPool",
        "unpause-contract",
        [],
        deployer
      );
      expect(result.result).toBeOk(simnet.types.bool(true));

      // Verify contract is unpaused
      isPaused = simnet.callReadOnlyFn(
        "StakingPool",
        "is-contract-paused",
        [],
        deployer
      );
      expect(isPaused.result).toBeBool(false);
    });

    it("should allow admin transfer", () => {
      const { result } = simnet.callPublicFn(
        "StakingPool",
        "set-admin",
        [simnet.types.principal(wallet1)],
        deployer
      );

      expect(result).toBeOk(simnet.types.bool(true));

      // Verify new admin
      const admin = simnet.callReadOnlyFn(
        "StakingPool",
        "get-admin",
        [],
        wallet1
      );
      expect(admin.result).toBeStandardPrincipal(wallet1);
    });
  });

  describe("Read-only Functions", () => {
    beforeEach(() => {
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
    });

    it("should calculate staking duration correctly", () => {
      const initialDuration = simnet.callReadOnlyFn(
        "StakingPool",
        "get-staking-duration",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(initialDuration.result).toBeOk(simnet.types.uint(0));

      // Mine some blocks
      simnet.mineEmptyBlocks(10);

      const laterDuration = simnet.callReadOnlyFn(
        "StakingPool",
        "get-staking-duration",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(laterDuration.result).toBeOk(simnet.types.uint(10));
    });

    it("should calculate staking duration in days", () => {
      simnet.mineEmptyBlocks(288); // 2 days worth of blocks

      const durationDays = simnet.callReadOnlyFn(
        "StakingPool",
        "get-staking-duration-days",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(durationDays.result).toBeOk(simnet.types.uint(2));
    });

    it("should track user NFT count", () => {
      const count = simnet.callReadOnlyFn(
        "StakingPool",
        "get-user-nft-count",
        [simnet.types.principal(wallet1)],
        wallet1
      );
      expect(count.result).toBeUint(1);

      // Stake another NFT
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(2), simnet.types.uint(200)],
        wallet1
      );

      const newCount = simnet.callReadOnlyFn(
        "StakingPool",
        "get-user-nft-count",
        [simnet.types.principal(wallet1)],
        wallet1
      );
      expect(newCount.result).toBeUint(2);
    });

    it("should return total NFTs count", () => {
      const total = simnet.callReadOnlyFn(
        "StakingPool",
        "get-total-nfts",
        [],
        wallet1
      );
      expect(total.result).toBeUint(1);
    });
  });

  describe("SIP-009 Compliance", () => {
    beforeEach(() => {
      simnet.callPublicFn(
        "StakingPool",
        "stake-carbon",
        [simnet.types.uint(1), simnet.types.uint(100)],
        wallet1
      );
    });

    it("should return last token ID", () => {
      const { result } = simnet.callReadOnlyFn(
        "StakingPool",
        "get-last-token-id",
        [],
        wallet1
      );
      expect(result).toBeOk(simnet.types.uint(1));
    });

    it("should return token URI", () => {
      const { result } = simnet.callReadOnlyFn(
        "StakingPool",
        "get-token-uri",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(result).toBeOk(simnet.types.none());
    });

    it("should return token owner", () => {
      const { result } = simnet.callReadOnlyFn(
        "StakingPool",
        "get-owner",
        [simnet.types.uint(1)],
        wallet1
      );
      expect(result).toBeOk(simnet.types.some(simnet.types.principal(wallet1)));
    });
  });
});