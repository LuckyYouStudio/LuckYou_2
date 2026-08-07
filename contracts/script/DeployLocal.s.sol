// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Lottery} from "../src/Lottery.sol";
import {LocalTestbed} from "./helpers/LocalTestbed.sol";

/// @notice 本地（anvil）一键部署：Mock USDC + VRF mock + Lottery，
///         预铸测试资金，并把地址写入 web/src/lib/deployment.local.json 供测试前端读取。
///         本地没有 Chainlink keeper/VRF 节点，开奖由前端按钮手动触发与模拟回调。
contract DeployLocal is Script {
    // anvil 默认助记词的前三个账户 + 末位账户（treasury）
    address constant ANVIL_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant ANVIL_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant ANVIL_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address constant ANVIL_9 = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720;

    function run() external {
        require(block.chainid == 31337, "DeployLocal: anvil only");

        address[] memory funded = new address[](3);
        funded[0] = ANVIL_0;
        funded[1] = ANVIL_1;
        funded[2] = ANVIL_2;

        vm.startBroadcast();
        LocalTestbed testbed = new LocalTestbed(ANVIL_9, msg.sender, funded);
        Lottery lottery = testbed.lottery();
        lottery.acceptOwnership();
        vm.stopBroadcast();

        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "lottery", address(lottery));
        vm.serializeAddress(json, "usdc", address(testbed.usdc()));
        vm.serializeAddress(json, "vrfCoordinator", address(testbed.coordinator()));
        vm.serializeAddress(json, "treasury", ANVIL_9);
        string memory out = vm.serializeString(json, "subId", vm.toString(testbed.subId()));
        vm.writeJson(out, "../web/src/lib/deployment.local.json");

        console.log("Lottery:        ", address(lottery));
        console.log("Mock USDC:      ", address(testbed.usdc()));
        console.log("VRF Coordinator:", address(testbed.coordinator()));
        console.log("deployment.local.json written to web/src/lib/");
    }
}
