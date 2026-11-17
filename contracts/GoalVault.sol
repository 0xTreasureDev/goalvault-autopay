// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/**
 * @title GoalVault
 * @notice A "set it and forget it" savings-goal vault on Ethereum Sepolia.
 *
 * Anyone can open a savings goal (a beneficiary and a target amount in ETH),
 * and anyone can deposit toward it. The moment the deposits reach the target,
 * a reactive contract on Reactive Lasna (GoalWatcher) notices the `Deposited`
 * event and requests a callback into `release()`, which pays the full funded
 * amount out to the beneficiary automatically — no keeper, no bot, and nobody
 * has to remember to press a button.
 *
 * The vault is its own callback recipient: it inherits {AbstractCallback}, so
 * `release()` can only be invoked by the Reactive callback proxy on Sepolia,
 * and only on behalf of the authorized GoalWatcher contract. The proxy bills
 * this contract for callback delivery in Sepolia ETH; those (tiny, testnet)
 * charges are settled from the contract balance via the inherited `pay()`.
 * Goal accounting is tracked per goal in storage, so payouts always send the
 * exact funded amount regardless of fee charges against the pooled balance.
 */
contract GoalVault is AbstractCallback {
    struct Goal {
        address owner; // creator of the goal; may cancel before release
        address beneficiary; // receives the funds on release
        uint256 target; // amount (wei) that triggers automatic release
        uint256 funded; // amount deposited so far
        bool released; // true once paid out by the reactive callback
        bool cancelled; // true once cancelled and refunded by the owner
    }

    uint256 public nextGoalId = 1;
    mapping(uint256 => Goal) public goals;

    event GoalCreated(
        uint256 indexed goalId, address indexed owner, address indexed beneficiary, uint256 target
    );
    event Deposited(
        uint256 indexed goalId,
        address indexed depositor,
        uint256 amount,
        uint256 totalFunded,
        uint256 target
    );
    event GoalReleased(uint256 indexed goalId, address indexed beneficiary, uint256 amount);
    event GoalCancelled(uint256 indexed goalId, address indexed owner, uint256 refunded);

    error GoalMissing(uint256 goalId);
    error GoalClosed(uint256 goalId);
    error TargetNotReached(uint256 goalId, uint256 funded, uint256 target);
    error NotGoalOwner(uint256 goalId, address caller);
    error ZeroTarget();
    error ZeroBeneficiary();
    error PayoutFailed();

    /**
     * @param callbackProxy_ Reactive callback proxy on this chain
     *        (Ethereum Sepolia: 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4).
     * @param callbackSender_ Address of the GoalWatcher reactive contract on
     *        Reactive Lasna that is authorized to trigger releases.
     */
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {}

    /// @notice Open a new savings goal. Returns the goal id.
    function createGoal(address beneficiary_, uint256 target_) external returns (uint256 goalId) {
        if (beneficiary_ == address(0)) revert ZeroBeneficiary();
        if (target_ == 0) revert ZeroTarget();
        goalId = nextGoalId++;
        goals[goalId] = Goal({
            owner: msg.sender,
            beneficiary: beneficiary_,
            target: target_,
            funded: 0,
            released: false,
            cancelled: false
        });
        emit GoalCreated(goalId, msg.sender, beneficiary_, target_);
    }

    /// @notice Deposit ETH toward a goal. Emits the event GoalWatcher follows.
    function deposit(uint256 goalId_) external payable {
        Goal storage goal = goals[goalId_];
        if (goal.target == 0) revert GoalMissing(goalId_);
        if (goal.released || goal.cancelled) revert GoalClosed(goalId_);
        goal.funded += msg.value;
        emit Deposited(goalId_, msg.sender, msg.value, goal.funded, goal.target);
    }

    /// @notice Cancel an unreleased goal and refund everything to its owner.
    function cancelGoal(uint256 goalId_) external {
        Goal storage goal = goals[goalId_];
        if (goal.target == 0) revert GoalMissing(goalId_);
        if (goal.released || goal.cancelled) revert GoalClosed(goalId_);
        if (msg.sender != goal.owner) revert NotGoalOwner(goalId_, msg.sender);
        uint256 refund = goal.funded;
        goal.funded = 0;
        goal.cancelled = true;
        emit GoalCancelled(goalId_, msg.sender, refund);
        if (refund > 0) {
            (bool ok,) = payable(goal.owner).call{ value: refund }("");
            if (!ok) revert PayoutFailed();
        }
    }

    /**
     * @notice Callback entry point — invoked only by the Reactive callback
     * proxy, only on behalf of the authorized GoalWatcher reactive contract.
     * The first parameter is overwritten by the proxy with the reactive
     * contract's address and is authenticated by `onlyCallbackSender`.
     * Pays the goal's full funded amount to its beneficiary.
     */
    function release(address reactive_, uint256 goalId_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        Goal storage goal = goals[goalId_];
        if (goal.target == 0) revert GoalMissing(goalId_);
        if (goal.released || goal.cancelled) revert GoalClosed(goalId_);
        if (goal.funded < goal.target) revert TargetNotReached(goalId_, goal.funded, goal.target);
        uint256 amount = goal.funded;
        goal.funded = 0;
        goal.released = true;
        emit GoalReleased(goalId_, goal.beneficiary, amount);
        (bool ok,) = payable(goal.beneficiary).call{ value: amount }("");
        if (!ok) revert PayoutFailed();
    }

    /// @notice Settles outstanding callback debt from this contract's balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Convenience read for UIs: full goal record as a tuple.
    function getGoal(uint256 goalId_)
        external
        view
        returns (address owner, address beneficiary, uint256 target, uint256 funded, bool released, bool cancelled)
    {
        Goal storage goal = goals[goalId_];
        return (goal.owner, goal.beneficiary, goal.target, goal.funded, goal.released, goal.cancelled);
    }
}
