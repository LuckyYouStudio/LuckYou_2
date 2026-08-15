// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Lottery} from "../src/Lottery.sol";

/// @notice 测试网手动交互脚本（FR-D-03）。需要环境变量 LOTTERY_ADDRESS。
///
/// 用法示例：
///   forge script script/Interact.s.sol --sig "status()" --rpc-url $BASE_SEPOLIA_RPC_URL
///   forge script script/Interact.s.sol --sig "buy(uint32)" 10 \
///     --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
///   forge script script/Interact.s.sol --sig "poke()" ... --broadcast   # 手动触发开奖
///   forge script script/Interact.s.sol --sig "claimAll(uint32)" 1 ... --broadcast
contract Interact is Script {
    string[5] private STATE_NAMES = ["NONE", "OPEN", "DRAWING", "SETTLED", "VOIDED"];

    function _lottery() internal view returns (Lottery) {
        return Lottery(vm.envAddress("LOTTERY_ADDRESS"));
    }

    /// @notice 查询当前期与最近几期状态
    function status() external view {
        Lottery lottery = _lottery();
        uint32 cur = lottery.s_currentRound();
        console.log(unicode"当前期:", cur);
        console.log(unicode"链上时间:", block.timestamp);
        console.log(unicode"售票暂停:", lottery.s_salesPaused());
        console.log(unicode"累计抽成:", lottery.s_accruedFees());
        uint32 from = cur >= 3 ? cur - 2 : 1;
        for (uint32 id = cur; id >= from; id--) {
            (
                Lottery.RoundState st,
                uint64 closeTime,
                uint64 drawTime,
                uint32 ticketCount,
                uint256 pot,
                uint256 carry,,,
            ) = lottery.getRound(id);
            console.log("----------------------------------");
            console.log(unicode"期号:", id);
            console.log(unicode"状态:", STATE_NAMES[uint8(st)]);
            console.log(unicode"票数:", ticketCount);
            console.log(unicode"奖池:", pot);
            console.log(unicode"滚入一等奖:", carry);
            console.log(unicode"停售:", closeTime);
            console.log(unicode"开奖:", drawTime);
            if (id == 1) break;
        }
    }

    /// @notice 购票（原生 ETH，无需 approve）
    function buy(uint32 quantity) external {
        Lottery lottery = _lottery();
        uint256 cost = lottery.i_ticketPrice() * quantity;
        vm.startBroadcast();
        uint32 _rid1 = lottery.s_currentRound();
        lottery.buyTickets{value: cost}(quantity, _rid1);
        vm.stopBroadcast();
        console.log(unicode"已购票（张）:", quantity);
        console.log(unicode"支付（wei）:", cost);
    }

    /// @notice 到点后手动触发开奖（keeper 的手动替身）
    function poke() external {
        Lottery lottery = _lottery();
        (bool needed,) = lottery.checkUpkeep("");
        require(needed, unicode"未到开奖时刻或当前期不可开奖");
        vm.startBroadcast();
        lottery.performUpkeep("");
        vm.stopBroadcast();
        console.log(unicode"已触发开奖，等待 VRF 回调");
    }

    /// @notice VRF 超时后重试
    function retry(uint32 roundId) external {
        vm.startBroadcast();
        _lottery().retryDraw(roundId);
        vm.stopBroadcast();
        console.log(unicode"已重新请求 VRF:", roundId);
    }

    /// @notice 领取某期全部本人奖金
    function claimAll(uint32 roundId) external {
        Lottery lottery = _lottery();
        uint256[] memory pending = lottery.pendingPrizes(roundId, msg.sender);
        vm.startBroadcast();
        for (uint8 tier = 0; tier < pending.length; tier++) {
            if (pending[tier] > 0) {
                lottery.claim(roundId, tier);
                console.log(unicode"已领取奖级/金额:", tier, pending[tier]);
            }
        }
        vm.stopBroadcast();
    }

    /// @notice 把过期未领奖金滚入当前期
    function rollover(uint32 roundId) external {
        vm.startBroadcast();
        _lottery().rolloverExpired(roundId);
        vm.stopBroadcast();
        console.log(unicode"已滚存过期奖金:", roundId);
    }
}
