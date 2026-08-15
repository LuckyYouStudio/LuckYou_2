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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title 链上周期开奖彩票
/// @notice 抽签制彩票：按双色球日程（锚定固定场次）售票，Chainlink VRF v2.5 开奖，
///         keeper 触发。奖池与运营抽成自购票时刻起分账（FR-C-20），
///         不存在任何能挪用奖池的管理员函数（FR-C-24）。
/// @dev 计价资产为**链原生币（ETH）**（FR-C-01，2026-08-11 由 USDC 变更）。
///      理由：ERC20 稳定币由发行方掌控，可暂停/黑名单/升级，合约地址一旦被拉黑
///      则买票、领奖、提抽成同时失效且无救援手段；原生币无发行方，且省掉 approve。
///      代价：ETH 价格波动会影响奖池实际购买力——这是刻意接受的取舍。
/// @dev 无 `receive`/`fallback`：只能经 buyTickets / injectPot 两个 payable 入口付款。
///      误转入的 ETH 无法退回，也会破坏偿付性不变量，因此干脆不接收。
///      所有转出用 `call{value:}` 并检查返回值；因原生转账会执行接收方代码，
///      转出路径一律 CEI + nonReentrant。
/// @dev owner 权限完整清单见 FR-C-22 说明：setTreasury / setFeeBps / setSalesPaused，
///      外加继承自 ConfirmedOwner 的 transferOwnership / acceptOwnership，
///      以及继承自 VRFConsumerBaseV2Plus 的 setCoordinator（无法 override 封禁，
///      但换源后回调会被 CoordinatorTampered 拒绝，只能造成可自行恢复的延迟，
///      无法操纵开奖或挪用资金）。
contract Lottery is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, ReentrancyGuard {
    // ===== 类型 =====

    enum RoundState {
        NONE,
        OPEN,
        DRAWING,
        SETTLED,
        VOIDED,
        /// @dev 卡死超 ABANDON_TIMEOUT 后作废、转为按票款退款（FR-C-29）。
        ///      追加在末尾而非插入中间——枚举取值已被前端与既有部署依赖
        ABANDONED
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
        bool salesPausedAtOpen; // 开期时的暂停状态快照（修复：见 setSalesPaused）
        uint16 feeBpsAtOpen; // 开期时的抽成快照，防 owner 抢跑购票临时抬高费率
        uint64 drawRequestedAt;
        uint64 settledAt; // 结算时刻；领奖窗口自此起算，避免结算延迟吃掉窗口
        uint256 pot; // 本期可分配奖金（购票分账 + 注资 + 承接的过期滚存）
        uint256 carriedPot; // pot 中「非本期自售」的部分（滚存承接 + 注资），受参与度门槛保护
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
    /// @notice 调用者指定的期号与链上当前期不符（FR-C-09a）
    error RoundMismatch(uint32 expected, uint32 actual);
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
    error InvalidTicketPrice();
    error InvalidSchedule();
    error InvalidTierConfig();
    error NoFeesToWithdraw();
    error TransferFailed();
    error IncorrectPayment();
    error OnlySelf();
    error InvalidRecipient();
    error AbandonTooEarly();
    error RoundNotAbandoned();
    error NotRangeOwner();
    error AlreadyRefunded();
    error NoRewardToClaim();

    // ===== 事件（FR-C-25）=====

    event RoundOpened(uint32 indexed roundId, uint64 closeTime);
    event TicketsBought(
        uint32 indexed roundId, address indexed buyer, uint32 start, uint32 quantity
    );
    event PotInjected(uint32 indexed roundId, address indexed sender, uint256 amount);
    event DrawRequested(uint32 indexed roundId, uint256 indexed requestId);
    /// @notice 开奖结算。中奖票号由 `keccak256(seed, slot) % ticketCount` 完全决定，
    ///         中奖人可由 TicketsBought 事件离线还原（或调 winnersOf 视图）——
    ///         这保持了 FR-C-25「仅靠事件重建全部历史」，同时让 VRF 回调保持 O(奖级数)
    event DrawSettled(
        uint32 indexed roundId, uint256 seed, uint32 ticketCount, uint256[] perWinnerAmounts
    );
    event PrizeClaimed(uint32 indexed roundId, address indexed winner, uint8 tier, uint256 amount);
    /// @notice 资金离开某期进入滚存缓冲区（FR-C-28）。
    ///         `toRound` 恒为 0——因为释放是按窗口完整度打折的，这笔钱可能分几期才流出，
    ///         在此刻无法确定去向。真正的去向由 CarryReleased 事件给出
    event PrizeRolledOver(uint32 indexed fromRound, uint32 indexed toRound, uint256 amount);
    /// @notice 缓冲区资金释放进新开出的期（与 PrizeRolledOver 配对，可精确重建资金流）
    event CarryReleased(uint32 indexed toRound, uint256 potAmount, uint256 tier1Amount);
    event RoundVoided(uint32 indexed roundId);
    event FeesWithdrawn(address indexed treasury, uint256 amount);
    event TreasuryUpdated(address indexed treasury);
    event FeeBpsUpdated(uint16 feeBps);
    event SalesPausedUpdated(bool paused);
    /// @notice carry 超出本期自售额配比的部分被扣留、顺延到后续期（FR-C-27）。
    /// @dev **这笔钱同时也会由 `PrizeRolledOver` 报告一次**——本事件只是「为什么被扣留」
    ///      的附加说明。纯事件重建器若把两者都算作缓冲区流入会重复计数，
    ///      应只累加 `PrizeRolledOver`（R20 I-1）
    event CarryWithheld(uint32 indexed roundId, uint256 amount);
    /// @notice 构造时一次性广播奖级配置。DrawSettled 只带 seed 与各档金额，
    ///         而 slot→奖级 的映射依赖 winnerCounts；没有这个事件，
    ///         纯事件重建器就无法把中奖位归到正确奖级（FR-C-25）
    event TierConfigSet(uint16[] tierBps, uint8[] winnerCounts);
    /// @notice VRF 请求失败（订阅问题等）。本期留在 DRAWING 待 retryDraw，不阻塞新期开出
    event DrawRequestFailed(uint32 indexed roundId);
    /// @notice 某期卡死超阈值被作废，转为退款模式（FR-C-29）。amount 为退回缓冲区的非自售部分
    event RoundAbandoned(uint32 indexed roundId, uint256 carryReturned);
    /// @notice 作废期的购票者取回票款
    event TicketsRefunded(uint32 indexed roundId, address indexed buyer, uint256 amount);
    /// @notice 触发开奖者获得的奖励（FR-C-30）。资金来自**该期自己的**运营抽成，
    ///         不动奖池分文——奖池与抽成自购票起就是分账的（FR-C-20）
    event KeeperRewarded(uint32 indexed roundId, address indexed keeper, uint256 amount);
    event KeeperRewardClaimed(address indexed keeper, uint256 amount);

    // ===== 常量 =====

    uint16 public constant MAX_FEE_BPS = 1000; // 10% 硬上限（FR-C-21）
    uint32 public constant MAX_TICKETS_PER_TX = 1000; // FR-C-06
    uint64 public constant SEAL_GAP = 75 minutes; // 停售→开奖间隔（FR-C-08，对应双色球 20:00→21:15）
    /// @notice 新期最短售票窗口。performUpkeep 无权限、任何人可择时调用，若不设下限，
    ///         调用者可卡在下一场次前 1 秒开期，使新期只有极短窗口供自己独占（审计第三轮 #2）
    uint64 public constant MIN_SALES_WINDOW = 30 minutes;
    /// @notice 滚存/注资资金的释放配比（FR-C-27）：本期可分配的 carry 上限 =
    ///         本期自售净额 × 此倍数，超出部分退回缓冲顺延。
    ///
    ///         为什么是「按自售额配比」而不是「票数达标就全放」：
    ///         - 阶跃门槛可被恰好买满门槛票数的人一次性独占整包 carry，
    ///           捕获成本与 carry 规模无关（O(1)），carry 越滚越大反而越划算；
    ///         - 若再加「连续扣留 N 期后强制放行」的逃生阀，攻击者只需用最小额度
    ///           把计数器攒满，成本进一步降到几张票（审计第四轮 Critical）。
    ///         按配比后，想拿走 X 的 carry 就必须自掏至少 X/倍数 的票款，
    ///         资本门槛与捕获量线性挂钩；同时只要有人买票就会释放相应额度，
    ///         carry 不会像阶跃门槛那样在低参与度下被永久冻结。
    ///
    ///         **诚实的局限**：这仍不能消除捕获——买光全场即可拿走全部奖池是
    ///         抽签制彩票的固有性质，攻击者的本金也会随中奖回到自己手里。
    ///         配比只抬高资本门槛并给其他参与者稀释的机会
    uint256 public constant CARRY_MATCH_MULTIPLIER = 1;
    uint64 public constant DRAW_TIMEOUT = 3 hours; // FR-C-14
    uint64 public constant CLAIM_WINDOW = 90 days; // FR-C-19
    /// @notice 卡死逃生阈值（FR-C-29）：某期停在 DRAWING 超过此时长后，
    ///         任何人可作废该期，购票者按票款原路取回。
    ///         **不含任何自由裁量权**，因此不违反 FR-C-24（该条禁的是「管理员能动到未领奖金」）
    uint64 public constant ABANDON_TIMEOUT = 30 days;
    /// @notice 触发开奖的奖励占**该期抽成**的比例（FR-C-30）。
    ///
    ///         为什么是常量而非可调参数：多一个可调项就多一个信任面，而这个数
    ///         本就不该经常动。代价是部署后无法适应 gas 或币价的长期变化——
    ///         真要改只能重新部署，这是刻意接受的取舍。
    ///
    ///         为什么按比例而非固定金额：固定金额在 ETH 涨跌与 gas 波动下迟早失衡；
    ///         按比例则自动缩放——热闹的期奖励高、冷清的期奖励低、**零票的期为零**。
    ///
    ///         经济上的诚实说明：一次 performUpkeep 约 17.3 万 gas，主网连同 L1
    ///         数据费约 1e-5 ETH。20% 意味着约 50 张票以上的期才够覆盖 gas，
    ///         更小的期不会有人来按按钮。这不是缺陷——三张票的期本就不值得
    ///         谁专门跑机器人；但它意味着**奖励创造的是动机，不是机制**，
    ///         冷启动阶段仍需运营方自己触发
    uint16 public constant KEEPER_REWARD_BPS = 2000; // 20%
    uint16 public constant BPS_DENOMINATOR = 10000;
    uint16 private constant VRF_CONFIRMATIONS = 3;
    uint32 private constant VRF_CALLBACK_GAS = 1_000_000;

    // ===== 不可变配置 =====

    uint256 public immutable i_ticketPrice;
    bytes32 public immutable i_keyHash;
    uint256 public immutable i_subId;
    // 注：此处曾有 `address private immutable i_coordinator`，把随机源钉死以防
    // owner 用继承来的 setCoordinator 换源挑种子。2026-08-13 按 SPEC Q9 方案 B 移除——
    // 那道校验同时把 Chainlink **官方订阅迁移**判成篡改（migrate 会替每个 consumer
    // 调 setCoordinator），迁移后回调恒失败、请求又发往已删订阅的旧源，全部奖池永久冻结。
    // 换源杠杆改由 LotteryAdmin 从**权限侧**消除：owner 是一个物理上没有能力调
    // setCoordinator 的极小合约，于是 setCoordinator 只剩 coordinator 自己能调
    // （= 只有合法迁移），随机源便可安全地跟随 s_vrfCoordinator。

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

    // 滚存缓冲区（2026-08-10 安全修复 A）：过期滚存与未开出奖级的 carry 不再直接注入
    // s_currentRound（其可能处于封盘期、票已冻结、攻击者可预先卡位为唯一买家），
    // 而是先入缓冲，由 _openNextRound 在开出新期（拥有完整、未封盘售票窗口）时消费
    uint256 public s_pendingPot; // 待并入下一新期 pot（过期滚存，FR-C-19）
    uint256 public s_pendingTier1; // 待并入下一新期一等奖份额（Q1 未开出奖级 carry）

    /// @dev 作废期中已退款的 Range（FR-C-29）。按 range 而非按地址记账：
    ///      同一地址可能有多条 Range，逐条标记才能既支持分批退款又杜绝重复领取
    mapping(uint32 roundId => mapping(uint256 rangeIndex => bool)) private s_rangeRefunded;

    /// @dev 已记账、尚未领取的开奖奖励（pull 模式，FR-C-30）
    mapping(address keeper => uint256 amount) private s_keeperRewards;
    /// @dev 上面那个 mapping 的总和。mapping 无法在链上求和，而偿付性不变量
    ///      必须把这笔未领奖励计入应付义务，故单独维护一个聚合数
    uint256 public s_pendingKeeperRewards;

    // ===== 构造 =====

    /// @param vrfCoordinator VRF v2.5 coordinator 地址
    /// @param subId VRF 订阅 ID
    /// @param keyHash VRF gas lane
    /// @param ticketPrice 票价（wei）。部署默认 0.0001 ether
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
        uint256 ticketPrice,
        uint64 anchorTime,
        uint32[] memory intervals,
        address treasury,
        uint16 feeBps,
        uint16[] memory tierBps,
        uint8[] memory tierWinnerCounts
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        if (ticketPrice == 0) revert InvalidTicketPrice();
        if (treasury == address(0)) revert InvalidTreasury();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (intervals.length == 0) revert InvalidSchedule();
        for (uint256 i = 0; i < intervals.length; i++) {
            // 间隔必须大于「封盘时长 + 最短售票窗口」，否则日程本身就排不出
            // 一个可正常售票的期（审计第三轮 #2，同时并解旧发现 H）
            if (intervals[i] <= SEAL_GAP + MIN_SALES_WINDOW) revert InvalidSchedule();
        }
        // 日程全合约无 setter，锚点配错只能重新部署。远古锚点会让 _openNextRound 的
        // 追赶循环在构造时就跑上百万次：实测 anchor=1 且 interval 取允许的最小值 6301 时
        // 需要 207.9M gas，必然 OOG。加一道显式闸，让配错失败得清楚（R20 L-4）
        if (uint256(anchorTime) + 365 days < block.timestamp) revert InvalidSchedule();
        // 对称的另一侧同样致命，而 R20 L-4 只挡了一半（第 50 轮 A-4）：锚点若落在未来，
        // 第 1 期的 closeTime 就跟着落在未来，`performUpkeep` 永远不到期、期号永不推进，
        // 而 `buyTickets` 只看 state 与 closeTime，实例会**照常收钱**。日程无 setter、
        // FR-C-24 又禁止任何救援手段，这种实例只能作废重部。锚点按定义是「一个已经
        // 发生过的场次」（Deploy.s.sol 取上一个周二 12:00 UTC，或部署当刻），因此
        // 要求它不晚于当前时刻不会拒绝任何合法配置
        if (anchorTime > block.timestamp) revert InvalidSchedule();
        if (tierBps.length == 0 || tierBps.length != tierWinnerCounts.length) {
            revert InvalidTierConfig();
        }
        uint256 bpsSum = 0;
        uint256 slots = 0;
        for (uint256 i = 0; i < tierBps.length; i++) {
            // 名额为 0 的奖级无意义；比例为 0 的奖级 perWinner 恒为 0 ⇒ 永远判为
            // 「未开出」⇒ 每期把它那份滚走，却照样占用 16 个 slot 的名额预算（R20 I-2）
            if (tierWinnerCounts[i] == 0 || tierBps[i] == 0) revert InvalidTierConfig();
            bpsSum += tierBps[i];
            slots += tierWinnerCounts[i];
        }
        if (bpsSum != BPS_DENOMINATOR || slots > 16) revert InvalidTierConfig();
        // 注：曾在此加过「回调 gas 预算」校验，但 slots <= 16 已蕴含
        // tierBps.length <= 16（每档名额 >= 1），预算上界恒为 514k < 1M，
        // 那条校验永远不触发、只制造虚假安全感，已移除（第四轮复查 M-4）。
        // 回调 gas 的真正保障是：中奖人派生已移出回调，其成本与 range 数无关

        i_ticketPrice = ticketPrice;
        i_keyHash = keyHash;
        i_subId = subId;
        s_treasury = treasury;
        s_feeBps = feeBps;
        s_tierBps = tierBps;
        s_tierWinnerCounts = tierWinnerCounts;
        s_intervals = intervals;
        s_lastSlotTime = anchorTime;
        emit TierConfigSet(tierBps, tierWinnerCounts);

        _openNextRound();
    }

    // ===== 购票与注资 =====

    /// @notice 购买连续票号的彩票，一次购买只写入一条 Range（FR-C-04）。
    /// @param quantity 购买张数
    /// @param expectedRoundId 调用者**发起交易时看到的**期号；与链上当前期不符即 revert（FR-C-09a）
    /// @dev msg.value **必须恰好**等于 票价 × 张数：多付不自动退还——退款是额外的
    ///      外部调用，会平白扩大重入面（FR-C-03）
    /// @dev 为什么期号必须由调用者带进来（R20 L-1）：交易在内存池里排队期间，
    ///      `performUpkeep` 可能已经翻到下一期。此时买单会落在一个用户从未选择的期上——
    ///      奖池规模、已售票数、中奖概率、乃至距停售还剩多久，全都与他下单时看到的不同。
    ///      钱不会丢，但「买到的不是看到的」在彩票语境下就是错误成交。
    ///      **注意**：`expectedRoundId` 必须来自链下（用户下单那一刻的读数）。
    ///      在同一笔交易里现读 `s_currentRound()` 再传进来是**完全无效的**——
    ///      那只是把当前值和它自己比，恒等成立。
    function buyTickets(uint32 quantity, uint32 expectedRoundId) external payable {
        uint32 roundId = s_currentRound;
        if (roundId != expectedRoundId) revert RoundMismatch(expectedRoundId, roundId);
        Round storage r = s_rounds[roundId];
        // 用开期快照而非全局标志：暂停对「已开出的期」无效，owner 无法中途清场后自购
        if (r.salesPausedAtOpen) revert SalesArePaused();
        if (r.state != RoundState.OPEN) revert RoundNotOpen();
        // FR-C-09：到达停售时刻即拒绝，即使 keeper 尚未触发
        if (block.timestamp >= r.closeTime) revert SalesClosed();
        if (quantity == 0) revert InvalidQuantity();
        if (quantity > MAX_TICKETS_PER_TX) revert ExceedsMaxPerTx();
        if (uint256(r.ticketCount) + quantity > type(uint32).max) revert ExceedsRoundCapacity();

        uint32 start = r.ticketCount;
        uint256 cost = i_ticketPrice * quantity;
        if (msg.value != cost) revert IncorrectPayment();
        // 用开期快照而非实时费率：否则 owner 可抢跑大额购票临时把 1% 抬到 10%，
        // 差额从奖池里吃走（审计第四轮，与 salesPausedAtOpen 同构）
        uint256 fee = (cost * r.feeBpsAtOpen) / BPS_DENOMINATOR;
        r.pot += cost - fee;
        s_accruedFees += fee;
        r.ticketCount = start + quantity;
        s_ranges[roundId].push(
            TicketRange({start: start, end: start + quantity, owner: msg.sender})
        );

        emit TicketsBought(roundId, msg.sender, start, quantity);
    }

    /// @notice 冷启动/活动注资：任何人可向售票中的期注入奖金，全额进奖池、不抽成（FR-C-26）
    /// @dev 与 buyTickets 共用同一时间闸（FR-C-09）：停售后不得再改变本期奖池规模
    function injectPot(uint32 roundId) external payable {
        Round storage r = s_rounds[roundId];
        // 与 buyTickets 共用同一道暂停闸（R21 C-1）。这不是语义洁癖：暂停状态在开期时
        // 就被快照定死，因此「开期即暂停」的期**永远不可能有票**（buyTickets 恒 revert，
        // 事后恢复售票也改不了这一期的快照），必然以 ticketCount == 0 走到 VOIDED。
        // 往这样的期注资，那笔钱**必然**流进滚存缓冲区——而缓冲区没有退出通道（FR-C-28）。
        // 也就是说，缺了这道闸，injectPot 就是一条把资金单向送进黑洞的合法入口
        if (r.salesPausedAtOpen) revert SalesArePaused();
        if (r.state != RoundState.OPEN) revert RoundNotOpen();
        if (block.timestamp >= r.closeTime) revert SalesClosed();
        uint256 amount = msg.value;
        if (amount == 0) revert InvalidQuantity();
        r.pot += amount;
        // 注资同样是「非本期自售」的钱，受配比释放约束，避免被小额独占
        r.carriedPot += amount;
        emit PotInjected(roundId, msg.sender, amount);
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
            // FR-C-08：零购票直接作废。其资金**必须经缓冲区**转出（FR-C-28），
            // 不能直接注入下一期——否则攻击者可让期空转、再在压缩窗口时触发 VOID，
            // 让整包 carry 绕过按窗口打折的释放规则进入他能独占的短窗口期（第四轮复查）
            r.state = RoundState.VOIDED;
            uint256 voided = r.pot + r.tier1Carry;
            s_pendingPot += r.pot;
            s_pendingTier1 += r.tier1Carry;
            r.pot = 0;
            r.tier1Carry = 0;
            r.carriedPot = 0; // 同步清零，避免 carriedPotOf 对 VOIDED 期报告已转走的钱
            emit RoundVoided(roundId);
            if (voided > 0) {
                emit PrizeRolledOver(roundId, 0, voided);
            }
            _openNextRound();
            return;
        }

        r.state = RoundState.DRAWING;
        r.drawRequestedAt = uint64(block.timestamp);
        // FR-C-30：给触发者记账奖励。**只在这条分支**——零票作废的期不给，
        // 否则无人玩时有人可以每个间隔触发一次 VOID 来刷钱。
        // （按比例算本就会得 0，此处仍显式区分，让意图写在代码结构里而非注释里）
        _accrueKeeperReward(roundId, r);
        // VRF 请求失败**不得**让整笔交易回滚：否则订阅被 removeConsumer 或 coordinator
        // 层失效时，_openNextRound 也一起失败 → 期号永不推进 → 全部资金（含缓冲区）
        // 永久冻结，而 FR-C-24 禁止任何救援手段。隔离后最坏只是本期卡在 DRAWING
        // （3 小时后任何人可 retryDraw），彩票本身继续运转（第十轮红队 #1）
        try this.requestRandomWordsSelf() returns (uint256 requestId) {
            r.vrfRequestId = requestId;
            s_requestToRound[requestId] = roundId;
            emit DrawRequested(roundId, requestId);
        } catch {
            emit DrawRequestFailed(roundId);
        }

        _openNextRound();
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
        // 基类已校验 msg.sender == s_vrfCoordinator。此处不再额外校验随机源是否被换过：
        // 换源能力已由 LotteryAdmin 在权限侧消除（SPEC Q9 方案 B），而保留该校验会把
        // 官方订阅迁移误判为篡改并导致全部奖池永久冻结
        uint32 roundId = s_requestToRound[requestId];
        if (roundId == 0) return; // 未登记的 requestId（期号从 1 起）
        Round storage r = s_rounds[roundId];
        // 修复 B：只以 state 为闸，DRAWING 期内先到的合法回调先落定（先到先得）。
        // 原实现额外校验 requestId == r.vrfRequestId，使 retryDraw 覆写后能作废一个
        // 即将落地的旧回调 = 重摇。FR-C-15「不能改写已定结果」由 state 闸保证：
        // 一旦 SETTLED，任何迟到回调都被下面这一句拦下
        if (r.state != RoundState.DRAWING) {
            return;
        }

        uint256 seed = randomWords[0];
        r.randomSeed = seed;

        uint256 pot = r.pot;
        uint256 tier1CarryIn = r.tier1Carry;
        // 滚存/注资的释放配比（FR-C-27）：本期可分配的 carry 上限 = 本期自售净额 ×
        // CARRY_MATCH_MULTIPLIER，超出部分退回缓冲顺延。想拿走多少 carry 就得自掏
        // 相应票款，资本门槛与捕获量线性挂钩；同时只要有人买票就会释放对应额度，
        // 不会像阶跃门槛那样在低参与度下把钱永久冻结
        (pot, tier1CarryIn) = _withholdExcessCarry(roundId, pot, tier1CarryIn);

        uint256 tierCount = s_tierBps.length;
        uint256 splitTotal = 0;
        uint256 carryOut = 0;

        for (uint8 tier = 0; tier < tierCount; tier++) {
            uint256 amount = (pot * s_tierBps[tier]) / BPS_DENOMINATOR;
            splitTotal += amount;
            if (tier == 0) {
                amount += tier1CarryIn; // Q1：上期滚存计入一等奖份额（未达门槛时已置 0）
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
        r.settledAt = uint64(block.timestamp);
        if (carryOut > 0) {
            // 修复 A：入缓冲，由下一新期消费，不注入可能已封盘的当前期
            s_pendingTier1 += carryOut;
            emit PrizeRolledOver(roundId, 0, carryOut); // 进缓冲，去向由 CarryReleased 给出
        }

        // FR-C-16：回调内只做记账。中奖人由 seed 完全决定，可离线/经 winnersOf 派生，
        // 不在回调里做 16 次二分查找——那会让回调 gas 随 range 数增长，
        // 高 slot 配置下可被灌票撑爆 1M 回调上限、使该期永久卡在 DRAWING（审计第四轮）
        uint256 tierCountForEvent = s_tierBps.length;
        uint256[] memory perWinnerAmounts = new uint256[](tierCountForEvent);
        for (uint8 tier = 0; tier < tierCountForEvent; tier++) {
            perWinnerAmounts[tier] = s_perWinnerAmount[roundId][tier];
        }
        emit DrawSettled(roundId, seed, r.ticketCount, perWinnerAmounts);
    }

    // ===== 领奖与资金 =====

    /// @notice 领取某期某奖级的全部本人奖金（pull 模式，FR-C-17）。暂停售票不影响领奖（FR-C-23）
    function claim(uint32 roundId, uint8 tier) external nonReentrant {
        _claim(roundId, tier, msg.sender);
    }

    /// @notice 同 claim，但把奖金付到指定地址。
    /// @dev 只有中奖票的持有人能调用，钱只能由票主自己指向别处，**不增加任何权限面**。
    ///      存在的理由（2026-08-11 原生 ETH 改造引入的缺陷）：ERC20 时代转账到任何地址
    ///      都成功，改用原生币后，没有 `receive`/`fallback` 的合约钱包中奖即等于弃奖——
    ///      `claim` 恒 revert `TransferFailed`，90 天后奖金被 `rolloverExpired` 扫走。
    ///      顺带满足「冷钱包持票、想领到热钱包」的正常需求
    function claimTo(uint32 roundId, uint8 tier, address to) external nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        _claim(roundId, tier, to);
    }

    /// @dev claim / claimTo 的共用实现：中奖判定恒以 msg.sender 持票为准，
    ///      `to` 只决定钱付到哪里
    function _claim(uint32 roundId, uint8 tier, address to) private {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.SETTLED) revert RoundNotSettled();
        if (tier >= s_tierBps.length) revert InvalidTier();
        // 窗口自结算时刻起算：keeper/VRF 停摆导致的结算延迟不得吃掉中奖者的领奖时间
        // （审计第四轮：延迟 > 90 天时中奖者曾被判 0，奖金反被第三方 rollover 扫走）
        if (block.timestamp > r.settledAt + CLAIM_WINDOW) revert ClaimWindowClosed();
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

        // 事件里记的是**中奖人**（msg.sender），不是收款地址：
        // FR-C-25 的事件重建器据此归属奖金，收款地址只是支付细节
        emit PrizeClaimed(roundId, msg.sender, tier, total);
        _sendValue(to, total);
    }

    /// @notice 领奖窗口结束后，任何人可把该期未领奖金滚入当前期奖池（FR-C-19）
    function rolloverExpired(uint32 roundId) external {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.SETTLED) revert RoundNotSettled();
        // 与 claim 同锚点：结算时刻 + 窗口，两者严格互斥无重叠
        if (block.timestamp <= r.settledAt + CLAIM_WINDOW) revert ClaimWindowNotClosed();
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

        // 修复 A：入缓冲，由下一新期消费。绝不注入 s_currentRound——它可能正处于
        // 封盘期、票已冻结，攻击者可预先卡位为唯一买家从而确定性独占这笔过期奖金
        s_pendingPot += unclaimed;
        emit PrizeRolledOver(roundId, 0, unclaimed); // 进缓冲，去向由 CarryReleased 给出
    }

    /// @notice 卡死逃生通道（FR-C-29）：某期停在 DRAWING 超过 `ABANDON_TIMEOUT` 后，
    ///         **任何人**可将其作废，购票者随后用 `refundAbandoned` 按票款原路取回。
    /// @dev 这是对「任何原因导致的卡死」的兜底——VRF 停摆、LINK 烧光、coordinator 变更、
    ///      乃至尚未发现的 bug。它是唯一**不依赖我们把失效模式列全**的保护。
    ///      无权限、无参数选择、金额完全由链上状态决定，因此不构成 FR-C-24 禁止的行政提款。
    /// @dev 计时锚点是该期**原定开奖时刻**（closeTime + SEAL_GAP），而**不是**
    ///      `drawRequestedAt`——后者会被 `retryDraw` 刷新，攻击者只需每 3 小时重试一次
    ///      即可无限推迟作废、把逃生通道锁死
    function abandonStuckRound(uint32 roundId) external {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.DRAWING) revert RoundNotDrawing();
        if (block.timestamp < uint256(r.closeTime) + SEAL_GAP + ABANDON_TIMEOUT) {
            revert AbandonTooEarly();
        }

        r.state = RoundState.ABANDONED;
        // 非本期自售的钱（滚存承接 + 注资）不属于任何购票者，退回缓冲区另行分配；
        // 剩下的 pot 恰好等于自售净额，留作按 Range 退款的资金池
        uint256 carryBack = r.carriedPot;
        uint256 tier1Back = r.tier1Carry;
        r.pot -= carryBack; // carriedPot <= pot 恒成立
        r.carriedPot = 0;
        r.tier1Carry = 0;
        s_pendingPot += carryBack;
        s_pendingTier1 += tier1Back;

        emit RoundAbandoned(roundId, carryBack + tier1Back);
        if (carryBack + tier1Back > 0) {
            emit PrizeRolledOver(roundId, 0, carryBack + tier1Back);
        }
    }

    /// @notice 取回作废期的票款（pull 模式，FR-C-29）。传入自己名下的 Range 序号，
    ///         可分批取回；序号由 `getRanges` 或 `TicketsBought` 事件得到。
    /// @dev 退款金额 = 票价 × 张数 − 该期抽成，即**不退那 1%**。抽成在购票那一刻
    ///      就已按 FR-C-20 与奖池分账、可能早已被 `withdrawFees` 提走，退全款会击穿
    ///      偿付性。按净额退时，全部 Range 退完恰好等于 `pot`，分文不差。
    ///      每条 Range 都用与购票时**完全相同的算式**重算，避免批量公式引入取整偏差
    function refundAbandoned(uint32 roundId, uint256[] calldata rangeIndexes)
        external
        nonReentrant
    {
        _refundAbandoned(roundId, rangeIndexes, msg.sender);
    }

    /// @notice 同 refundAbandoned，但把票款退到指定地址。
    /// @dev 与 `claimTo` 同构、同理由，**不增加任何权限面**：Range 归属恒以
    ///      `msg.sender` 为准，`to` 只决定钱付到哪里。
    ///      存在的理由（第 50 轮 A-2）：FR-C-29 的退款通道晚于 `claimTo` 加入，
    ///      重新引入了 R20 M-1 那一类缺陷——没有 `receive`/`fallback` 的合约钱包
    ///      买了票、该期又卡死作废后，`refundAbandoned` 恒 revert `TransferFailed`。
    ///      而退款**没有** `rolloverExpired` 那样的过期兜底，这笔钱会永久留在
    ///      该期 `pot` 里，成为偿付性台账上一笔永远无法清偿的负债
    function refundAbandonedTo(uint32 roundId, uint256[] calldata rangeIndexes, address to)
        external
        nonReentrant
    {
        if (to == address(0)) revert InvalidRecipient();
        _refundAbandoned(roundId, rangeIndexes, to);
    }

    /// @dev refundAbandoned / refundAbandonedTo 的共用实现：Range 归属恒以
    ///      `msg.sender` 为准，`to` 只决定收款地址
    function _refundAbandoned(uint32 roundId, uint256[] calldata rangeIndexes, address to) private {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.ABANDONED) revert RoundNotAbandoned();
        TicketRange[] storage ranges = s_ranges[roundId];
        uint16 feeBps = r.feeBpsAtOpen;

        uint256 total = 0;
        for (uint256 i = 0; i < rangeIndexes.length; i++) {
            uint256 idx = rangeIndexes[i];
            if (idx >= ranges.length) revert TicketOutOfRange();
            TicketRange storage rg = ranges[idx];
            if (rg.owner != msg.sender) revert NotRangeOwner();
            if (s_rangeRefunded[roundId][idx]) revert AlreadyRefunded();
            s_rangeRefunded[roundId][idx] = true;
            uint256 cost = i_ticketPrice * (rg.end - rg.start);
            total += cost - (cost * feeBps) / BPS_DENOMINATOR;
        }
        if (total == 0) revert NothingToClaim();

        r.pot -= total;
        // 事件里记的是**购票者**（msg.sender），不是收款地址：与 PrizeClaimed 同一口径，
        // FR-C-25 的事件重建器据此归属退款，收款地址只是支付细节
        emit TicketsRefunded(roundId, msg.sender, total);
        _sendValue(to, total);
    }

    /// @notice 某条 Range 是否已退款（作废期用）
    function rangeRefunded(uint32 roundId, uint256 rangeIndex) external view returns (bool) {
        return s_rangeRefunded[roundId][rangeIndex];
    }

    /// @notice 领取累计的开奖奖励（pull 模式，FR-C-30）
    function claimKeeperReward() external nonReentrant {
        _claimKeeperReward(msg.sender);
    }

    /// @notice 同 claimKeeperReward，但把奖励付到指定地址。
    /// @dev 与 `claimTo` 同构、同理由，**不增加任何权限面**：奖励归属恒以
    ///      `msg.sender` 为准，`to` 只决定钱付到哪里。
    ///      存在的理由（第 50 轮 A-3）：`performUpkeep` 无权限，触发者常常是**合约**——
    ///      SPEC Q8 的 CRE 桥接器就是最典型的一个。没有 `receive`/`fallback` 的
    ///      触发者永远领不走自己的奖励，那笔已从 `s_accruedFees` 划出的钱就成了
    ///      `s_pendingKeeperRewards` 里一笔永远无法清偿的负债
    function claimKeeperRewardTo(address to) external nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        _claimKeeperReward(to);
    }

    /// @dev claimKeeperReward / claimKeeperRewardTo 的共用实现
    function _claimKeeperReward(address to) private {
        uint256 amount = s_keeperRewards[msg.sender];
        if (amount == 0) revert NoRewardToClaim();
        s_keeperRewards[msg.sender] = 0;
        s_pendingKeeperRewards -= amount;
        emit KeeperRewardClaimed(msg.sender, amount);
        _sendValue(to, amount);
    }

    /// @notice 某地址已记账、尚未领取的开奖奖励
    function keeperRewardOf(address keeper) external view returns (uint256) {
        return s_keeperRewards[keeper];
    }

    /// @notice 现在触发某期开奖能拿到多少奖励（前端用于在按钮上展示）。
    /// @dev 与 `_accrueKeeperReward` 完全同一套算式；该期若不可开奖或零票则为 0
    function pendingKeeperReward(uint32 roundId) external view returns (uint256) {
        Round storage r = s_rounds[roundId];
        if (r.state != RoundState.OPEN || r.ticketCount == 0) return 0;
        if (block.timestamp < uint256(r.closeTime) + SEAL_GAP) return 0;
        uint256 reward = _keeperRewardGross(r);
        if (reward > s_accruedFees) reward = s_accruedFees;
        return reward;
    }

    /// @notice 现在调 `withdrawFees` 实际能提走多少（= 累计抽成 − 为当期开奖奖励预留的部分）。
    /// @dev 前端应展示此值而非裸的 `s_accruedFees`，否则会对运营方虚报可提金额
    function withdrawableFees() external view returns (uint256) {
        uint256 accrued = s_accruedFees;
        uint256 reserved = _keeperRewardReserve();
        return accrued > reserved ? accrued - reserved : 0;
    }

    /// @notice 把已分账的运营抽成转给 treasury。任何人可触发，资金只会去 treasury。
    /// @dev **会为当期的开奖奖励预留一份**（至多一张票价，FR-C-30）。
    ///      不预留的话，`_accrueKeeperReward` 的第三道夹逼「不超过当下实际尚存的
    ///      accruedFees」就变成了一个人人可拉的断路器：本函数无权限、约 3 万 gas，
    ///      任何人在封盘期（停售 → 开奖之间、抽成不再增加的那 75 分钟）调一次，
    ///      本期的开奖奖励就恒为 0（第 50 轮 A-1，有 PoC）。那等于零成本架空 FR-C-30，
    ///      而 FR-C-30 存在的全部意义正是「运营方缺席时仍有人有理由接手」。
    ///      运营方自己例行提费同样会误伤，这一点比蓄意骚扰更可能发生。
    ///      预留额随本期抽成增长而增长（奖励 = 抽成的 20%，故留存永远够付），
    ///      并在该期开出后自动释放，不构成任何长期沉淀
    function withdrawFees() external nonReentrant {
        uint256 accrued = s_accruedFees;
        uint256 reserved = _keeperRewardReserve();
        uint256 amount = accrued > reserved ? accrued - reserved : 0;
        if (amount == 0) revert NoFeesToWithdraw();
        s_accruedFees = accrued - amount;
        address treasury = s_treasury;
        emit FeesWithdrawn(treasury, amount);
        _sendValue(treasury, amount);
    }

    // ===== owner 权限（仅限 FR-C-22 列出的三项）=====

    /// @notice 设置运营抽成接收地址
    /// @dev **treasury 必须能接收原生币**（EOA，或带 receive/fallback 且不会 revert
    ///      的合约）。这是 2026-08-11 改用原生币后**新增**的约束：ERC20 时代转账到
    ///      任何地址都能成功，现在收款方拒收会让 withdrawFees 永久 revert、抽成卡死。
    ///      无法在链上预先验证（只有真转一次才知道），因此由 owner 自行保证；
    ///      万一配错，改回可收款地址即可解冻，奖池不受影响（抽成与奖池分账，FR-C-20）
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

    /// @notice 暂停/恢复售票。只影响 buyTickets，领奖、滚存、重试开奖不受影响（FR-C-23）。
    /// @dev **对已开出的期无效**：能否购票在开期时快照定死（`salesPausedAtOpen`），
    ///      本设置只作用于此后开出的新期。这是为堵住「owner 全程暂停清场、末秒解禁自购、
    ///      独占整包奖池」而刻意付出的代价（审计第三轮 #1）——紧急停售因此最多延后一期生效。
    function setSalesPaused(bool paused) external onlyOwner {
        s_salesPaused = paused;
        emit SalesPausedUpdated(paused);
    }

    /// @notice 本期是否可购票（开期时的暂停快照）
    function salesOpenFor(uint32 roundId) external view returns (bool) {
        return !s_rounds[roundId].salesPausedAtOpen;
    }

    /// @notice 本期实际生效的抽成（开期快照）。全局 s_feeBps 只对此后开出的期生效，
    ///         前端必须用这个值展示，否则会对当期购票者误述费率
    function feeBpsOf(uint32 roundId) external view returns (uint16) {
        return s_rounds[roundId].feeBpsAtOpen;
    }

    /// @notice 本期结算时实际可分配的上限估算（配比释放后，FR-C-27）。
    ///         前端应展示此值而非原始 pot——两者在大额滚存 + 低参与度时可差数量级
    function distributableEstimate(uint32 roundId) external view returns (uint256) {
        Round storage r = s_rounds[roundId];
        uint256 selfSold = r.pot - r.carriedPot;
        uint256 budget = selfSold * CARRY_MATCH_MULTIPLIER;
        uint256 releasable = r.carriedPot < budget ? r.carriedPot : budget;
        budget -= releasable;
        uint256 tier1Releasable = r.tier1Carry < budget ? r.tier1Carry : budget;
        return selfSold + releasable + tier1Releasable;
    }

    /// @notice 本期 pot 中「非本期自售」的部分（滚存承接 + 注资），受参与度门槛保护
    function carriedPotOf(uint32 roundId) external view returns (uint256) {
        return s_rounds[roundId].carriedPot;
    }

    /// @notice 结算时刻与领奖截止时刻（窗口自结算起算，不受结算延迟影响）
    function claimDeadlineOf(uint32 roundId)
        external
        view
        returns (uint64 settledAt, uint64 claimDeadline)
    {
        settledAt = s_rounds[roundId].settledAt;
        claimDeadline = settledAt == 0 ? 0 : settledAt + CLAIM_WINDOW;
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

    /// @notice 已结算期的全部中奖票、中奖人与所属奖级（未开出的奖级不含在内）
    function winnersOf(uint32 roundId)
        external
        view
        returns (uint32[] memory winningTickets, address[] memory winners, uint8[] memory tiers)
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
        if (r.state != RoundState.SETTLED || block.timestamp > r.settledAt + CLAIM_WINDOW) {
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

    /// @notice 某期的 Range 总条数（配合 getRanges 分页）
    function rangeCountOf(uint32 roundId) external view returns (uint256) {
        return s_ranges[roundId].length;
    }

    /// @notice 分页读取某期的 Range 记录。
    /// @dev 必须分页：返回结构体数组的内存扩展成本是 O(N²)，一次性返回上万条会
    ///      超出节点的 eth_call gas 上限而直接报错——攻击者用大量单张购买灌 range
    ///      即可让前端视图对所有人失效（审计第四轮）。offset/limit 让调用方自控代价
    function getRanges(uint32 roundId, uint256 offset, uint256 limit)
        external
        view
        returns (TicketRange[] memory page)
    {
        TicketRange[] storage all = s_ranges[roundId];
        uint256 total = all.length;
        if (offset >= total) return new TicketRange[](0);
        // 不能写 offset + limit：limit = type(uint256).max 是「读到底」的自然写法，
        // 直接相加会溢出 panic（第四轮复查 L-2）
        uint256 end = limit > total - offset ? total : offset + limit;
        page = new TicketRange[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = all[i];
        }
    }

    /// @notice 某地址在某期持有的票数（测试界面用；正式前端走事件）
    /// @dev **无分页，成本与该期 Range 条数线性相关**，与 getRanges 不同。
    ///      实测约 500 gas/条：5 万条 range 时约 25M gas，会超出多数公共 RPC 的
    ///      eth_call 上限而报错。攻击者用大量单张购买灌 range 即可让此视图失效
    ///      （灌 5 万条的净成本约为票款的 1%，因为票款本身随中奖回到自己手里）。
    ///      刻意不改签名加分页：这是测试台便利函数，正式前端应由 TicketsBought
    ///      事件累加得出。调用方**必须**容忍它 revert，不得让它拖垮整个页面刷新。
    ///      注意写入路径不受影响——claim 走二分查找，恒为 O(log n)
    function ticketsOwned(uint32 roundId, address account) external view returns (uint256 count) {
        TicketRange[] storage ranges = s_ranges[roundId];
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].owner == account) {
                count += ranges[i].end - ranges[i].start;
            }
        }
    }

    // ===== 内部 =====

    /// @dev 给 performUpkeep 的调用者记账奖励（FR-C-30，pull 模式）。
    ///
    ///      **为什么必须是 pull 而不是当场转账**：performUpkeep 内部有
    ///      `try this.requestRandomWordsSelf()` 这个外部自调用，直接加 nonReentrant
    ///      会把自己挡在门外；而在函数中途给任意调用者转原生币则直接开了重入口子
    ///      （原生转账会执行接收方代码）。记账 + 另行领取一次解决两个问题，
    ///      也与 claim 的 pull 哲学一致（FR-C-17）。
    ///
    ///      **资金来源是该期自己的抽成，不动奖池分文**（FR-C-20 的分账仍然成立）。
    ///      三道夹逼缺一不可：
    ///        1. 按该期抽成的比例——而非历史累计。否则一个 1 张票的小期能把
    ///           之前大期赚的钱吸走
    ///        2. 上限一张票价——防止巨额期把抽成大比例送出去
    ///        3. 不超过实际尚存的 accruedFees——抽成可能已被 withdrawFees 提走，
    ///           不夹这一下会下溢
    function _accrueKeeperReward(uint32 roundId, Round storage r) private {
        uint256 reward = _keeperRewardGross(r);
        uint256 available = s_accruedFees;
        if (reward > available) reward = available; // 夹逼 ③，见 withdrawFees 的预留
        if (reward == 0) return;

        s_accruedFees -= reward;
        s_keeperRewards[msg.sender] += reward;
        s_pendingKeeperRewards += reward;
        emit KeeperRewarded(roundId, msg.sender, reward);
    }

    /// @dev 开奖奖励的毛额（只含前两道夹逼：按该期抽成的比例、上限一张票价）。
    ///      单独抽出来是为了让 `_accrueKeeperReward`、`pendingKeeperReward` 与
    ///      `withdrawFees` 的预留额三处共用同一套算式——它们一旦分叉，
    ///      要么界面报的数与实发的不一致，要么预留额不足以覆盖实发额
    function _keeperRewardGross(Round storage r) private view returns (uint256 reward) {
        // 该期抽成 = 票款总额 − 自售净额。两个数都已在链上，且与购票时
        // 「pot += cost - fee」逐笔对应，因此这个减法是精确的，无需新增存储。
        // 注资只进 pot 也只进 carriedPot，在差值里自动抵消，不会被误算成抽成
        uint256 gross = uint256(r.ticketCount) * i_ticketPrice;
        uint256 selfSold = r.pot - r.carriedPot; // carriedPot <= pot 恒成立
        reward = ((gross - selfSold) * KEEPER_REWARD_BPS) / BPS_DENOMINATOR;
        if (reward > i_ticketPrice) reward = i_ticketPrice; // 夹逼 ②
    }

    /// @dev `withdrawFees` 必须为「尚未开出的那一期」留下的开奖奖励。
    ///      只有仍处于 OPEN 的当期存在未记账的奖励：一旦离开 OPEN，
    ///      奖励要么已在 `performUpkeep` 里记账（DRAWING），要么按规则不发（VOIDED）
    function _keeperRewardReserve() private view returns (uint256) {
        Round storage r = s_rounds[s_currentRound];
        if (r.state != RoundState.OPEN) return 0;
        return _keeperRewardGross(r);
    }

    /// @dev 按自售额配比扣留超额 carry（FR-C-27）：本期可分配的滚存/注资上限 =
    ///      自售净额 × CARRY_MATCH_MULTIPLIER，超出部分退回缓冲顺延。
    ///      返回扣留后可供分账的 pot 与一等奖 carry
    function _withholdExcessCarry(uint32 roundId, uint256 pot, uint256 tier1CarryIn)
        private
        returns (uint256, uint256)
    {
        Round storage r = s_rounds[roundId];
        uint256 budget = (r.pot - r.carriedPot) * CARRY_MATCH_MULTIPLIER; // carriedPot <= pot 恒成立
        uint256 withheldPot = r.carriedPot > budget ? r.carriedPot - budget : 0;
        budget = r.carriedPot > budget ? 0 : budget - r.carriedPot;
        uint256 withheldTier1 = tier1CarryIn > budget ? tier1CarryIn - budget : 0;

        if (withheldPot > 0) {
            s_pendingPot += withheldPot;
            pot -= withheldPot;
            r.pot -= withheldPot; // 同步账面，避免 getRound 仍报告已被扣留的钱
            r.carriedPot -= withheldPot;
        }
        if (withheldTier1 > 0) {
            s_pendingTier1 += withheldTier1;
            tier1CarryIn -= withheldTier1;
            r.tier1Carry -= withheldTier1;
        }
        if (withheldPot + withheldTier1 > 0) {
            emit CarryWithheld(roundId, withheldPot + withheldTier1);
            emit PrizeRolledOver(roundId, 0, withheldPot + withheldTier1);
        }
        return (pot, tier1CarryIn);
    }

    /// @dev 开启下一期：closeTime 取日程中晚于当前时刻的最近场次（跳过已错过的场次，Q2）
    function _openNextRound() private returns (uint32 newId) {
        uint64 prevSlot = s_lastSlotTime;
        uint64 t = prevSlot;
        uint32 cursor = s_intervalCursor;
        uint32 len = uint32(s_intervals.length);
        // 跳过距今不足 MIN_SALES_WINDOW 的场次：performUpkeep 任何人可择时调用，
        // 若只要求 t > now，调用者可开出仅 1 秒售票窗口的期供自己独占（审计第三轮 #2）
        do {
            t += s_intervals[cursor];
            cursor = (cursor + 1) % len;
        } while (t <= block.timestamp + MIN_SALES_WINDOW);
        s_lastSlotTime = t;
        s_intervalCursor = cursor;

        newId = ++s_currentRound;
        Round storage r = s_rounds[newId];
        r.state = RoundState.OPEN;
        r.closeTime = t;
        // 暂停状态快照（审计第三轮 #1）：本期能否购票在开期时一次性定死。
        // 否则 owner 可全程暂停清场、末秒解禁自购，独占整包奖池
        r.salesPausedAtOpen = s_salesPaused;
        r.feeBpsAtOpen = s_feeBps; // 费率同样开期定死，防止对已开出期的购票抢跑抬价

        // 及时性闸：只有当本期拿到「足够完整」的售票窗口时才释放缓冲。
        // 名义窗口 = 上期开奖时刻 → 本期停售；实际窗口 = 现在 → 本期停售。
        // keeper 及时则两者接近；攻击者拖到临近场次才开期则实际窗口远小于名义，
        // 此时缓冲留待下一个由及时 keeper 开出的期，杜绝「自选短窗口再独占」
        uint64 prevDraw = prevSlot + SEAL_GAP;
        uint256 nominal = t > prevDraw ? t - prevDraw : 0;
        uint256 actual = t > block.timestamp ? t - block.timestamp : 0;
        // 用 bps 而非百分比：整数除法在 nominal 远大于 actual 时会归零，
        // 而正式日程「3 天」那一腿 nominal 达 70.75 小时，只要 keeper 稍晚
        // 就会算出 0%、缓冲一分不出——这正是要避免的冻结（第四轮复查 M-1）
        uint256 pctBps = nominal == 0 ? 10000 : (actual * 10000) / nominal;
        if (pctBps > 10000) pctBps = 10000;

        r.pot = 0;
        r.tier1Carry = 0;
        // 缓冲释放量按「售票窗口完整度」等比例打折：释放额 = 缓冲 × (实际窗口/名义窗口)。
        // performUpkeep 无权限、开期时刻由调用者选，攻击者可拖到临近下一场次才开期使窗口
        // 极短、再在同一笔交易里买光独占；打折使压缩窗口等比例削减可捕获额度。
        // **刻意不用 0/1 阈值**：
        // 0/1 门在 keeper 持续不及时时会让缓冲永远出不来（自查实测：6 期未释放），
        // 与上一轮「阶跃门槛导致永久冻结」是同一个坑。打折后压缩窗口只会减少本期
        // 可释放的额度（削弱择时独占的收益），而不会把资金卡死
        if (pctBps > 0) {
            uint256 releasePot = (s_pendingPot * pctBps) / 10000;
            uint256 releaseTier1 = (s_pendingTier1 * pctBps) / 10000;
            // 防粉尘冻结：余额极小时按比例仍会取整为 0，此时窗口过半就全额放行
            if (releasePot == 0 && s_pendingPot > 0 && pctBps >= 5000) releasePot = s_pendingPot;
            if (releaseTier1 == 0 && s_pendingTier1 > 0 && pctBps >= 5000) {
                releaseTier1 = s_pendingTier1;
            }
            r.pot += releasePot;
            r.tier1Carry += releaseTier1;
            s_pendingPot -= releasePot;
            s_pendingTier1 -= releaseTier1;
            if (releasePot + releaseTier1 > 0) {
                emit CarryReleased(newId, releasePot, releaseTier1);
            }
        }
        // 开期时 pot 全部来自 carry（本期尚无自售），据此建立配比释放的基线
        r.carriedPot = r.pot;
        emit RoundOpened(newId, t);
    }

    /// @dev 原生币转出：用 call 而非 transfer/send（后者 2300 gas 上限会让多签等
    ///      合约钱包收不到款）。必须检查返回值——call 失败只返回 false 不会自动 revert
    function _sendValue(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice 仅供本合约自调用，用于把 VRF 请求包进 try/catch。外部调用一律拒绝
    function requestRandomWordsSelf() external returns (uint256) {
        if (msg.sender != address(this)) revert OnlySelf();
        return _requestRandomWords();
    }

    /// @dev 请求发往当前随机源。跟随 s_vrfCoordinator 是**刻意的**：官方迁移后
    ///      订阅只存在于新 coordinator 上，钉死旧地址会让请求永远失败（SPEC Q9）
    function _requestRandomWords() private returns (uint256 requestId) {
        return IVRFCoordinatorV2Plus(address(s_vrfCoordinator))
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
    /// @dev **前置条件：该期至少有一条 Range**（即 ticketCount >= 1）。
    ///      下面的 `ranges.length - 1` 在空数组上会下溢 panic。当前所有调用点都被
    ///      `state == SETTLED`（蕴含 ticketCount >= 1，因为零票期走 VOIDED）或
    ///      `ticketId < ticketCount` 挡住，实际不可达；新增视图函数时必须保持这个不变量（R20 I-3）
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

    /// @dev 派生全部已开出奖级的中奖票、中奖人与所属奖级。
    ///      返回 tiers 是为了让前端不必假设奖级按前缀顺序开出（非单调 winnerCounts 配置下
    ///      会错标），也让 FR-C-25 的 WinnersPicked 事件仅靠自身即可还原奖级（审计 D）
    function _deriveWinners(uint32 roundId)
        private
        view
        returns (uint32[] memory tickets, address[] memory winners, uint8[] memory tiers)
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
        tiers = new uint8[](openSlots);
        uint256 idx = 0;
        for (uint8 tier = 0; tier < tierCount; tier++) {
            if (s_perWinnerAmount[roundId][tier] == 0) continue;
            (uint8 slotStart, uint8 count) = _tierSlots(tier);
            for (uint8 j = 0; j < count; j++) {
                uint32 ticketId = _winningTicket(r.randomSeed, slotStart + j, r.ticketCount);
                tickets[idx] = ticketId;
                winners[idx] = _ownerOfTicket(roundId, ticketId);
                tiers[idx] = tier;
                idx++;
            }
        }
    }
}
