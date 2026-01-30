// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SasukaGame is ReentrancyGuard {
    // ──────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────

    enum Phase {
        Waiting,
        Committing,
        Revealing,
        Resolved,
        Finished
    }

    enum Action {
        None,
        Shield,
        Blizzard,
        Avalanche
    }

    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    struct Room {
        address[] players;
        uint256 stakeAmount;
        uint8 maxPlayers;
        Phase phase;
        uint8 tick;
        address winner;
        uint256 createdAt;
        uint256 phaseDeadline;
    }

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    uint256 public constant PROTOCOL_FEE_BPS = 300;
    uint256 public constant TICK_TIMEOUT = 60 seconds;
    uint8 public constant STARTING_HP = 100;

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    address public immutable treasury;
    uint256 public roomCounter;

    mapping(uint256 => Room) public rooms;

    // roomId => player => hp
    mapping(uint256 => mapping(address => uint8)) public hp;

    // roomId => tick => player => commitHash
    mapping(uint256 => mapping(uint8 => mapping(address => bytes32))) public commitHashes;

    // roomId => tick => player => revealedAction
    mapping(uint256 => mapping(uint8 => mapping(address => Action))) public revealedActions;

    // roomId => tick => player => hasCommitted
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) public hasCommitted;

    // roomId => tick => player => hasRevealed
    mapping(uint256 => mapping(uint8 => mapping(address => bool))) public hasRevealed;

    // roomId => player => isInRoom
    mapping(uint256 => mapping(address => bool)) public isInRoom;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event RoomCreated(
        uint256 indexed roomId,
        address creator,
        uint256 stakeAmount,
        uint8 maxPlayers
    );
    event PlayerJoined(uint256 indexed roomId, address player);
    event GameStarted(uint256 indexed roomId);
    event ActionCommitted(uint256 indexed roomId, address player, uint8 tick);
    event ActionRevealed(uint256 indexed roomId, address player, uint8 tick);
    event TickResolved(
        uint256 indexed roomId,
        uint8 tick,
        address[] eliminated
    );
    event GameWon(uint256 indexed roomId, address winner, uint256 prize);

    // ──────────────────────────────────────────────
    //  Custom Errors
    // ──────────────────────────────────────────────

    error InvalidStakeAmount();
    error InvalidMaxPlayers();
    error RoomNotWaiting();
    error StakeMismatch();
    error RoomFull();
    error AlreadyInRoom();
    error NotInRoom();
    error NotRoomCreator();
    error NotEnoughPlayers();
    error WrongPhase();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error InvalidAction();
    error HashMismatch();
    error PlayerEliminated();
    error NotAllRevealed();
    error NoWinnerYet();
    error NotWinner();
    error GameNotFinished();
    error TransferFailed();
    error TimeoutNotReached();

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(address _treasury) {
        treasury = _treasury;
    }

    // ──────────────────────────────────────────────
    //  External Functions
    // ──────────────────────────────────────────────

    function createRoom(
        uint256 stakeAmount,
        uint8 maxPlayers
    ) external payable returns (uint256 roomId) {
        if (stakeAmount == 0) revert InvalidStakeAmount();
        if (maxPlayers < 2 || maxPlayers > 10) revert InvalidMaxPlayers();
        if (msg.value != stakeAmount) revert StakeMismatch();

        roomId = roomCounter++;

        Room storage room = rooms[roomId];
        room.stakeAmount = stakeAmount;
        room.maxPlayers = maxPlayers;
        room.phase = Phase.Waiting;
        room.createdAt = block.timestamp;
        room.players.push(msg.sender);

        isInRoom[roomId][msg.sender] = true;
        hp[roomId][msg.sender] = STARTING_HP;

        emit RoomCreated(roomId, msg.sender, stakeAmount, maxPlayers);
        emit PlayerJoined(roomId, msg.sender);
    }

    function joinRoom(uint256 roomId) external payable {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Waiting) revert RoomNotWaiting();
        if (msg.value != room.stakeAmount) revert StakeMismatch();
        if (room.players.length >= room.maxPlayers) revert RoomFull();
        if (isInRoom[roomId][msg.sender]) revert AlreadyInRoom();

        room.players.push(msg.sender);
        isInRoom[roomId][msg.sender] = true;
        hp[roomId][msg.sender] = STARTING_HP;

        emit PlayerJoined(roomId, msg.sender);
    }

    function startGame(uint256 roomId) external {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Waiting) revert WrongPhase();
        if (room.players[0] != msg.sender) revert NotRoomCreator();
        if (room.players.length < 2) revert NotEnoughPlayers();

        room.phase = Phase.Committing;
        room.tick = 1;
        room.phaseDeadline = block.timestamp + TICK_TIMEOUT;

        emit GameStarted(roomId);
    }

    function commitAction(uint256 roomId, bytes32 hash) external {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Committing) revert WrongPhase();
        if (!isInRoom[roomId][msg.sender]) revert NotInRoom();
        if (hp[roomId][msg.sender] == 0) revert PlayerEliminated();
        if (hasCommitted[roomId][room.tick][msg.sender]) revert AlreadyCommitted();

        commitHashes[roomId][room.tick][msg.sender] = hash;
        hasCommitted[roomId][room.tick][msg.sender] = true;

        emit ActionCommitted(roomId, msg.sender, room.tick);

        // Auto-advance to Revealing if all alive players committed
        if (_allAliveCommitted(roomId)) {
            room.phase = Phase.Revealing;
            room.phaseDeadline = block.timestamp + TICK_TIMEOUT;
        }
    }

    function revealAction(
        uint256 roomId,
        uint8 action,
        bytes32 salt
    ) external {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Revealing) revert WrongPhase();
        if (!isInRoom[roomId][msg.sender]) revert NotInRoom();
        if (hp[roomId][msg.sender] == 0) revert PlayerEliminated();
        if (hasRevealed[roomId][room.tick][msg.sender]) revert AlreadyRevealed();
        if (action == 0 || action > 3) revert InvalidAction();

        bytes32 expected = keccak256(abi.encodePacked(action, salt));
        if (commitHashes[roomId][room.tick][msg.sender] != expected) {
            revert HashMismatch();
        }

        revealedActions[roomId][room.tick][msg.sender] = Action(action);
        hasRevealed[roomId][room.tick][msg.sender] = true;

        emit ActionRevealed(roomId, msg.sender, room.tick);
    }

    function resolveTick(uint256 roomId) external {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Revealing) revert WrongPhase();

        bool allRevealed = _allAliveRevealed(roomId);
        bool timedOut = block.timestamp >= room.phaseDeadline;

        if (!allRevealed && !timedOut) revert NotAllRevealed();

        uint8 currentTick = room.tick;
        address[] memory players = room.players;
        uint256 len = players.length;

        // Build arrays of alive players and their actions
        address[] memory alive = new address[](len);
        Action[] memory actions = new Action[](len);
        uint256 aliveCount;

        for (uint256 i; i < len; ++i) {
            if (hp[roomId][players[i]] > 0) {
                alive[aliveCount] = players[i];

                if (hasRevealed[roomId][currentTick][players[i]]) {
                    actions[aliveCount] = revealedActions[roomId][currentTick][players[i]];
                } else {
                    // Timed out without revealing: Action.None (takes max damage)
                    actions[aliveCount] = Action.None;
                }
                ++aliveCount;
            }
        }

        // Calculate damage for each alive player
        uint8[] memory damage = new uint8[](aliveCount);

        for (uint256 i; i < aliveCount; ++i) {
            if (actions[i] == Action.Shield) {
                // Shield users take 0 damage
                continue;
            }

            uint8 totalDmg;

            for (uint256 j; j < aliveCount; ++j) {
                if (i == j) continue;

                if (actions[i] == Action.None) {
                    // No action: takes damage from everything as if unshielded
                    if (actions[j] == Action.Blizzard) {
                        totalDmg += 10; // AoE hits everyone
                    } else if (actions[j] == Action.Avalanche) {
                        // Avalanche might target this player (handled below)
                    }
                } else if (actions[i] == Action.Blizzard) {
                    if (actions[j] == Action.Blizzard) {
                        totalDmg += 10;
                    } else if (actions[j] == Action.Avalanche) {
                        // Avalanche targets one non-shield enemy; check if i is the target
                        // Handled in avalanche targeting pass below
                    }
                } else if (actions[i] == Action.Avalanche) {
                    if (actions[j] == Action.Blizzard) {
                        totalDmg += 10; // AoE
                    } else if (actions[j] == Action.Avalanche) {
                        totalDmg += 30;
                    }
                }
            }

            damage[i] = totalDmg;
        }

        // Avalanche targeting pass: each Avalanche user picks one non-shield enemy
        for (uint256 i; i < aliveCount; ++i) {
            if (actions[i] != Action.Avalanche) continue;

            // Build list of targetable enemies (non-shield, alive, not self)
            uint256[] memory targets = new uint256[](aliveCount);
            uint256 targetCount;

            for (uint256 j; j < aliveCount; ++j) {
                if (j == i) continue;
                if (actions[j] == Action.Shield) continue;
                targets[targetCount++] = j;
            }

            if (targetCount == 0) continue;

            // Pseudo-random target selection (blockhash-based, acceptable for hackathon)
            uint256 seed = uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        roomId,
                        currentTick,
                        i
                    )
                )
            );
            uint256 targetIdx = targets[seed % targetCount];

            // Apply avalanche damage to the target
            if (actions[targetIdx] == Action.Blizzard) {
                damage[targetIdx] += 20;
            } else if (actions[targetIdx] == Action.Avalanche) {
                // Already counted 30 in the pairwise pass above (symmetric),
                // so no extra damage here to avoid double-counting
            } else {
                // Action.None
                damage[targetIdx] += 40;
            }
        }

        // Apply damage and track eliminations
        address[] memory eliminated = new address[](aliveCount);
        uint256 elimCount;

        for (uint256 i; i < aliveCount; ++i) {
            if (damage[i] > 0) {
                uint8 currentHp = hp[roomId][alive[i]];
                if (damage[i] >= currentHp) {
                    hp[roomId][alive[i]] = 0;
                    eliminated[elimCount++] = alive[i];
                } else {
                    hp[roomId][alive[i]] = currentHp - damage[i];
                }
            }
        }

        // Trim eliminated array
        address[] memory trimmedEliminated = new address[](elimCount);
        for (uint256 i; i < elimCount; ++i) {
            trimmedEliminated[i] = eliminated[i];
        }

        emit TickResolved(roomId, currentTick, trimmedEliminated);

        // Count remaining alive players
        uint256 remaining;
        address lastAlive;

        for (uint256 i; i < len; ++i) {
            if (hp[roomId][players[i]] > 0) {
                ++remaining;
                lastAlive = players[i];
            }
        }

        if (remaining <= 1) {
            room.phase = Phase.Finished;
            if (remaining == 1) {
                room.winner = lastAlive;
            }
            // If remaining == 0, all died simultaneously; no winner, funds stay in contract
            // (could add refund logic but keeping simple for hackathon)
        } else {
            room.tick = currentTick + 1;
            room.phase = Phase.Committing;
            room.phaseDeadline = block.timestamp + TICK_TIMEOUT;
        }
    }

    function claimWin(uint256 roomId) external nonReentrant {
        Room storage room = rooms[roomId];

        if (room.phase != Phase.Finished) revert GameNotFinished();
        if (room.winner != msg.sender) revert NotWinner();

        uint256 pot = room.stakeAmount * room.players.length;
        uint256 fee = (pot * PROTOCOL_FEE_BPS) / 10_000;
        uint256 prize = pot - fee;

        // Clear winner to prevent re-entrancy / double claim
        room.winner = address(0);

        (bool sentFee, ) = treasury.call{value: fee}("");
        if (!sentFee) revert TransferFailed();

        (bool sentPrize, ) = msg.sender.call{value: prize}("");
        if (!sentPrize) revert TransferFailed();

        emit GameWon(roomId, msg.sender, prize);
    }

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    struct RoomView {
        uint256 id;
        address creator;
        uint256 stakeAmount;
        uint8 maxPlayers;
        uint8 phase;
        uint8 tick;
        address winner;
        uint8 playerCount;
        address[] players;
        uint8[] hps;
        bool[] isAlive;
    }

    function getRoom(uint256 roomId) external view returns (RoomView memory) {
        Room storage room = rooms[roomId];
        uint256 len = room.players.length;

        uint8[] memory hps = new uint8[](len);
        bool[] memory alive = new bool[](len);

        for (uint256 i; i < len; ++i) {
            hps[i] = hp[roomId][room.players[i]];
            alive[i] = hps[i] > 0 || room.phase == Phase.Waiting;
        }

        return RoomView({
            id: roomId,
            creator: len > 0 ? room.players[0] : address(0),
            stakeAmount: room.stakeAmount,
            maxPlayers: room.maxPlayers,
            phase: uint8(room.phase),
            tick: room.tick,
            winner: room.winner,
            playerCount: uint8(len),
            players: room.players,
            hps: hps,
            isAlive: alive
        });
    }

    function getRoomCount() external view returns (uint256) {
        return roomCounter;
    }

    function getPlayerCommitted(uint256 roomId, address player) external view returns (bool) {
        return hasCommitted[roomId][rooms[roomId].tick][player];
    }

    function getPlayerRevealed(uint256 roomId, address player) external view returns (bool) {
        return hasRevealed[roomId][rooms[roomId].tick][player];
    }

    function getRoomPlayers(
        uint256 roomId
    ) external view returns (address[] memory) {
        return rooms[roomId].players;
    }

    function getPlayerHp(
        uint256 roomId,
        address player
    ) external view returns (uint8) {
        return hp[roomId][player];
    }

    function getAliveCount(uint256 roomId) external view returns (uint256) {
        address[] memory players = rooms[roomId].players;
        uint256 count;
        for (uint256 i; i < players.length; ++i) {
            if (hp[roomId][players[i]] > 0) ++count;
        }
        return count;
    }

    function getRoomInfo(
        uint256 roomId
    )
        external
        view
        returns (
            address[] memory players,
            uint256 stakeAmount,
            uint8 maxPlayers,
            Phase phase,
            uint8 tick,
            address winner,
            uint256 createdAt,
            uint256 phaseDeadline
        )
    {
        Room storage room = rooms[roomId];
        return (
            room.players,
            room.stakeAmount,
            room.maxPlayers,
            room.phase,
            room.tick,
            room.winner,
            room.createdAt,
            room.phaseDeadline
        );
    }

    // ──────────────────────────────────────────────
    //  Internal Helpers
    // ──────────────────────────────────────────────

    function _allAliveCommitted(uint256 roomId) internal view returns (bool) {
        Room storage room = rooms[roomId];
        address[] memory players = room.players;
        uint8 currentTick = room.tick;

        for (uint256 i; i < players.length; ++i) {
            if (hp[roomId][players[i]] > 0) {
                if (!hasCommitted[roomId][currentTick][players[i]]) {
                    return false;
                }
            }
        }
        return true;
    }

    function _allAliveRevealed(uint256 roomId) internal view returns (bool) {
        Room storage room = rooms[roomId];
        address[] memory players = room.players;
        uint8 currentTick = room.tick;

        for (uint256 i; i < players.length; ++i) {
            if (hp[roomId][players[i]] > 0) {
                if (!hasRevealed[roomId][currentTick][players[i]]) {
                    return false;
                }
            }
        }
        return true;
    }
}
