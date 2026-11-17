// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/**
 * @title GoalWatcher
 * @notice Reactive contract on Reactive Lasna — the automation half of
 * GoalVault Autopay ("Set It and Forget It" track).
 *
 * It subscribes to `Deposited` events emitted by a GoalVault contract on
 * Ethereum Sepolia. Every deposit is delivered here by the Reactive system
 * contract as a reactive transaction. When a deposit pushes a goal's total
 * funding to (or past) its target, the watcher requests exactly one callback
 * back to Sepolia, instructing the vault to release the funds to the goal's
 * beneficiary. No keeper, no off-chain bot, no polling.
 *
 * Deployment order (the vault needs this contract's address at construction,
 * and this contract needs the vault's address to subscribe):
 *   1. Deploy GoalWatcher on Lasna and fund it with lREACT.
 *   2. Deploy GoalVault on Sepolia with this contract as callback sender.
 *   3. Call `setVault(vault)` here — subscribes and sets the callback target.
 */
contract GoalWatcher is AbstractReactive {
    /// @notice Ethereum Sepolia chain id — origin and destination chain.
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    /// @notice topic0 of GoalVault.Deposited(uint256,address,uint256,uint256,uint256).
    uint256 public constant DEPOSITED_TOPIC_0 =
        uint256(keccak256("Deposited(uint256,address,uint256,uint256,uint256)"));

    /// @notice Gas limit for the release callback on Sepolia (protocol min 100,000).
    uint64 private constant CALLBACK_GAS_LIMIT = 500_000;

    address public owner;
    address public vault;
    uint256 public reactions; // total Deposited events processed
    uint256 public triggers; // total release callbacks requested
    mapping(uint256 => bool) public triggered; // goalId => release already requested

    event VaultSet(address indexed vault);
    event GoalObserved(uint256 indexed goalId, uint256 totalFunded, uint256 target);
    event GoalTriggered(uint256 indexed goalId, uint256 totalFunded, uint256 target);
    event Paused();
    event Resumed();

    error NotOwner(address caller);
    error VaultNotSet();
    error VaultAlreadySet();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    constructor() payable {
        owner = msg.sender;
    }

    /**
     * @notice Point the watcher at a GoalVault on Sepolia: records it as the
     * callback recipient and subscribes to its `Deposited` events.
     * Can be called again to retarget (unsubscribes the previous vault).
     */
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        if (vault != address(0)) {
            SYSTEM.unsubscribe(
                SEPOLIA_CHAIN_ID, vault, DEPOSITED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
        vault = vault_;
        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID, vault_, DEPOSITED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit VaultSet(vault_);
    }

    /// @notice Stop reacting (drops the subscription). Funds stay put.
    function pause() external onlyOwner {
        if (vault == address(0)) revert VaultNotSet();
        SYSTEM.unsubscribe(
            SEPOLIA_CHAIN_ID, vault, DEPOSITED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit Paused();
    }

    /// @notice Resume reacting after `pause()` (settles any debt first).
    function resume() external onlyOwner {
        if (vault == address(0)) revert VaultNotSet();
        _coverDebt();
        SYSTEM.subscribe(
            SEPOLIA_CHAIN_ID, vault, DEPOSITED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        emit Resumed();
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Only the vault's Deposited events on Sepolia matter here; anything
        // else falls through silently (reverting would still be billed).
        if (log_.chainId != SEPOLIA_CHAIN_ID) return;
        if (log_.contractAddress != vault) return;
        if (log_.topic0 != DEPOSITED_TOPIC_0) return;

        uint256 goalId = log_.topic1;
        // Deposited data payload: (uint256 amount, uint256 totalFunded, uint256 target)
        (, uint256 totalFunded, uint256 target) = abi.decode(log_.data, (uint256, uint256, uint256));

        reactions++;
        emit GoalObserved(goalId, totalFunded, target);

        if (totalFunded >= target && !triggered[goalId]) {
            triggered[goalId] = true;
            triggers++;
            emit GoalTriggered(goalId, totalFunded, target);

            bytes memory payload = abi.encodeWithSignature("release(address,uint256)", address(0), goalId);
            SYSTEM.requestCallbackV_1_0(
                ISystemContract.CallbackConfiguration_V_1_0({
                    chainId: SEPOLIA_CHAIN_ID,
                    recipient: vault,
                    gasLimit: CALLBACK_GAS_LIMIT,
                    payload: payload
                })
            );
        }
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Owner withdrawal of spare lREACT (e.g. after the demo ends).
    function withdraw(uint256 amount_) external onlyOwner {
        (bool ok,) = payable(owner).call{ value: amount_ }("");
        require(ok, "withdraw failed");
    }
}
