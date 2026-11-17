// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { GoalVault } from "../contracts/GoalVault.sol";
import { GoalWatcher } from "../contracts/GoalWatcher.sol";

/// @dev Minimal cheatcode interface (avoids a forge-std dependency).
interface Vm {
    function prank(address sender) external;
    function etch(address target, bytes calldata code) external;
    function deal(address account, uint256 newBalance) external;
}

/// @dev Stand-in for the Reactive system contract, etched at the real address.
contract MockSystem {
    uint256 public subscribeCalls;
    uint256 public callbackCalls;
    ISystemContract.CallbackConfiguration_V_1_0 public lastCallback;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscribeCalls++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {}

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCalls++;
        lastCallback = config_;
    }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

contract GoalAutopayTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address payable internal constant SYSTEM_ADDR = payable(0x8888888888888888888888888888888888888888);
    address payable internal constant PROXY = payable(0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4);
    uint256 internal constant SEPOLIA = 11155111;

    MockSystem internal mock;
    GoalWatcher internal watcher;
    GoalVault internal vault;
    address internal beneficiary = address(0xBEEF);

    function setUp() public {
        mock = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(mock).code);

        watcher = new GoalWatcher{ value: 1 ether }();
        vault = new GoalVault{ value: 0.1 ether }(IPayable(PROXY), address(watcher));
        watcher.setVault(address(vault));
    }

    // ---- helpers -----------------------------------------------------------

    function _log(uint256 goalId, uint256 amount, uint256 totalFunded, uint256 target)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: SEPOLIA,
            contractAddress: address(vault),
            topic0: watcher.DEPOSITED_TOPIC_0(),
            topic1: goalId,
            topic2: uint256(uint160(address(this))),
            topic3: 0,
            data: abi.encode(amount, totalFunded, target),
            blockNumber: 1,
            opCode: 3,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _assertEq(uint256 a, uint256 b, string memory what) internal pure {
        require(a == b, what);
    }

    function _assertTrue(bool cond, string memory what) internal pure {
        require(cond, what);
    }

    // ---- tests -------------------------------------------------------------

    function testSetVaultSubscribes() public view {
        _assertEq(MockSystem(SYSTEM_ADDR).subscribeCalls(), 1, "watcher must subscribe once");
        _assertTrue(watcher.vault() == address(vault), "vault recorded");
    }

    function testDepositBelowTargetNoCallback() public {
        IReactive.LogRecord memory log1 = _log(1, 0.03 ether, 0.03 ether, 0.05 ether);
        vm.prank(SYSTEM_ADDR);
        watcher.react(log1);
        _assertEq(watcher.reactions(), 1, "reaction counted");
        _assertEq(watcher.triggers(), 0, "no trigger below target");
        _assertEq(MockSystem(SYSTEM_ADDR).callbackCalls(), 0, "no callback below target");
    }

    function testDepositReachingTargetRequestsReleaseCallback() public {
        IReactive.LogRecord memory logA = _log(1, 0.03 ether, 0.03 ether, 0.05 ether);
        IReactive.LogRecord memory logB = _log(1, 0.025 ether, 0.055 ether, 0.05 ether);
        IReactive.LogRecord memory logC = _log(1, 0.01 ether, 0.065 ether, 0.05 ether);
        vm.prank(SYSTEM_ADDR);
        watcher.react(logA);
        vm.prank(SYSTEM_ADDR);
        watcher.react(logB);

        _assertEq(watcher.triggers(), 1, "one trigger at target");
        _assertEq(MockSystem(SYSTEM_ADDR).callbackCalls(), 1, "one callback requested");

        (uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            MockSystem(SYSTEM_ADDR).lastCallback();
        _assertEq(chainId, SEPOLIA, "callback goes to Sepolia");
        _assertTrue(recipient == address(vault), "callback recipient is the vault");
        _assertTrue(gasLimit >= 100_000, "callback gas above protocol minimum");

        bytes memory expected = abi.encodeWithSignature("release(address,uint256)", address(0), uint256(1));
        _assertTrue(keccak256(payload) == keccak256(expected), "payload is release(0, goalId)");

        // A later deposit for the same goal must not trigger a second release.
        vm.prank(SYSTEM_ADDR);
        watcher.react(logC);
        _assertEq(MockSystem(SYSTEM_ADDR).callbackCalls(), 1, "no duplicate callback");
    }

    function testReactRejectsNonSystemCaller() public {
        bool reverted;
        try watcher.react(_log(1, 1, 1, 1)) {
            reverted = false;
        } catch {
            reverted = true;
        }
        _assertTrue(reverted, "react() must reject non-system callers");
    }

    function testFullLoopVaultReleasePaysBeneficiary() public {
        uint256 goalId = vault.createGoal(beneficiary, 0.05 ether);
        vm.deal(address(this), 1 ether);
        vault.deposit{ value: 0.03 ether }(goalId);
        vault.deposit{ value: 0.02 ether }(goalId);

        uint256 before = beneficiary.balance;
        vm.prank(PROXY);
        vault.release(address(watcher), goalId);

        _assertEq(beneficiary.balance - before, 0.05 ether, "beneficiary paid in full");
        (,,,, bool released,) = vault.getGoal(goalId);
        _assertTrue(released, "goal marked released");
    }

    function testReleaseGuards() public {
        uint256 goalId = vault.createGoal(beneficiary, 0.05 ether);
        vm.deal(address(this), 1 ether);
        vault.deposit{ value: 0.05 ether }(goalId);

        // Wrong caller (not the proxy).
        bool reverted1;
        try vault.release(address(watcher), goalId) {
            reverted1 = false;
        } catch {
            reverted1 = true;
        }
        _assertTrue(reverted1, "release must reject non-proxy callers");

        // Right proxy, wrong reactive sender.
        bool reverted2;
        vm.prank(PROXY);
        try vault.release(address(0xBAD), goalId) {
            reverted2 = false;
        } catch {
            reverted2 = true;
        }
        _assertTrue(reverted2, "release must reject unauthorized reactive senders");
    }

    function testReleaseBeforeTargetReverts() public {
        uint256 goalId = vault.createGoal(beneficiary, 0.05 ether);
        vm.deal(address(this), 1 ether);
        vault.deposit{ value: 0.01 ether }(goalId);

        bool reverted;
        vm.prank(PROXY);
        try vault.release(address(watcher), goalId) {
            reverted = false;
        } catch {
            reverted = true;
        }
        _assertTrue(reverted, "release before target must revert");
    }

    function testCancelRefundsOwner() public {
        uint256 goalId = vault.createGoal(beneficiary, 0.05 ether);
        vm.deal(address(this), 1 ether);
        vault.deposit{ value: 0.02 ether }(goalId);
        uint256 before = address(this).balance;
        vault.cancelGoal(goalId);
        _assertEq(address(this).balance - before, 0.02 ether, "owner refunded in full");
    }

    receive() external payable {}
}
