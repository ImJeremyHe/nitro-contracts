// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/nitro/blob/master/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.4;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {
    NotContract,
    NotRollupOrOwner,
    NotDelayedInbox,
    NotSequencerInbox,
    NotOutbox,
    InvalidOutboxSet,
    BadSequencerMessageNumber,
    EmptyDelayedMessagesRead,
    DelayedBackwards,
    DelayedTooFar
} from "../libraries/Error.sol";
import "../precompiles/ArbGasInfo.sol";
import "./IBridgeOpt.sol";
import "./Messages.sol";
import "../libraries/DelegateCallAware.sol";
import "./ISequencerInbox.sol";

import {L1MessageType_batchPostingReport} from "../libraries/MessageTypes.sol";

/**
 * @title Staging ground for incoming and outgoing messages
 * @notice Holds the inbox accumulator for sequenced and delayed messages.
 * Since the escrow is held here, this contract also contains a list of allowed
 * outboxes that can make calls from here and withdraw this escrow.
 */
abstract contract AbsBridgeOpt is Initializable, DelegateCallAware, IBridgeOpt {
    using AddressUpgradeable for address;

    struct InOutInfo {
        uint256 index;
        bool allowed;
    }

    mapping(address => InOutInfo) private allowedDelayedInboxesMap;
    mapping(address => InOutInfo) private allowedOutboxesMap;

    address[] public allowedDelayedInboxList;
    address[] public allowedOutboxList;

    address internal _activeOutbox;

    /// @inheritdoc IBridgeOpt
    bytes32[] public delayedInboxAccs;

    /// @inheritdoc IBridgeOpt
    bytes32[] public sequencerInboxAccs;

    IOwnable public rollup;
    address public sequencerInbox;

    uint256 public override sequencerReportedSubMessageCount;

    uint256 public totalDelayedMessagesRead;

    address internal constant EMPTY_ACTIVEOUTBOX = address(type(uint160).max);

    function postUpgradeInit() external onlyDelegated onlyProxyOwner {
        totalDelayedMessagesRead = ISequencerInbox(sequencerInbox).totalDelayedMessagesRead();
        if (totalDelayedMessagesRead == 0) revert EmptyDelayedMessagesRead();
    }

    modifier onlyRollupOrOwner() {
        if (msg.sender != address(rollup)) {
            address rollupOwner = rollup.owner();
            if (msg.sender != rollupOwner) {
                revert NotRollupOrOwner(msg.sender, address(rollup), rollupOwner);
            }
        }
        _;
    }

    /// @notice Allows the rollup owner to set another rollup address
    function updateRollupAddress(IOwnable _rollup) external onlyRollupOrOwner {
        rollup = _rollup;
        emit RollupUpdated(address(_rollup));
    }

    /// @dev returns the address of current active Outbox, or zero if no outbox is active
    function activeOutbox() public view returns (address) {
        address outbox = _activeOutbox;
        // address zero is returned if no outbox is set, but the value used in storage
        // is non-zero to save users some gas (as storage refunds are usually maxed out)
        // EIP-1153 would help here.
        // we don't return `EMPTY_ACTIVEOUTBOX` to avoid a breaking change on the current api
        if (outbox == EMPTY_ACTIVEOUTBOX) return address(0);
        return outbox;
    }

    function allowedDelayedInboxes(address inbox) public view returns (bool) {
        return allowedDelayedInboxesMap[inbox].allowed;
    }

    function allowedOutboxes(address outbox) public view returns (bool) {
        return allowedOutboxesMap[outbox].allowed;
    }

    modifier onlySequencerInbox() {
        if (msg.sender != sequencerInbox) revert NotSequencerInbox(msg.sender);
        _;
    }

    function enqueueSequencerMessage(
        bytes32 dataHash,
        uint256 afterDelayedMessagesRead,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        TimeBounds memory timeBounds,
        BatchDataLocation batchDataLocation
    )
        public
        onlySequencerInbox
        returns (
            uint256 seqMessageIndex,
            bytes32 beforeAcc,
            bytes32 delayedAcc,
            bytes32 acc
        )
    {
        if (
            sequencerReportedSubMessageCount != prevMessageCount &&
            prevMessageCount != 0 &&
            sequencerReportedSubMessageCount != 0
        ) {
            revert BadSequencerMessageNumber(sequencerReportedSubMessageCount, prevMessageCount);
        }
        if (afterDelayedMessagesRead > delayedInboxAccs.length) revert DelayedTooFar();
        if (afterDelayedMessagesRead < totalDelayedMessagesRead) revert DelayedBackwards();

        sequencerReportedSubMessageCount = newMessageCount;
        seqMessageIndex = sequencerInboxAccs.length;
        if (sequencerInboxAccs.length > 0) {
            beforeAcc = sequencerInboxAccs[sequencerInboxAccs.length - 1];
        }
        if (afterDelayedMessagesRead > 0) {
            delayedAcc = delayedInboxAccs[afterDelayedMessagesRead - 1];
        }
        acc = keccak256(abi.encodePacked(beforeAcc, dataHash, delayedAcc));
        sequencerInboxAccs.push(acc);
        totalDelayedMessagesRead = afterDelayedMessagesRead;

        emit SequencerBatchDelivered(
            seqMessageIndex,
            beforeAcc,
            acc,
            delayedAcc,
            afterDelayedMessagesRead,
            timeBounds,
            batchDataLocation,
            msg.sender
        );
    }

    function enqueueSequencerMessageAndSubmitBatchSpendingReport(
        bytes32 dataHash,
        uint256 afterDelayedMessagesRead,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        TimeBounds memory timeBounds,
        BatchDataLocation batchDataLocation,
        address batchPoster,
        bool hostChainIsArbitrum
    )
        external
        returns (
            uint256 seqMessageIndex
            // bytes32 beforeAcc,
            // bytes32 delayedAcc,
            // bytes32 acc
        )
    {
        (seqMessageIndex, , ,) = enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            batchDataLocation
        );
        bytes memory spendingReportMsg;
        if (hostChainIsArbitrum) {
            // // Include extra gas for the host chain's L1 gas charging
            // uint256 l1Fees = ArbGasInfo(address(0x6c)).getCurrentTxL1GasFees();
            // uint256 extraGas = l1Fees / block.basefee;
            // require(extraGas <= type(uint64).max, "L1_GAS_NOT_UINT64");
            // spendingReportMsg = abi.encodePacked(
            //     block.timestamp,
            //     batchPoster,
            //     dataHash,
            //     seqMessageIndex,
            //     block.basefee,
            //     uint64(extraGas)
            // );
        } else {
            spendingReportMsg = abi.encodePacked(
                block.timestamp,
                batchPoster,
                dataHash,
                seqMessageIndex,
                block.basefee
            );
        }
        uint256 msgNum = submitBatchSpendingReport(
            batchPoster,
            keccak256(spendingReportMsg)
        );
        emit InboxMessageDelivered(msgNum, spendingReportMsg);
    }

    /// @inheritdoc IBridgeOpt
    function submitBatchSpendingReport(address sender, bytes32 messageDataHash)
        public
        onlySequencerInbox
        returns (uint256)
    {
        return
            addMessageToDelayedAccumulator(
                L1MessageType_batchPostingReport,
                sender,
                uint64(block.number),
                uint64(block.timestamp), // solhint-disable-line not-rely-on-time,
                block.basefee,
                messageDataHash
            );
    }

    function _enqueueDelayedMessage(
        uint8 kind,
        address sender,
        bytes32 messageDataHash,
        uint256 amount
    ) internal returns (uint256) {
        if (!allowedDelayedInboxes(msg.sender)) revert NotDelayedInbox(msg.sender);

        uint256 messageCount = addMessageToDelayedAccumulator(
            kind,
            sender,
            uint64(block.number),
            uint64(block.timestamp), // solhint-disable-line not-rely-on-time
            _baseFeeToReport(),
            messageDataHash
        );

        _transferFunds(amount);

        return messageCount;
    }

    function addMessageToDelayedAccumulator(
        uint8 kind,
        address sender,
        uint64 blockNumber,
        uint64 blockTimestamp,
        uint256 baseFeeL1,
        bytes32 messageDataHash
    ) internal returns (uint256) {
        uint256 count = delayedInboxAccs.length;
        bytes32 messageHash = Messages.messageHash(
            kind,
            sender,
            blockNumber,
            blockTimestamp,
            count,
            baseFeeL1,
            messageDataHash
        );
        bytes32 prevAcc = 0;
        if (count > 0) {
            prevAcc = delayedInboxAccs[count - 1];
        }
        delayedInboxAccs.push(Messages.accumulateInboxMessage(prevAcc, messageHash));
        emit MessageDelivered(
            count,
            prevAcc,
            msg.sender,
            kind,
            sender,
            messageDataHash,
            baseFeeL1,
            blockTimestamp
        );
        return count;
    }

    /// @inheritdoc IBridgeOpt
    function executeCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool success, bytes memory returnData) {
        if (!allowedOutboxes(msg.sender)) revert NotOutbox(msg.sender);
        if (data.length > 0 && !to.isContract()) revert NotContract(to);
        address prevOutbox = _activeOutbox;
        _activeOutbox = msg.sender;
        // We set and reset active outbox around external call so activeOutbox remains valid during call

        // We use a low level call here since we want to bubble up whether it succeeded or failed to the caller
        // rather than reverting on failure as well as allow contract and non-contract calls
        (success, returnData) = _executeLowLevelCall(to, value, data);

        _activeOutbox = prevOutbox;
        emit BridgeCallTriggered(msg.sender, to, value, data);
    }

    function setSequencerInbox(address _sequencerInbox) external onlyRollupOrOwner {
        sequencerInbox = _sequencerInbox;
        emit SequencerInboxUpdated(_sequencerInbox);
    }

    function setDelayedInbox(address inbox, bool enabled) external onlyRollupOrOwner {
        InOutInfo storage info = allowedDelayedInboxesMap[inbox];
        bool alreadyEnabled = info.allowed;
        emit InboxToggle(inbox, enabled);
        if (alreadyEnabled == enabled) {
            return;
        }
        if (enabled) {
            allowedDelayedInboxesMap[inbox] = InOutInfo(allowedDelayedInboxList.length, true);
            allowedDelayedInboxList.push(inbox);
        } else {
            allowedDelayedInboxList[info.index] = allowedDelayedInboxList[
                allowedDelayedInboxList.length - 1
            ];
            allowedDelayedInboxesMap[allowedDelayedInboxList[info.index]].index = info.index;
            allowedDelayedInboxList.pop();
            delete allowedDelayedInboxesMap[inbox];
        }
    }

    function setOutbox(address outbox, bool enabled) external onlyRollupOrOwner {
        if (outbox == EMPTY_ACTIVEOUTBOX) revert InvalidOutboxSet(outbox);

        InOutInfo storage info = allowedOutboxesMap[outbox];
        bool alreadyEnabled = info.allowed;
        emit OutboxToggle(outbox, enabled);
        if (alreadyEnabled == enabled) {
            return;
        }
        if (enabled) {
            allowedOutboxesMap[outbox] = InOutInfo(allowedOutboxList.length, true);
            allowedOutboxList.push(outbox);
        } else {
            allowedOutboxList[info.index] = allowedOutboxList[allowedOutboxList.length - 1];
            allowedOutboxesMap[allowedOutboxList[info.index]].index = info.index;
            allowedOutboxList.pop();
            delete allowedOutboxesMap[outbox];
        }
    }

    function setSequencerReportedSubMessageCount(uint256 newMsgCount) external onlyRollupOrOwner {
        sequencerReportedSubMessageCount = newMsgCount;
    }

    function delayedMessageCount() external view override returns (uint256) {
        return delayedInboxAccs.length;
    }

    function sequencerMessageCount() external view returns (uint256) {
        return sequencerInboxAccs.length;
    }

    /// @dev For the classic -> nitro migration. TODO: remove post-migration.
    function acceptFundsFromOldBridge() external payable {}

    /// @dev transfer funds provided to pay for crosschain msg
    function _transferFunds(uint256 amount) internal virtual;

    function _executeLowLevelCall(
        address to,
        uint256 value,
        bytes memory data
    ) internal virtual returns (bool success, bytes memory returnData);

    /// @dev get base fee which is emitted in `MessageDelivered` event and then picked up and
    /// used in ArbOs to calculate the submission fee for retryable ticket
    function _baseFeeToReport() internal view virtual returns (uint256);

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[39] private __gap;
}
