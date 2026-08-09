// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VRFConsumerBaseV2Plus
} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {
    IVRFCoordinatorV2Plus
} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {
    AutomationCompatibleInterface
} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title 链上周期开奖彩票
/// @notice 抽签制彩票：按双色球日程（锚定固定场次）售票，Chainlink VRF v2.5 开奖，
///         keeper 触发。奖池与运营抽成自购票时刻起分账（FR-C-20），
///         不存在任何能挪用奖池的管理员函数（FR-C-24）。
/// @dev 计价 token 必须是标准 ERC20：**不支持**转账扣费（fee-on-transfer）或
///      弹性供给（rebasing）代币——这两类会使名义记账与实际到账不符，
///      击穿「合约余额 >= 全部未领奖金」的偿付性不变量。
/// @dev owner 权限完整清单见 FR-C-22 说明：setTreasury / setFeeBps / setSalesPaused，
///      外加继承自 ConfirmedOwner 的 transferOwnership / acceptOwnership，
///      以及继承自 VRFConsumerBaseV2Plus 的 setCoordinator（无法 override 封禁，
///      但换源后回调会被 CoordinatorTampered 拒绝，只能造成可自行恢复的延迟，
///      无法操纵开奖或挪用资金）。
contract Lottery is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== 类型 =====

    enum RoundState {
        NONE,
        OPEN,
        DRAWING,
        SETTLED,
        VOIDED
    }

    /// @dev 一次购买产生的连续票号区间 [start, end)（FR-C-04）
    struct TicketRange {
        uint32 start;
        uint32 end;
        address owner;
    }

    struct Round {
        RoundState state;
        uint64 closeTime; // 停售时刻；开奖时刻 = closeTime + SEAL_GAP
        uint32 ticketCount;
        uint16 claimedBits; // 中奖 slot 领取位图（slot 总数 ≤ 16）
        bool expiredRolled; // 过期未领奖金是否已滚存
        uint64 drawRequestedAt;
        uint256 pot; // 本期可分配奖金（购票分账 + 注资 + 承接的过期滚存）
        uint256 tier1Carry; // 上期滚入、计入本期一等奖份额的金额（Q1 双色球逻辑）
        uint256 vrfRequestId;
        uint256 randomSeed;
    }

    // ===== 错误 =====
    // 注意：VRFConsumerBaseV2Plus 已声明 ZeroAddress()，此处不得重复声明

    error RoundNotOpen();
    error SalesClosed();
    error SalesArePaused();
    error InvalidQuantity();
    error ExceedsMaxPerTx();
    error ExceedsRoundCapacity();
    error TicketOutOfRange();
    error DrawNotDue();
    error RoundNotDrawing();
    error RetryTooEarly();
    error RoundNotSettled();
    error InvalidTier();
    error TierNotOpened();
    error ClaimWindowClosed();
    error ClaimWindowNotClosed();
    error NothingToClaim();
    error AlreadyRolledOver();
    error FeeTooHigh();
    error InvalidTreasury();
    error InvalidToken();
    error InvalidTicketPrice();
    error InvalidSchedule();
    error InvalidTierConfig();
    error NoFeesToWithdraw();
    error CoordinatorTampered();

    // ===== 事件（FR-C-25）=====

    event RoundOpened(uint32 indexed roundId, uint64 closeTime);
    event TicketsBought(
        uint32 indexed roundId, address indexed buyer, uint32 start, uint32 quantity
    );
    event PotInjected(uint32 indexed roundId, address indexed sender, uint256 amount);
    event DrawRequested(uint32 indexed roundId, uint256 indexed requestId);
    event WinnersPicked(uint32 indexed roundId, uint32[] winningTickets, address[] winners);
    event PrizeClaimed(uint32 indexed roundId, address indexed winner, uint8 tier, uint256 amount);
    event PrizeRolledOver(uint32 indexed fromRound, uint32 indexed toRound, uint256 amount);
    event RoundVoided(uint32 indexed roundId);
    event FeesWithdrawn(address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event FeeBpsUpdated(uint16 feeBps);
    event SalesPausedUpdated(bool paused);

    // ===== 常量 =====

    uint16 public constant MAX_FEE_BPS = 1000; // 10% 硬上限（FR-C-21）
    uint32 public constant MAX_TICKETS_PER_TX = 1000; // FR-C-06
    uint64 public constant SEAL_GAP = 75 minutes; // 停售→开奖间隔（FR-C-08，对应双色球 20:00→21:15）
    uint64 public constant DRAW_TIMEOUT = 3 hours; // FR-C-14
    uint64 public constant CLAIM_WINDOW = 90 days; // FR-C-19
    uint16 public constant BPS_DENOMINATOR = 10000;
    uint16 private constant VRF_CONFIRMATIONS = 3;
    uint32 private constant VRF_CALLBACK_GAS = 1_000_000;

    // ===== 不可变配置 =====

    IERC20 public immutable i_token; // FR-C-01
    uint256 public immutable i_ticketPrice;
    bytes32 public immutable i_keyHash;
    uint256 public immutable i_subId;
    /// @dev 构造时钉死的随机源。基类 VRFConsumerBaseV2Plus 暴露了 owner 可调且
    ///      非 virtual（无法 override）的 setCoordinator——若不钉死，owner 可把随机源
    ///      换成自控合约、离线挑选种子稳中头奖。请求只发往此地址，回调也只认此地址
    address private immutable i_coordinator;

    // ===== 存储 =====

    uint16[] private s_tierBps; // 各奖级比例，和为 10000（FR-C-13）
    uint8[] private s_tierWinnerCounts; // 各奖级名额

    uint32[] private s_intervals; // 场次间隔循环（如 [2d, 3d, 2d]）
    uint64 private s_lastSlotTime; // 最近一个已使用的场次时间
    uint32 private s_intervalCursor; // 下一个间隔的索引

    uint32 public s_currentRound;
    mapping(uint32 roundId => Round) private s_rounds;
    mapping(uint32 roundId => TicketRange[]) private s_ranges;
    mapping(uint32 roundId => mapping(uint8 tier => uint256)) private s_perWinnerAmount;
    mapping(uint256 requestId => uint32 roundId) private s_requestToRound;

    address public s_treasury;
    uint16 public s_feeBps;
    uint256 public s_accruedFees; // 与奖池分账的运营抽成（FR-C-20）
    bool public s_salesPaused;

    // ===== 构造 =====

    /// @param vrfCoordinator VRF v2.5 coordinator 地址
    /// @param subId VRF 订阅 ID
    /// @param keyHash VRF gas lane
    /// @param token 计价 ERC20（默认 USDC，精度不做假设）
    /// @param ticketPrice 票价（token 最小单位）
    /// @param anchorTime 日程锚点（如某个周二 12:00 UTC）
    /// @param intervals 场次间隔循环（秒），如 [2 days, 3 days, 2 days]
    /// @param treasury 运营抽成接收地址
    /// @param feeBps 抽成比例（默认 100 = 1%，上限 1000）
    /// @param tierBps 各奖级占奖池比例，和必须为 10000
    /// @param tierWinnerCounts 各奖级名额
    constructor(
        address vrfCoordinator,
        uint256 subId,
        bytes32 keyHash,
        address token,
        uint256 ticketPrice,
        uint64 anchorTime,
        uint32[] memory intervals,
        address treasury,
        uint16 feeBps,
        uint16[] memory tierBps,
        uint8[] memory tierWinnerCounts
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        if (token == address(0)) revert InvalidToken();
        if (ticketPrice == 0) revert InvalidTicketPrice();
        if (treasury == address(0)) revert InvalidTreasury();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (intervals.length == 0) revert InvalidSchedule();
        for (uint256 i = 0; i < intervals.length; i++) {
            // 间隔必须大于封盘时长，否则下一期在上一期开奖前就已截止
            if (intervals[i] <= SEAL_GAP) revert InvalidSchedule();
        }
        if (tierBps.length == 0 || tierBps.length != tierWinnerCounts.length) {
            revert InvalidTierConfig();
        }
        uint256 bpsSum = 0;
        uint256 slots = 0;
        for (uint256 i = 0; i < tierBps.length; i++) {
            if (tierWinnerCounts[i] == 0) revert InvalidTierConfig();
            bpsSum += tierBps[i];
            slots += tierWinnerCounts[i];
        }
        if (bpsSum != BPS_DENOMINATOR || slots > 16) revert InvalidTierConfig();

        i_token = IERC20(token);
        i_ticketPrice = ticketPrice;
        i_keyHash = keyHash;
        i_subId = subId;
        i_coordinator = vrfCoordinator;
        s_treasury = treasury;
        s_feeBps = feeBps;
        s_tierBps = tierBps;
        s_tierWinnerCounts = tierWinnerCounts;
        s_intervals = intervals;
        s_lastSlotTime = anchorTime;

        _openNextRound(0, 0);
    }

    // ===== 购票与注资 =====

    /// @notice 购买连续票号的彩票，一次购买只写入一条 Range（FR-C-04）
    function buyTickets(uint32 quantity) external {
        if (s_salesPaused) revert SalesArePaused();
        uint32 roundId = s_currentRound;
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.OPEN) revert RoundNotOpen();
        // FR-C-09：到达停售时刻即拒绝，即使 keeper 尚未触发
        if (block.timestamp >= r.closeTime) revert SalesClosed();
        if (quantity == 0) revert InvalidQuantity();
        if (quantity > MAX_TICKETS_PER_TX) revert ExceedsMaxPerTx();
        if (uint256(r.ticketCount) + quantity > type(uint32).max) revert ExceedsRoundCapacity();

        uint32 start = r.ticketCount;
        uint256 cost = i_ticketPrice * quantity;
        uint256 fee = (cost * s_feeBps) / BPS_DENOMINATOR;
        r.pot += cost - fee;
        s_accruedFees += fee;
        r.ticketCount = start + quantity;
        s_ranges[roundId].push(
            TicketRange({start: start, end: start + quantity, owner: msg.sender})
        );

        emit TicketsBought(roundId, msg.sender, start, quantity);
        i_token.safeTransferFrom(msg.sender, address(this), cost);
    }

    /// @notice 冷启动/活动注资：任何人可向售票中的期注入奖金，全额进奖池、不抽成（FR-C-26）
    /// @dev 与 buyTickets 共用同一时间闸（FR-C-09）：停售后不得再改变本期奖池规模
    function injectPot(uint32 roundId, uint256 amount) external {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.OPEN) revert RoundNotOpen();
        if (block.timestamp >= r.closeTime) revert SalesClosed();
        if (amount == 0) revert InvalidQuantity();
        r.pot += amount;
        emit PotInjected(roundId, msg.sender, amount);
        i_token.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ===== 开奖（Automation + VRF）=====

    /// @notice Chainlink Automation 检查：当前期到达开奖时刻即需要执行
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory)
    {
        Round storage r = s_rounds[s_currentRound];
        upkeepNeeded = r.state == RoundState.OPEN && block.timestamp >= r.closeTime + SEAL_GAP;
        return (upkeepNeeded, "");
    }

    /// @notice 触发开奖：空期作废（不消耗 VRF），否则请求随机数并立即开启下一期（FR-C-10）
    function performUpkeep(bytes calldata) external override {
        uint32 roundId = s_currentRound;
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.OPEN || block.timestamp < r.closeTime + SEAL_GAP) {
            revert DrawNotDue();
        }

        if (r.ticketCount == 0) {
            // FR-C-08：零购票直接作废；注资与滚存承接额转入下期（FR-C-26）
            r.state = RoundState.VOIDED;
            uint256 carryPot = r.pot;
            uint256 carryT1 = r.tier1Carry;
            r.pot = 0;
            r.tier1Carry = 0;
            emit RoundVoided(roundId);
            uint32 nextId = _openNextRound(carryPot, carryT1);
            if (carryPot + carryT1 > 0) {
                emit PrizeRolledOver(roundId, nextId, carryPot + carryT1);
            }
            return;
        }

        r.state = RoundState.DRAWING;
        r.drawRequestedAt = uint64(block.timestamp);
        uint256 requestId = _requestRandomWords();
        r.vrfRequestId = requestId;
        s_requestToRound[requestId] = roundId;
        emit DrawRequested(roundId, requestId);

        _openNextRound(0, 0);
    }

    /// @notice VRF 超时兜底：距上次请求满 DRAW_TIMEOUT 后任何人可重新请求（FR-C-14）
    function retryDraw(uint32 roundId) external {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.DRAWING) revert RoundNotDrawing();
        if (block.timestamp < r.drawRequestedAt + DRAW_TIMEOUT) revert RetryTooEarly();

        r.drawRequestedAt = uint64(block.timestamp);
        uint256 requestId = _requestRandomWords();
        r.vrfRequestId = requestId;
        s_requestToRound[requestId] = roundId;
        emit DrawRequested(roundId, requestId);
    }

    /// @dev VRF 回调：只做记账，不转账（FR-C-16）。
    ///      非 DRAWING 或 requestId 已被重试替换时静默返回（FR-C-15）
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)
        internal
        override
    {
        // 基类只校验 msg.sender == s_vrfCoordinator，而 s_vrfCoordinator 可被 owner
        // 用继承来的 setCoordinator 换掉。此处强制随机源必须是构造时钉死的那一个，
        // 杜绝 owner 换源后离线挑选种子操纵开奖（FR-C-11/22/24 的实际保障）
        if (address(s_vrfCoordinator) != i_coordinator) revert CoordinatorTampered();

        uint32 roundId = s_requestToRound[requestId];
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.DRAWING || r.vrfRequestId != requestId) {
            return;
        }

        uint256 seed = randomWords[0];
        r.randomSeed = seed;

        uint256 pot = r.pot;
        uint256 tierCount = s_tierBps.length;
        uint256 splitTotal = 0;
        uint256 carryOut = 0;

        for (uint8 tier = 0; tier < tierCount; tier++) {
            uint256 amount = (pot * s_tierBps[tier]) / BPS_DENOMINATOR;
            splitTotal += amount;
            if (tier == 0) {
                amount += r.tier1Carry; // Q1：上期滚存计入一等奖份额
            }
            uint8 winners = s_tierWinnerCounts[tier];
            if (winners > r.ticketCount) {
                // Q1：名额多于总票数的奖级不开出，奖金滚入下期一等奖份额
                carryOut += amount;
            } else {
                uint256 perWinner = amount / winners;
                s_perWinnerAmount[roundId][tier] = perWinner;
                carryOut += amount - perWinner * winners; // 均分余数
            }
        }
        carryOut += pot - splitTotal; // 比例切分的舍入余数

        r.state = RoundState.SETTLED;
        if (carryOut > 0) {
            uint32 target = s_currentRound; // 始终是 OPEN 或 DRAWING（开奖即开下一期）
            s_rounds[target].tier1Carry += carryOut;
            emit PrizeRolledOver(roundId, target, carryOut);
        }

        (uint32[] memory tickets, address[] memory winnersArr) = _deriveWinners(roundId);
        emit WinnersPicked(roundId, tickets, winnersArr);
    }

    // ===== 领奖与资金 =====

    /// @notice 领取某期某奖级的全部本人奖金（pull 模式，FR-C-17）。暂停售票不影响领奖（FR-C-23）
    function claim(uint32 roundId, uint8 tier) external nonReentrant {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.SETTLED) revert RoundNotSettled();
        if (tier >= s_tierBps.length) revert InvalidTier();
        if (block.timestamp > r.closeTime + CLAIM_WINDOW) revert ClaimWindowClosed();
        uint256 perWinner = s_perWinnerAmount[roundId][tier];
        if (perWinner == 0) revert TierNotOpened();

        uint256 total = 0;
        (uint8 slotStart, uint8 winners) = _tierSlots(tier);
        for (uint8 j = 0; j < winners; j++) {
            uint8 slot = slotStart + j;
            if (r.claimedBits & (uint16(1) << slot) != 0) continue;
            uint32 ticketId = _winningTicket(r.randomSeed, slot, r.ticketCount);
            if (_ownerOfTicket(roundId, ticketId) != msg.sender) continue;
            r.claimedBits |= uint16(1) << slot;
            total += perWinner;
        }
        if (total == 0) revert NothingToClaim();

        emit PrizeClaimed(roundId, msg.sender, tier, total);
        i_token.safeTransfer(msg.sender, total);
    }

    /// @notice 领奖窗口结束后，任何人可把该期未领奖金滚入当前期奖池（FR-C-19）
    function rolloverExpired(uint32 roundId) external {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.SETTLED) revert RoundNotSettled();
        if (block.timestamp <= r.closeTime + CLAIM_WINDOW) revert ClaimWindowNotClosed();
        if (r.expiredRolled) revert AlreadyRolledOver();
        r.expiredRolled = true;

        uint256 unclaimed = 0;
        uint256 tierCount = s_tierBps.length;
        for (uint8 tier = 0; tier < tierCount; tier++) {
            uint256 perWinner = s_perWinnerAmount[roundId][tier];
            if (perWinner == 0) continue;
            (uint8 slotStart, uint8 winners) = _tierSlots(tier);
            for (uint8 j = 0; j < winners; j++) {
                uint8 slot = slotStart + j;
                if (r.claimedBits & (uint16(1) << slot) == 0) {
                    r.claimedBits |= uint16(1) << slot;
                    unclaimed += perWinner;
                }
            }
        }
        if (unclaimed == 0) revert NothingToClaim();

        uint32 target = s_currentRound;
        s_rounds[target].pot += unclaimed;
        emit PrizeRolledOver(roundId, target, unclaimed);
    }

    /// @notice 把已分账的运营抽成全额转给 treasury。任何人可触发，资金只会去 treasury
    function withdrawFees() external {
        uint256 amount = s_accruedFees;
        if (amount == 0) revert NoFeesToWithdraw();
        s_accruedFees = 0;
        address treasury = s_treasury;
        emit FeesWithdrawn(treasury, amount);
        i_token.safeTransfer(treasury, amount);
    }

    // ===== owner 权限（仅限 FR-C-22 列出的三项）=====

    /// @notice 设置运营抽成接收地址
    function setTreasury(address treasury) external onlyOwner {
        if (treasury == address(0)) revert InvalidTreasury();
        s_treasury = treasury;
        emit TreasuryUpdated(treasury);
    }

    /// @notice 设置抽成比例，不得超过 MAX_FEE_BPS（FR-C-21）
    function setFeeBps(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        s_feeBps = feeBps;
        emit FeeBpsUpdated(feeBps);
    }

    /// @notice 暂停/恢复售票。只影响 buyTickets，领奖、滚存、重试开奖不受影响（FR-C-23）
    function setSalesPaused(bool paused) external onlyOwner {
        s_salesPaused = paused;
        emit SalesPausedUpdated(paused);
    }

    // ===== 视图 =====

    /// @notice 由 ticketId 反查持有人，二分查找 O(log n)（FR-C-05）
    function ownerOfTicket(uint32 roundId, uint32 ticketId) external view returns (address) {
        if (ticketId >= s_rounds[roundId].ticketCount) revert TicketOutOfRange();
        return _ownerOfTicket(roundId, ticketId);
    }

    /// @notice 期详情
    function getRound(uint32 roundId)
        external
        view
        returns (
            RoundState state,
            uint64 closeTime,
            uint64 drawTime,
            uint32 ticketCount,
            uint256 pot,
            uint256 tier1Carry,
            uint256 randomSeed,
            uint16 claimedBits,
            bool expiredRolled
        )
    {
        Round storage r = s_rounds[roundId];
        return (
            r.state,
            r.closeTime,
            r.closeTime + SEAL_GAP,
            r.ticketCount,
            r.pot,
            r.tier1Carry,
            r.randomSeed,
            r.claimedBits,
            r.expiredRolled
        );
    }

    /// @notice 奖级配置
    function getTierConfig()
        external
        view
        returns (uint16[] memory tierBps, uint8[] memory winnerCounts)
    {
        return (s_tierBps, s_tierWinnerCounts);
    }

    /// @notice 某期当前生效的 VRF 请求（测试与本地模拟回调用）
    function vrfRequestOf(uint32 roundId)
        external
        view
        returns (uint256 requestId, uint64 requestedAt)
    {
        Round storage r = s_rounds[roundId];
        return (r.vrfRequestId, r.drawRequestedAt);
    }

    /// @notice 某期某奖级的单个中奖者奖金（未结算或未开出为 0）
    function perWinnerAmount(uint32 roundId, uint8 tier) external view returns (uint256) {
        return s_perWinnerAmount[roundId][tier];
    }

    /// @notice 已结算期的全部中奖票与中奖人（按 slot 顺序；未开出的奖级不含在内）
    function winnersOf(uint32 roundId)
        external
        view
        returns (uint32[] memory winningTickets, address[] memory winners)
    {
        if (s_rounds[roundId].state != RoundState.SETTLED) revert RoundNotSettled();
        return _deriveWinners(roundId);
    }

    /// @notice 某地址在某期可领而未领的各奖级金额（测试界面用；正式前端走事件）
    function pendingPrizes(uint32 roundId, address account)
        external
        view
        returns (uint256[] memory amounts)
    {
        Round storage r = s_rounds[roundId];
        uint256 tierCount = s_tierBps.length;
        amounts = new uint256[](tierCount);
        if (r.state != RoundState.SETTLED || block.timestamp > r.closeTime + CLAIM_WINDOW) {
            return amounts;
        }
        for (uint8 tier = 0; tier < tierCount; tier++) {
            uint256 perWinner = s_perWinnerAmount[roundId][tier];
            if (perWinner == 0) continue;
            (uint8 slotStart, uint8 winners) = _tierSlots(tier);
            for (uint8 j = 0; j < winners; j++) {
                uint8 slot = slotStart + j;
                if (r.claimedBits & (uint16(1) << slot) != 0) continue;
                uint32 ticketId = _winningTicket(r.randomSeed, slot, r.ticketCount);
                if (_ownerOfTicket(roundId, ticketId) == account) {
                    amounts[tier] += perWinner;
                }
            }
        }
        return amounts;
    }

    /// @notice 某期全部 Range 记录（测试界面用）
    function getRanges(uint32 roundId) external view returns (TicketRange[] memory) {
        return s_ranges[roundId];
    }

    /// @notice 某地址在某期持有的票数（测试界面用；正式前端走事件）
    function ticketsOwned(uint32 roundId, address account) external view returns (uint256 count) {
        TicketRange[] storage ranges = s_ranges[roundId];
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].owner == account) {
                count += ranges[i].end - ranges[i].start;
            }
        }
    }

    // ===== 内部 =====

    /// @dev 开启下一期：closeTime 取日程中晚于当前时刻的最近场次（跳过已错过的场次，Q2）
    function _openNextRound(uint256 carryPot, uint256 carryTier1) private returns (uint32 newId) {
        uint64 t = s_lastSlotTime;
        uint32 cursor = s_intervalCursor;
        uint32 len = uint32(s_intervals.length);
        do {
            t += s_intervals[cursor];
            cursor = (cursor + 1) % len;
        } while (t <= block.timestamp);
        s_lastSlotTime = t;
        s_intervalCursor = cursor;

        newId = ++s_currentRound;
        Round storage r = s_rounds[newId];
        r.state = RoundState.OPEN;
        r.closeTime = t;
        r.pot = carryPot;
        r.tier1Carry = carryTier1;
        emit RoundOpened(newId, t);
    }

    /// @dev 请求恒发往构造时钉死的 coordinator，不受 setCoordinator 影响
    function _requestRandomWords() private returns (uint256 requestId) {
        return IVRFCoordinatorV2Plus(i_coordinator)
            .requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subId,
                requestConfirmations: VRF_CONFIRMATIONS,
                callbackGasLimit: VRF_CALLBACK_GAS,
                numWords: 1,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
            );
    }

    /// @dev FR-C-12：slot i 的中奖票号 = keccak256(seed, i) % ticketCount。
    ///      slot 0 为一等奖；后续 slot 依奖级名额顺延。允许同票中多个 slot（刻意接受）
    function _winningTicket(uint256 seed, uint8 slot, uint32 ticketCount)
        private
        pure
        returns (uint32)
    {
        return uint32(uint256(keccak256(abi.encode(seed, uint256(slot)))) % ticketCount);
    }

    /// @dev 奖级 tier 的 slot 起点与名额
    function _tierSlots(uint8 tier) private view returns (uint8 slotStart, uint8 winners) {
        for (uint8 k = 0; k < tier; k++) {
            slotStart += s_tierWinnerCounts[k];
        }
        winners = s_tierWinnerCounts[tier];
    }

    /// @dev 二分查找 ticketId 所在 Range（FR-C-05）
    function _ownerOfTicket(uint32 roundId, uint32 ticketId) private view returns (address) {
        TicketRange[] storage ranges = s_ranges[roundId];
        uint256 lo = 0;
        uint256 hi = ranges.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (ranges[mid].end <= ticketId) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return ranges[lo].owner;
    }

    /// @dev 派生全部已开出奖级的中奖票与中奖人
    function _deriveWinners(uint32 roundId)
        private
        view
        returns (uint32[] memory tickets, address[] memory winners)
    {
        Round storage r = s_rounds[roundId];
        uint256 tierCount = s_tierBps.length;
        uint256 openSlots = 0;
        for (uint8 tier = 0; tier < tierCount; tier++) {
            if (s_perWinnerAmount[roundId][tier] > 0) {
                openSlots += s_tierWinnerCounts[tier];
            }
        }
        tickets = new uint32[](openSlots);
        winners = new address[](openSlots);
        uint256 idx = 0;
        for (uint8 tier = 0; tier < tierCount; tier++) {
            if (s_perWinnerAmount[roundId][tier] == 0) continue;
            (uint8 slotStart, uint8 count) = _tierSlots(tier);
            for (uint8 j = 0; j < count; j++) {
                uint32 ticketId = _winningTicket(r.randomSeed, slotStart + j, r.ticketCount);
                tickets[idx] = ticketId;
                winners[idx] = _ownerOfTicket(roundId, ticketId);
                idx++;
            }
        }
    }
}
