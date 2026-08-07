// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Lottery} from "../src/Lottery.sol";

/// @notice 正式网络部署脚本（FR-D-01）：按 block.chainid 区分 Base Sepolia 与 Base 主网。
///
/// 链上配置来源（2026-08-07 自官方文档核实，勿凭记忆改动）：
/// - VRF v2.5：https://docs.chain.link/vrf/v2-5/supported-networks
/// - USDC（Circle 官方）：https://developers.circle.com/stablecoins/usdc-contract-addresses
///
/// 用法：
///   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY --broadcast --verify
/// 需要环境变量：VRF_SUBSCRIPTION_ID、TREASURY_ADDRESS（FR-D-04）
contract Deploy is Script {
    struct NetworkConfig {
        string name;
        address vrfCoordinator;
        bytes32 keyHash;
        address usdc;
    }

    error UnsupportedChain(uint256 chainId);

    function run() external returns (Lottery lottery) {
        NetworkConfig memory cfg = _configFor(block.chainid);
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        // 双色球日程：锚点取最近一个已过去的周二 12:00 UTC（北京时间 20:00 停售），
        // 间隔循环 [2 天, 3 天, 2 天] → 周二/周四/周日（SPEC 第 9 节 Q2）
        uint64 anchor = _lastTuesdayNoonUtc();
        uint32[] memory intervals = new uint32[](3);
        intervals[0] = 2 days;
        intervals[1] = 3 days;
        intervals[2] = 2 days;

        // 奖级：60% / 25%（2 名）/ 15%（5 名）（FR-C-13、Q5）
        uint16[] memory tierBps = new uint16[](3);
        tierBps[0] = 6000;
        tierBps[1] = 2500;
        tierBps[2] = 1500;
        uint8[] memory tierWinners = new uint8[](3);
        tierWinners[0] = 1;
        tierWinners[1] = 2;
        tierWinners[2] = 5;

        vm.startBroadcast();
        lottery = new Lottery(
            cfg.vrfCoordinator,
            subId,
            cfg.keyHash,
            cfg.usdc,
            1e6, // 票价 1 USDC（Q4，USDC 为 6 位精度）
            anchor,
            intervals,
            treasury,
            100, // 默认抽成 1%（FR-C-21）
            tierBps,
            tierWinners
        );
        vm.stopBroadcast();

        // FR-D-02：部署后待办清单
        console.log("==============================================");
        console.log(unicode"部署完成：", cfg.name);
        console.log("Lottery:", address(lottery));
        console.log(unicode"首期停售时间（unix）:", _firstClose(anchor, intervals));
        console.log("==============================================");
        console.log(unicode"待办清单（缺一不可，否则无法开奖）：");
        console.log(unicode"  1. 在 https://vrf.chain.link 打开订阅", subId);
        console.log(unicode"     -> Add consumer:", address(lottery));
        console.log(unicode"     -> 确保订阅有足够 LINK 余额（建议 >= 5 LINK）");
        console.log(unicode"  2. 在 https://automation.chain.link 注册 Custom logic upkeep");
        console.log(unicode"     -> Target contract:", address(lottery));
        console.log(unicode"     -> Gas limit 建议 1500000，充值 LINK（建议 >= 5 LINK）");
        console.log(unicode"  3. 运行 web/scripts/sync-abi.mjs 并更新前端 deployment 配置");
    }

    function _configFor(uint256 chainId) internal pure returns (NetworkConfig memory) {
        if (chainId == 84532) {
            return NetworkConfig({
                name: "Base Sepolia",
                vrfCoordinator: 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE,
                keyHash: 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71, // 30 gwei lane
                usdc: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
            });
        }
        if (chainId == 8453) {
            return NetworkConfig({
                name: "Base Mainnet",
                vrfCoordinator: 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634,
                keyHash: 0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab, // 2 gwei lane
                usdc: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
            });
        }
        revert UnsupportedChain(chainId); // 本地请用 DeployLocal.s.sol
    }

    /// @dev 最近一个已过去的周二 12:00 UTC。unix 纪元（1970-01-01）是周四，
    ///      按 0=周四 记日序，周二 = 5
    function _lastTuesdayNoonUtc() internal view returns (uint64) {
        uint256 daysSinceEpoch = block.timestamp / 1 days;
        uint256 daysBackToTuesday = (daysSinceEpoch % 7 + 7 - 5) % 7;
        uint256 tuesdayNoon = (daysSinceEpoch - daysBackToTuesday) * 1 days + 12 hours;
        if (tuesdayNoon > block.timestamp) {
            tuesdayNoon -= 7 days; // 今天恰是周二且未到 12:00
        }
        return uint64(tuesdayNoon);
    }

    function _firstClose(uint64 anchor, uint32[] memory intervals) internal view returns (uint256) {
        uint256 t = anchor;
        uint256 i = 0;
        while (t <= block.timestamp) {
            t += intervals[i];
            i = (i + 1) % intervals.length;
        }
        return t;
    }
}
