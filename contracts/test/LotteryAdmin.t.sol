// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Lottery} from "../src/Lottery.sol";
import {LotteryAdmin} from "../src/LotteryAdmin.sol";
import {LotteryTestBase} from "./Lottery.t.sol";

/// @dev `LotteryAdmin` 自身的行为（SPEC Q9 方案 B）。
///      换源杠杆已消除这一点由 `LotteryVrfHijack.t.sol` 覆盖；这里覆盖的是
///      **本合约自己的所有权流转**——它一旦有 bug，Lottery 的三项业务权限会
///      永久失去（奖池不受影响，但那仍是不可逆的运营事故）
contract LotteryAdminTest is LotteryTestBase {
    LotteryAdmin internal admin;

    function setUp() public override {
        super.setUp();
        admin = new LotteryAdmin(address(lottery), address(this));
        lottery.transferOwnership(address(admin));
        admin.acceptLotteryOwnership();
    }

    function test_ConstructorWiring() public view {
        assertEq(address(admin.i_lottery()), address(lottery));
        assertEq(admin.s_owner(), address(this));
        assertEq(admin.s_pendingOwner(), address(0));
        assertEq(lottery.owner(), address(admin), "admin holds the lottery");
    }

    function test_RevertWhen_ConstructedWithZeroAddress() public {
        vm.expectRevert(LotteryAdmin.ZeroAddress.selector);
        new LotteryAdmin(address(0), address(this));
        vm.expectRevert(LotteryAdmin.ZeroAddress.selector);
        new LotteryAdmin(address(lottery), address(0));
    }

    /// @dev 接管 Lottery 所有权无需权限：只有在 Lottery 现任 owner 已把所有权
    ///      指向本合约时才可能成功，谁来调都一样
    function test_AcceptLotteryOwnershipIsPermissionless() public {
        LotteryAdmin fresh = new LotteryAdmin(address(lottery), address(this));
        vm.prank(address(admin));
        lottery.transferOwnership(address(fresh));
        vm.prank(alice); // 无关第三方
        fresh.acceptLotteryOwnership();
        assertEq(lottery.owner(), address(fresh));
    }

    // ===== 本合约自身的两步所有权转让 =====

    function test_TwoStepOwnershipTransfer() public {
        admin.transferOwnership(alice);
        assertEq(admin.s_pendingOwner(), alice);
        assertEq(admin.s_owner(), address(this), "owner unchanged until accepted");

        vm.prank(alice);
        admin.acceptOwnership();
        assertEq(admin.s_owner(), alice);
        assertEq(admin.s_pendingOwner(), address(0), "pending cleared");

        // 新 owner 可用，旧 owner 已失效
        vm.prank(alice);
        admin.setFeeBps(300);
        assertEq(lottery.s_feeBps(), 300);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.setFeeBps(400);
    }

    function test_RevertWhen_NonOwnerTransfersOwnership() public {
        vm.prank(alice);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.transferOwnership(alice);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.expectRevert(LotteryAdmin.ZeroAddress.selector);
        admin.transferOwnership(address(0));
    }

    /// @dev 两步转让的意义：只有被指定的那个地址能接受，防止误转给无法签名的地址
    function test_RevertWhen_WrongAccountAcceptsOwnership() public {
        admin.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(LotteryAdmin.NotPendingOwner.selector);
        admin.acceptOwnership();
        assertEq(admin.s_owner(), address(this), "owner untouched");
    }

    function test_RevertWhen_AcceptWithoutPendingTransfer() public {
        vm.prank(alice);
        vm.expectRevert(LotteryAdmin.NotPendingOwner.selector);
        admin.acceptOwnership();
    }

    /// @dev 三项业务权限都受 onlyOwner 约束
    function test_RevertWhen_NonOwnerCallsEachBusinessFunction() public {
        vm.startPrank(alice);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.setTreasury(alice);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.setFeeBps(100);
        vm.expectRevert(LotteryAdmin.NotOwner.selector);
        admin.setSalesPaused(true);
        vm.stopPrank();
    }

    /// @dev Lottery 侧的硬上限仍然生效——admin 不是绕过校验的后门
    /// @dev 注意取值必须写在 vm.expectRevert **之前**：expectRevert 作用于下一次调用，
    ///      而 `lottery.MAX_FEE_BPS()` 本身就是一次调用，写在参数里会把期望消费掉，
    ///      于是测试即使在无保护时也会「通过」（写这个测试时真踩到了）
    function test_RevertWhen_FeeAboveLotteryCap() public {
        uint16 tooHigh = lottery.MAX_FEE_BPS() + 1;
        vm.expectRevert(Lottery.FeeTooHigh.selector);
        admin.setFeeBps(tooHigh);
    }

    /// @dev 彩票在 admin 治下照常运转（回归）
    function test_LotteryStillFullyFunctionalUnderAdmin() public {
        _buy(alice, 10);
        _settleRound(1, 42);
        (, address[] memory winners,) = lottery.winnersOf(1);
        uint256 before = winners[0].balance;
        vm.prank(winners[0]);
        lottery.claim(1, 0);
        assertGt(winners[0].balance, before);
    }
}
