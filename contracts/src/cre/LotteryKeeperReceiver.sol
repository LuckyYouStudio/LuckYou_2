// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTemplate} from "./ReceiverTemplate.sol";

interface ILotteryUpkeep {
    function performUpkeep(bytes calldata performData) external;
}

/// @title CRE keeper 桥接接收器
/// @notice Chainlink CRE 工作流的链上落点（SPEC Q8）：CRE 的写入只能投递到实现
///         IReceiver 的合约，本合约验证报告来自 KeystoneForwarder 后转调彩票的
///         performUpkeep。performUpkeep 本就任何人可调（keeper 不在信任边界内），
///         桥接器不引入新的权限面。
contract LotteryKeeperReceiver is ReceiverTemplate {
    error ExecutionNotRequested();
    error InvalidLotteryAddress();

    event UpkeepForwarded(address indexed lottery, uint256 timestamp);

    ILotteryUpkeep public immutable i_lottery;

    /// @param forwarder 本链的 CRE KeystoneForwarder 地址
    /// @param lottery 彩票合约地址
    constructor(address forwarder, address lottery) ReceiverTemplate(forwarder) {
        if (lottery == address(0)) revert InvalidLotteryAddress();
        i_lottery = ILotteryUpkeep(lottery);
    }

    /// @dev 报告负载为 abi.encode(bool shouldExecute)，由工作流在链下判定
    ///      checkUpkeep 为真后发出
    function _processReport(bytes calldata report) internal override {
        bool shouldExecute = abi.decode(report, (bool));
        if (!shouldExecute) revert ExecutionNotRequested();
        i_lottery.performUpkeep("");
        emit UpkeepForwarded(address(i_lottery), block.timestamp);
    }
}
