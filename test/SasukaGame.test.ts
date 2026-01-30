import { expect } from "chai";
import { ethers } from "hardhat";
import {
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";

const Action = {
  Shield: 1,
  Blizzard: 2,
  Avalanche: 3,
} as const;

const Phase = {
  Waiting: 0,
  Committing: 1,
  Revealing: 2,
  Resolved: 3,
  Finished: 4,
} as const;

const STAKE = ethers.parseEther("1");
const FEE_BPS = 300;

function computeCommitHash(action: number, salt: string): string {
  return ethers.solidityPackedKeccak256(
    ["uint8", "bytes32"],
    [action, salt]
  );
}

function randomSalt(): string {
  return ethers.hexlify(ethers.randomBytes(32));
}

describe("SasukaGame", function () {
  async function deployFixture() {
    const [owner, player1, player2, player3] = await ethers.getSigners();

    const Treasury = await ethers.getContractFactory("SasukaTreasury");
    const treasury = await Treasury.deploy(owner.address);
    await treasury.waitForDeployment();

    const Game = await ethers.getContractFactory("SasukaGame");
    const game = await Game.deploy(await treasury.getAddress());
    await game.waitForDeployment();

    return { game, treasury, owner, player1, player2, player3 };
  }

  async function startedGameFixture() {
    const base = await deployFixture();
    const { game, player1, player2 } = base;

    await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });
    await game.connect(player2).joinRoom(0, { value: STAKE });
    await game.connect(player1).startGame(0);

    return base;
  }

  describe("Room Creation", function () {
    it("should create a room with correct stake and emit event", async function () {
      const { game, player1 } = await loadFixture(deployFixture);

      await expect(
        game.connect(player1).createRoom(STAKE, 2, { value: STAKE })
      ).to.emit(game, "RoomCreated");
    });

    it("should revert if msg.value does not match stake amount", async function () {
      const { game, player1 } = await loadFixture(deployFixture);

      await expect(
        game.connect(player1).createRoom(STAKE, 2, {
          value: ethers.parseEther("0.5"),
        })
      ).to.be.reverted;
    });
  });

  describe("Joining a Room", function () {
    it("should allow a second player to join", async function () {
      const { game, player1, player2 } = await loadFixture(deployFixture);

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });

      await expect(
        game.connect(player2).joinRoom(0, { value: STAKE })
      ).to.emit(game, "PlayerJoined");
    });

    it("should revert when joining with wrong stake", async function () {
      const { game, player1, player2 } = await loadFixture(deployFixture);

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });

      await expect(
        game.connect(player2).joinRoom(0, {
          value: ethers.parseEther("0.5"),
        })
      ).to.be.reverted;
    });

    it("should revert when room is full", async function () {
      const { game, player1, player2, player3 } =
        await loadFixture(deployFixture);

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });
      await game.connect(player2).joinRoom(0, { value: STAKE });

      await expect(
        game.connect(player3).joinRoom(0, { value: STAKE })
      ).to.be.reverted;
    });
  });

  describe("Starting a Game", function () {
    it("should allow starting when enough players", async function () {
      const { game, player1, player2 } = await loadFixture(deployFixture);

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });
      await game.connect(player2).joinRoom(0, { value: STAKE });

      await expect(game.connect(player1).startGame(0)).to.emit(
        game,
        "GameStarted"
      );
    });

    it("should revert if not enough players", async function () {
      const { game, player1 } = await loadFixture(deployFixture);

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });

      await expect(game.connect(player1).startGame(0)).to.be.reverted;
    });
  });

  describe("Commit-Reveal Flow", function () {
    it("should accept a valid commit", async function () {
      const { game, player1 } = await loadFixture(startedGameFixture);

      const salt = randomSalt();
      const hash = computeCommitHash(Action.Blizzard, salt);

      await expect(
        game.connect(player1).commitAction(0, hash)
      ).to.emit(game, "ActionCommitted");
    });

    it("should accept a valid reveal matching the commit", async function () {
      const { game, player1, player2 } = await loadFixture(startedGameFixture);

      const salt1 = randomSalt();
      const salt2 = randomSalt();

      await game.connect(player1).commitAction(0, computeCommitHash(Action.Blizzard, salt1));
      await game.connect(player2).commitAction(0, computeCommitHash(Action.Shield, salt2));

      await expect(
        game.connect(player1).revealAction(0, Action.Blizzard, salt1)
      ).to.emit(game, "ActionRevealed");

      await expect(
        game.connect(player2).revealAction(0, Action.Shield, salt2)
      ).to.emit(game, "ActionRevealed");
    });

    it("should revert reveal with wrong action (hash mismatch)", async function () {
      const { game, player1, player2 } = await loadFixture(startedGameFixture);

      const salt1 = randomSalt();
      const salt2 = randomSalt();

      await game.connect(player1).commitAction(0, computeCommitHash(Action.Blizzard, salt1));
      await game.connect(player2).commitAction(0, computeCommitHash(Action.Shield, salt2));

      await expect(
        game.connect(player1).revealAction(0, Action.Avalanche, salt1)
      ).to.be.reverted;
    });

    it("should revert reveal with wrong salt", async function () {
      const { game, player1, player2 } = await loadFixture(startedGameFixture);

      const salt1 = randomSalt();
      const salt2 = randomSalt();
      const wrongSalt = randomSalt();

      await game.connect(player1).commitAction(0, computeCommitHash(Action.Blizzard, salt1));
      await game.connect(player2).commitAction(0, computeCommitHash(Action.Shield, salt2));

      await expect(
        game.connect(player1).revealAction(0, Action.Blizzard, wrongSalt)
      ).to.be.reverted;
    });
  });

  describe("Tick Resolution", function () {
    it("should resolve a tick after both players reveal", async function () {
      const { game, player1, player2 } = await loadFixture(startedGameFixture);

      const salt1 = randomSalt();
      const salt2 = randomSalt();

      await game.connect(player1).commitAction(0, computeCommitHash(Action.Avalanche, salt1));
      await game.connect(player2).commitAction(0, computeCommitHash(Action.Shield, salt2));

      await game.connect(player1).revealAction(0, Action.Avalanche, salt1);
      await game.connect(player2).revealAction(0, Action.Shield, salt2);

      await expect(game.resolveTick(0)).to.emit(game, "TickResolved");
    });
  });

  describe("Full Game Flow", function () {
    it("should complete a game and let winner claim prize with 3% fee", async function () {
      const { game, treasury, player1, player2 } =
        await loadFixture(deployFixture);

      const treasuryAddr = await treasury.getAddress();

      await game.connect(player1).createRoom(STAKE, 2, { value: STAKE });
      await game.connect(player2).joinRoom(0, { value: STAKE });
      await game.connect(player1).startGame(0);

      const totalPot = STAKE * 2n;
      const expectedFee = (totalPot * BigInt(FEE_BPS)) / 10000n;
      const expectedPrize = totalPot - expectedFee;

      // Strategy: P1 uses Avalanche, P2 uses Blizzard
      // Per tick: P1 takes 10 (blizzard AoE), P2 takes 20 (avalanche targets blizzard user)
      // After 5 ticks: P1=50, P2=0 -> P2 eliminated, P1 wins
      const MAX_TICKS = 20;

      for (let tick = 0; tick < MAX_TICKS; tick++) {
        const s1 = randomSalt();
        const s2 = randomSalt();

        await game.connect(player1).commitAction(0, computeCommitHash(Action.Avalanche, s1));
        await game.connect(player2).commitAction(0, computeCommitHash(Action.Blizzard, s2));

        await game.connect(player1).revealAction(0, Action.Avalanche, s1);
        await game.connect(player2).revealAction(0, Action.Blizzard, s2);

        await game.resolveTick(0);

        // Check if game is finished by reading room info
        const roomInfo = await game.getRoomInfo(0);
        const phase = Number(roomInfo.phase);
        if (phase === Phase.Finished) {
          break;
        }
      }

      // Verify game is finished
      const finalRoom = await game.getRoomInfo(0);
      expect(Number(finalRoom.phase)).to.equal(Phase.Finished);

      // Winner (player1) claims prize
      const balanceBefore = await ethers.provider.getBalance(player1.address);

      const claimTx = await game.connect(player1).claimWin(0);
      const claimReceipt = await claimTx.wait();
      const gasUsed = claimReceipt!.gasUsed * claimReceipt!.gasPrice;

      const balanceAfter = await ethers.provider.getBalance(player1.address);

      expect(balanceAfter - balanceBefore + gasUsed).to.equal(expectedPrize);

      // Treasury received the 3% fee
      const treasuryBalance = await ethers.provider.getBalance(treasuryAddr);
      expect(treasuryBalance).to.equal(expectedFee);
    });
  });
});
