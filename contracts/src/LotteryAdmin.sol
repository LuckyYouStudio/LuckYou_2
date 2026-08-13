// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Lottery 的**窄接口**。这份接口刻意只列出三个业务函数与一次性的
///      acceptOwnership —— 它的价值恰恰在于**没有列出的那些**：
///      没有 setCoordinator、没有 transferOwnership、没有任何通用调用入口。
///      本合约因此在字节码层面就不具备发出那些调用的能力。
interface ILotteryAdminTarget {
    function acceptOwnership() external;
    function setTreasury(address treasury) external;
    function setFeeBps(uint16 feeBps) external;
    function setSalesPaused(bool paused) external;
}

/// @title Lottery 的最小权限管理合约（SPEC Q9 方案 B）
/// @notice 持有 Lottery 的所有权，只转发 FR-C-22 允许的三项业务权限。
///
/// @dev **为什么需要它。**
///      `VRFConsumerBaseV2Plus.setCoordinator` 的修饰符是 `onlyOwnerOrCoordinator`
///      且非 virtual（无法 override 封禁）。这带来两条都不可恢复的风险：
///        1. owner 私钥失窃 ⇒ 攻击者换掉随机源 ⇒ 可离线挑选种子稳中头奖；
///        2. 若为防 (1) 而把 coordinator 钉死，Chainlink **官方订阅迁移**
///           （`migrate` 会替每个 consumer 调 `setCoordinator`）就会被误判为篡改，
///           导致全部奖池永久冻结，而 FR-C-24 禁止任何救援手段。
///
///      把 Lottery 的 owner 换成本合约后，`onlyOwnerOrCoordinator` 的两个分支里：
///        - owner 分支 = 本合约，而本合约**没有任何代码路径**能调 setCoordinator；
///        - coordinator 分支 = 只有真正的 coordinator，即只有合法迁移。
///      于是杠杆从权限侧被物理消除，Lottery 便可安全地让随机源跟随 s_vrfCoordinator。
///
/// @dev **刻意不提供的东西（改动前请三思）：**
///      - 通用 `execute(address,bytes)` / `call` / `delegatecall` —— 有其一即可编码出
///        对 setCoordinator 的调用，本合约的全部意义随之归零；
///      - 转发 Lottery 的 `transferOwnership` —— 有它就能把所有权交回 EOA，同样归零；
///      - 可升级性 —— 违反 SPEC 第 1.2 节。
///
/// @dev **代价（已在 Q9 中接受）**：Lottery 的所有权自此永久绑定在本合约上。
///      本合约若有 bug，三项业务权限一起失去。但**奖池不受影响**——
///      那三项权限本来就动不了奖池（FR-C-24）。
contract LotteryAdmin {
    ILotteryAdminTarget public immutable i_lottery;

    address public s_owner;
    address public s_pendingOwner;

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();

    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        if (msg.sender != s_owner) revert NotOwner();
        _;
    }

    /// @param lottery 目标 Lottery
    /// @param initialOwner 本合约的所有者（**应当**是多签）
    constructor(address lottery, address initialOwner) {
        if (lottery == address(0) || initialOwner == address(0)) revert ZeroAddress();
        i_lottery = ILotteryAdminTarget(lottery);
        s_owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    // ===== Lottery 所有权接管 =====

    /// @notice 接受 Lottery 的所有权转让（ConfirmedOwner 的两步流程的第二步）。
    /// @dev 无权限：这一步只能在 Lottery 现任 owner 已经把所有权指向本合约时成功，
    ///      因此谁来调都一样，不构成攻击面
    function acceptLotteryOwnership() external {
        i_lottery.acceptOwnership();
    }

    // ===== FR-C-22 允许的三项业务权限（且仅此三项）=====

    /// @notice 设置运营抽成接收地址。注意 treasury **必须能接收原生币**（FR-C-22）
    function setTreasury(address treasury) external onlyOwner {
        i_lottery.setTreasury(treasury);
    }

    /// @notice 设置抽成比例（Lottery 侧有 MAX_FEE_BPS 硬上限，本合约不再重复校验）
    function setFeeBps(uint16 feeBps) external onlyOwner {
        i_lottery.setFeeBps(feeBps);
    }

    /// @notice 暂停/恢复售票。只影响此后开出的新期（FR-C-23 快照语义）
    function setSalesPaused(bool paused) external onlyOwner {
        i_lottery.setSalesPaused(paused);
    }

    // ===== 本合约自身的所有权（两步转让）=====
    // 注意：这转让的是**本合约**的控制权，不是 Lottery 的所有权。
    // Lottery 的 owner 永远是本合约，这正是设计意图

    /// @notice 发起本合约所有权转让（两步的第一步，防误转到无法签名的地址）
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        s_pendingOwner = newOwner;
        emit OwnershipTransferStarted(s_owner, newOwner);
    }

    /// @notice 接受本合约所有权
    function acceptOwnership() external {
        if (msg.sender != s_pendingOwner) revert NotPendingOwner();
        address previous = s_owner;
        s_owner = msg.sender;
        s_pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }
}
