// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";

interface ILotteryUpkeep {
    function performUpkeep(bytes calldata performData) external;
    function claimKeeperReward() external;
    function keeperRewardOf(address keeper) external view returns (uint256);
}

/// @title CRE keeper 桥接接收器
/// @notice Chainlink CRE 工作流的链上落点（SPEC Q8）：CRE 的写入只能投递到实现
///         IReceiver 的合约，本合约验证报告来自 KeystoneForwarder 后转调彩票的
///         performUpkeep。performUpkeep 本就任何人可调（keeper 不在信任边界内），
///         桥接器不引入新的权限面。
/// @dev **为什么本合约必须能收款、能领奖励**（第 50 轮 A-3）：转调 performUpkeep
///      时 `msg.sender` 是本合约，于是 FR-C-30 的开奖奖励记在**本合约**名下。
///      初版既没有领取路径、也没有 `receive`，那笔奖励因此永久锁死：每一期都有
///      最多一张票价的运营抽成被烧进一个取不出的余额，而彩票侧的
///      `s_pendingKeeperRewards` 会单调增长成一笔永远无法清偿的负债。
///      修法是给它一条**无权限、无自由裁量**的出口：奖励只能流向构造时钉死的
///      `i_rewardBeneficiary`，谁来按都一样，本合约不因此获得任何新权限。
contract LotteryKeeperReceiver is ReceiverTemplate {
    error ExecutionNotRequested();
    error InvalidLotteryAddress();
    error InvalidBeneficiary();
    error NothingToSweep();
    error SweepTransferFailed();

    event UpkeepForwarded(address indexed lottery, uint256 timestamp);
    event KeeperRewardSwept(address indexed beneficiary, uint256 amount);

    ILotteryUpkeep public immutable i_lottery;
    /// @notice 开奖奖励的最终去向。**构造时钉死、无 setter**——本合约的全部价值
    ///         在于它没有可被滥用的杠杆，一个可改的收款地址会重新引入一个
    address public immutable i_rewardBeneficiary;

    /// @param forwarder 本链的 CRE KeystoneForwarder 地址
    /// @param lottery 彩票合约地址
    /// @param rewardBeneficiary 开奖奖励的最终收款地址，**必须能接收原生币**
    constructor(address forwarder, address lottery, address rewardBeneficiary)
        ReceiverTemplate(forwarder)
    {
        if (lottery == address(0)) revert InvalidLotteryAddress();
        if (rewardBeneficiary == address(0)) revert InvalidBeneficiary();
        i_lottery = ILotteryUpkeep(lottery);
        i_rewardBeneficiary = rewardBeneficiary;
    }

    /// @notice 把本合约名下累计的开奖奖励领出并转给 `i_rewardBeneficiary`。
    /// @dev **无权限**：金额与去向完全由链上状态决定，调用者选不了任何东西，
    ///      因此与 FR-C-24 的立意一致（该条禁的是「管理员能动到未领奖金」）。
    ///      先领后扫余额而非只转领到的那一笔：本合约若因任何原因还留有零星余额
    ///      （例如彩票侧曾用 `claimKeeperRewardTo` 付进来），一并清出去，
    ///      免得它变成第二个取不出的沉淀
    function sweepKeeperReward() external {
        if (i_lottery.keeperRewardOf(address(this)) > 0) {
            i_lottery.claimKeeperReward();
        }
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToSweep();
        emit KeeperRewardSwept(i_rewardBeneficiary, amount);
        (bool ok,) = payable(i_rewardBeneficiary).call{value: amount}("");
        if (!ok) revert SweepTransferFailed();
    }

    /// @notice 接收彩票派发的开奖奖励。**只是一个中转站**——收到的钱只能经
    ///         `sweepKeeperReward` 流向钉死的 `i_rewardBeneficiary`，没有别的出口
    receive() external payable {}

    /// @dev 报告负载为 abi.encode(bool shouldExecute)，由工作流在链下判定
    ///      checkUpkeep 为真后发出
    function _processReport(bytes calldata report) internal override {
        bool shouldExecute = abi.decode(report, (bool));
        if (!shouldExecute) revert ExecutionNotRequested();
        i_lottery.performUpkeep("");
        emit UpkeepForwarded(address(i_lottery), block.timestamp);
    }
}
