// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Lottery} from "../src/Lottery.sol";

/// @notice 正式网络部署脚本（FR-D-01）：按 block.chainid 区分 Base Sepolia 与 Base 主网。
///
/// 链上配置来源（2026-08-07 自官方文档核实，勿凭记忆改动）：
/// - VRF v2.5：https://docs.chain.link/vrf/v2-5/supported-networks
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
    }

    error UnsupportedChain(uint256 chainId);

    function run() external returns (Lottery lottery) {
        NetworkConfig memory cfg = _configFor(block.chainid);
        uint256 subId = vm.envUint("VRF_SUBSCRIPTION_ID");
        address treasury = vm.envAddress("TREASURY_ADDRESS");

        // 双色球日程：锚点取最近一个已过去的周二 12:00 UTC（北京时间 20:00 停售），
        // 间隔循环 [2 天, 3 天, 2 天] → 周二/周四/周日（SPEC 第 9 节 Q2）。
        // 设置 FAST_INTERVAL_SECONDS 可部署快节奏验证实例（仅测试网，见下方 require）。
        // 取值须 > SEAL_GAP + MIN_SALES_WINDOW = 6300 秒（105 分钟），推荐 7200。
        // 注意：日程在构造时定死、全合约无 setter，配错只能重新部署
        uint64 anchor;
        uint32[] memory intervals;
        uint256 fastInterval = vm.envOr("FAST_INTERVAL_SECONDS", uint256(0));
        // 快节奏日程仅限测试网：日程在构造时定死且无 setter，若 .env 里残留这一行
        // 就把主网部署成 2 小时循环，将永久无法修复（审计第四轮 D-1）
        require(fastInterval == 0 || block.chainid == 84532, "FAST_INTERVAL_SECONDS: testnet only");
        // 合约要求 interval > SEAL_GAP + MIN_SALES_WINDOW = 75min + 30min = 6300 秒
        require(fastInterval == 0 || fastInterval > 6300, "FAST_INTERVAL_SECONDS: must exceed 6300");
        require(fastInterval <= type(uint32).max, "FAST_INTERVAL_SECONDS: overflows uint32");
        if (fastInterval > 0) {
            anchor = uint64(block.timestamp);
            intervals = new uint32[](1);
            intervals[0] = uint32(fastInterval);
            console.log(unicode"!! 快节奏验证实例，间隔（秒）:", fastInterval);
        } else {
            anchor = _lastTuesdayNoonUtc();
            intervals = new uint32[](3);
            intervals[0] = 2 days;
            intervals[1] = 3 days;
            intervals[2] = 2 days;
        }

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
            0.0001 ether, // 票价（FR-C-01，2026-08-11 由 1 USDC 改为原生 ETH）
            anchor,
            intervals,
            treasury,
            100, // 默认抽成 1%（FR-C-21）
            tierBps,
            tierWinners
        );
        vm.stopBroadcast();

        // 写前端配置（仅测试网；主网前端配置应人工审核后更新）。
        // 仅在真实广播时写：dry run 也覆写会把前端指向一个从未部署的地址（审计第四轮 D-12）
        if (block.chainid == 84532 && vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory json = "deployment";
            vm.serializeUint(json, "chainId", block.chainid);
            vm.serializeUint(json, "startBlock", block.number);
            vm.serializeAddress(json, "lottery", address(lottery));
            vm.serializeAddress(json, "vrfCoordinator", cfg.vrfCoordinator);
            // 不写 subId：FR-D-04 禁止订阅 ID 出现在任何提交的文件里，
            // 而这个 JSON 是要提交的前端配置（前端也不需要它）
            string memory out = vm.serializeAddress(json, "treasury", treasury);
            vm.writeJson(out, "../web/src/lib/deployment.base-sepolia.json");
        }

        // FR-D-02：部署后待办清单
        console.log("==============================================");
        console.log(unicode"部署完成：", cfg.name);
        console.log("Lottery:", address(lottery));
        // 直接读实例状态，而非在脚本里重算日程——重算过 MIN_SALES_WINDOW 这一关时
        // 会与合约结论不一致（审计第四轮 D-11）
        (, uint64 firstCloseTime, uint64 firstDrawTime,,,,,,) = lottery.getRound(1);
        console.log(unicode"首期停售时间（unix）:", firstCloseTime);
        console.log(unicode"首期开奖时间（unix）:", firstDrawTime);
        console.log("==============================================");
        console.log(unicode"待办清单（缺一不可，否则无法开奖）：");
        console.log(unicode"  1. 在 https://vrf.chain.link 打开订阅", subId);
        console.log(unicode"     -> Add consumer:", address(lottery));
        console.log(unicode"     -> 确保订阅有足够 LINK 余额（建议 >= 5 LINK）");
        console.log(
            unicode"  2. 启动 keeper（Chainlink Automation 已弃用，用自托管轮询"
        );
        console.log(unicode"     或 CRE 工作流）：checkUpkeep 为真时调用 performUpkeep");
        console.log(unicode"     -> Target contract:", address(lottery));
        console.log(unicode"  3. 运行 web/scripts/sync-abi.mjs 并更新前端 deployment 配置");
    }

    function _configFor(uint256 chainId) internal pure returns (NetworkConfig memory) {
        if (chainId == 84532) {
            return NetworkConfig({
                name: "Base Sepolia",
                vrfCoordinator: 0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE,
                keyHash: 0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71 // 30 gwei lane
            });
        }
        if (chainId == 8453) {
            return NetworkConfig({
                name: "Base Mainnet",
                vrfCoordinator: 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634,
                keyHash: 0x00b81b5a830cb0a4009fbd8904de511e28631e62ce5ad231373d3cdad373ccab // 2 gwei lane
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
}
