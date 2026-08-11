// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    VRFCoordinatorV2_5Mock
} from "@chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {Lottery} from "../../src/Lottery.sol";

/// @notice 本地测试台：在单笔交易内完成全部部署与接线。
///         VRF mock 的 subId 由 blockhash 派生，拆成多笔交易会导致脚本模拟值与
///         链上实际值不一致，因此必须在一个构造函数里一气呵成。
contract LocalTestbed {
    VRFCoordinatorV2_5Mock public immutable coordinator;
    Lottery public immutable lottery;
    uint256 public immutable subId;

    constructor(address treasury, address pendingOwner) {
        coordinator = new VRFCoordinatorV2_5Mock(0.1 ether, 1e9, 4e15);
        subId = coordinator.createSubscription();
        coordinator.fundSubscription(subId, 1000 ether);

        // 本地用 2 小时一场的紧凑日程（> SEAL_GAP 75 分钟），配合前端时间快进使用
        uint32[] memory intervals = new uint32[](1);
        intervals[0] = 2 hours;

        uint16[] memory tierBps = new uint16[](3);
        tierBps[0] = 6000;
        tierBps[1] = 2500;
        tierBps[2] = 1500;
        uint8[] memory tierWinners = new uint8[](3);
        tierWinners[0] = 1;
        tierWinners[1] = 2;
        tierWinners[2] = 5;

        lottery = new Lottery(
            address(coordinator),
            subId,
            bytes32(uint256(1)), // 本地 mock 不校验 keyHash
            0.0001 ether, // 票价（FR-C-01）
            uint64(block.timestamp),
            intervals,
            treasury,
            100, // 1% 抽成
            tierBps,
            tierWinners
        );
        coordinator.addConsumer(subId, address(lottery));

        // 把 owner 移交给部署者（ConfirmedOwner 两步制，需部署者随后 acceptOwnership）
        lottery.transferOwnership(pendingOwner);
    }
}
