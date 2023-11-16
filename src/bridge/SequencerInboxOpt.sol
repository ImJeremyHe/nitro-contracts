// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import {
    AlreadyInit,
    HadZeroInit,
    NotOrigin,
    DataTooLarge,
    NotRollup,
    DelayedBackwards,
    DelayedTooFar,
    ForceIncludeBlockTooSoon,
    ForceIncludeTimeTooSoon,
    IncorrectMessagePreimage,
    NotBatchPoster,
    BadSequencerNumber,
    DataNotAuthenticated,
    AlreadyValidDASKeyset,
    NoSuchKeyset,
    NotForked,
    NotOwner,
    RollupNotChanged
} from "../libraries/Error.sol";
import "./IBridgeOpt.sol";
import "./IInboxBase.sol";
import "./ISequencerInboxOpt.sol";
import "../rollup/IRollupLogic.sol";
import "./Messages.sol";
import "../precompiles/ArbGasInfo.sol";
import "../precompiles/ArbSys.sol";

import {L1MessageType_batchPostingReport} from "../libraries/MessageTypes.sol";
import {GasRefundEnabled, IGasRefunder} from "../libraries/IGasRefunder.sol";
import "../libraries/ArbitrumChecker.sol";

/**
 * @title Accepts batches from the sequencer and adds them to the rollup inbox.
 * @notice Contains the inbox accumulator which is the ordering of all data and transactions to be processed by the rollup.
 * As part of submitting a batch the sequencer is also expected to include items enqueued
 * in the delayed inbox (Bridge.sol). If items in the delayed inbox are not included by a
 * sequencer within a time limit they can be force included into the rollup inbox by anyone.
 */
contract SequencerInboxOpt is GasRefundEnabled, ISequencerInboxOpt {
    IBridgeOpt public immutable bridge;

    /// @inheritdoc ISequencerInboxOpt
    uint256 public constant HEADER_LENGTH = 40;

    /// @inheritdoc ISequencerInboxOpt
    bytes1 public constant DATA_AUTHENTICATED_FLAG = 0x40;

    IOwnable public rollup;
    mapping(address => bool) public isBatchPoster;
    // see ISequencerInboxOpt.MaxTimeVariation
    uint256 internal immutable delayBlocks;
    uint256 internal immutable futureBlocks;
    uint256 internal immutable delaySeconds;
    uint256 internal immutable futureSeconds;

    mapping(bytes32 => DasKeySetInfo) public dasKeySetInfo;

    modifier onlyRollupOwner() {
        if (msg.sender != rollup.owner()) revert NotOwner(msg.sender, address(rollup));
        _;
    }

    mapping(address => bool) public isSequencer;

    // On L1 this should be set to 117964: 90% of Geth's 128KB tx size limit, leaving ~13KB for proving
    uint256 public immutable maxDataSize;
    uint256 internal immutable deployTimeChainId = block.chainid;
    // If the chain this SequencerInboxOpt is deployed on is an Arbitrum chain.
    bool internal immutable hostChainIsArbitrum = ArbitrumChecker.runningOnArbitrum();

    constructor(
        IBridgeOpt bridge_,
        ISequencerInboxOpt.MaxTimeVariation memory maxTimeVariation_,
        uint256 _maxDataSize
    ) {
        if (bridge_ == IBridgeOpt(address(0))) revert HadZeroInit();
        bridge = bridge_;
        rollup = bridge_.rollup();
        if (address(rollup) == address(0)) revert RollupNotChanged();
        delayBlocks = maxTimeVariation_.delayBlocks;
        futureBlocks = maxTimeVariation_.futureBlocks;
        delaySeconds = maxTimeVariation_.delaySeconds;
        futureSeconds = maxTimeVariation_.futureSeconds;
        maxDataSize = _maxDataSize;
    }

    function _chainIdChanged() internal view returns (bool) {
        return deployTimeChainId != block.chainid;
    }

    /// @inheritdoc ISequencerInboxOpt
    function updateRollupAddress() external {
        if (msg.sender != IOwnable(rollup).owner())
            revert NotOwner(msg.sender, IOwnable(rollup).owner());
        IOwnable newRollup = bridge.rollup();
        if (rollup == newRollup) revert RollupNotChanged();
        rollup = newRollup;
    }

    /// @inheritdoc ISequencerInboxOpt
    function totalDelayedMessagesRead() public view returns (uint256) {
        return bridge.totalDelayedMessagesRead();
    }

    function getTimeBounds() internal view virtual returns (IBridgeOpt.TimeBounds memory) {
        IBridgeOpt.TimeBounds memory bounds;
        ISequencerInboxOpt.MaxTimeVariation memory maxTimeVariation_ = maxTimeVariation();
        if (block.timestamp > maxTimeVariation_.delaySeconds) {
            bounds.minTimestamp = uint64(block.timestamp - maxTimeVariation_.delaySeconds);
        }
        bounds.maxTimestamp = uint64(block.timestamp + maxTimeVariation_.futureSeconds);
        if (block.number > maxTimeVariation_.delayBlocks) {
            bounds.minBlockNumber = uint64(block.number - maxTimeVariation_.delayBlocks);
        }
        bounds.maxBlockNumber = uint64(block.number + maxTimeVariation_.futureBlocks);
        return bounds;
    }

    function maxTimeVariation() public view returns (ISequencerInboxOpt.MaxTimeVariation memory) {
        if (_chainIdChanged()) {
            return
                ISequencerInboxOpt.MaxTimeVariation({
                    delayBlocks: 1,
                    futureBlocks: 1,
                    delaySeconds: 1,
                    futureSeconds: 1
                });
        } else {
            return
                ISequencerInboxOpt.MaxTimeVariation({
                    delayBlocks: delayBlocks,
                    futureBlocks: futureBlocks,
                    delaySeconds: delaySeconds,
                    futureSeconds: futureSeconds
                });
        }
    }

    /// @inheritdoc ISequencerInboxOpt
    function forceInclusion(
        uint256 _totalDelayedMessagesRead,
        uint8 kind,
        uint64[2] calldata l1BlockAndTime,
        uint256 baseFeeL1,
        address sender,
        bytes32 messageDataHash
    ) external {
        if (_totalDelayedMessagesRead <= totalDelayedMessagesRead()) revert DelayedBackwards();
        bytes32 messageHash = Messages.messageHash(
            kind,
            sender,
            l1BlockAndTime[0],
            l1BlockAndTime[1],
            _totalDelayedMessagesRead - 1,
            baseFeeL1,
            messageDataHash
        );
        ISequencerInboxOpt.MaxTimeVariation memory maxTimeVariation_ = maxTimeVariation();
        // Can only force-include after the Sequencer-only window has expired.
        if (l1BlockAndTime[0] + maxTimeVariation_.delayBlocks >= block.number)
            revert ForceIncludeBlockTooSoon();
        if (l1BlockAndTime[1] + maxTimeVariation_.delaySeconds >= block.timestamp)
            revert ForceIncludeTimeTooSoon();

        // Verify that message hash represents the last message sequence of delayed message to be included
        bytes32 prevDelayedAcc = 0;
        if (_totalDelayedMessagesRead > 1) {
            prevDelayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead - 2);
        }
        if (
            bridge.delayedInboxAccs(_totalDelayedMessagesRead - 1) !=
            Messages.accumulateInboxMessage(prevDelayedAcc, messageHash)
        ) revert IncorrectMessagePreimage();

        (bytes32 dataHash, IBridgeOpt.TimeBounds memory timeBounds) = formEmptyDataHash(
            _totalDelayedMessagesRead
        );
        uint256 prevSeqMsgCount = bridge.sequencerReportedSubMessageCount();
        uint256 newSeqMsgCount = prevSeqMsgCount +
            _totalDelayedMessagesRead -
            totalDelayedMessagesRead();
        addSequencerL2BatchImpl(
            dataHash,
            _totalDelayedMessagesRead,
            0,
            prevSeqMsgCount,
            newSeqMsgCount,
            timeBounds,
            IBridgeOpt.BatchDataLocation.NoData
        );
    }

    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) external refundsGas(gasRefunder) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster[msg.sender]) revert NotBatchPoster();
        (bytes32 dataHash, IBridgeOpt.TimeBounds memory timeBounds) = formDataHash(
            data,
            afterDelayedMessagesRead
        );
        // Reformat the stack to prevent "Stack too deep"
        uint256 sequenceNumber_ = sequenceNumber;
        IBridgeOpt.TimeBounds memory timeBounds_ = timeBounds;
        bytes32 dataHash_ = dataHash;
        uint256 dataLength = data.length;
        uint256 afterDelayedMessagesRead_ = afterDelayedMessagesRead;
        uint256 prevMessageCount_ = prevMessageCount;
        uint256 newMessageCount_ = newMessageCount;

        uint256 seqMessageIndex = addSequencerL2BatchImpl(
            dataHash_,
            afterDelayedMessagesRead_,
            dataLength,
            prevMessageCount_,
            newMessageCount_,
            timeBounds_,
            IBridgeOpt.BatchDataLocation.TxInput
        );
        if (seqMessageIndex != sequenceNumber_ && sequenceNumber_ != ~uint256(0))
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber_);
    }

    function addSequencerL2Batch(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) external override refundsGas(gasRefunder) {
        if (!isBatchPoster[msg.sender] && msg.sender != address(rollup)) revert NotBatchPoster();
        (bytes32 dataHash, IBridgeOpt.TimeBounds memory timeBounds) = formDataHash(
            data,
            afterDelayedMessagesRead
        );
        uint256 seqMessageIndex;
        {
            // Reformat the stack to prevent "Stack too deep"
            uint256 sequenceNumber_ = sequenceNumber;
            IBridgeOpt.TimeBounds memory timeBounds_ = timeBounds;
            bytes32 dataHash_ = dataHash;
            uint256 afterDelayedMessagesRead_ = afterDelayedMessagesRead;
            uint256 prevMessageCount_ = prevMessageCount;
            uint256 newMessageCount_ = newMessageCount;
            // we set the calldata length posted to 0 here since the caller isn't the origin
            // of the tx, so they might have not paid tx input cost for the calldata
            seqMessageIndex = addSequencerL2BatchImpl(
                dataHash_,
                afterDelayedMessagesRead_,
                0,
                prevMessageCount_,
                newMessageCount_,
                timeBounds_,
                IBridgeOpt.BatchDataLocation.SeparateBatchEvent
            );
            if (seqMessageIndex != sequenceNumber_ && sequenceNumber_ != ~uint256(0))
                revert BadSequencerNumber(seqMessageIndex, sequenceNumber_);
        }
        emit SequencerBatchData(seqMessageIndex, data);
    }

    modifier validateBatchData(bytes calldata data) {
        uint256 fullDataLen = HEADER_LENGTH + data.length;
        if (fullDataLen > maxDataSize) revert DataTooLarge(fullDataLen, maxDataSize);
        if (data.length > 0 && (data[0] & DATA_AUTHENTICATED_FLAG) == DATA_AUTHENTICATED_FLAG) {
            revert DataNotAuthenticated();
        }
        // the first byte is used to identify the type of batch data
        // das batches expect to have the type byte set, followed by the keyset (so they should have at least 33 bytes)
        if (data.length >= 33 && data[0] & 0x80 != 0) {
            // we skip the first byte, then read the next 32 bytes for the keyset
            bytes32 dasKeysetHash = bytes32(data[1:33]);
            if (!dasKeySetInfo[dasKeysetHash].isValidKeyset) revert NoSuchKeyset(dasKeysetHash);
        }
        _;
    }

    function packHeader(uint256 afterDelayedMessagesRead)
        internal
        view
        returns (bytes memory, IBridgeOpt.TimeBounds memory)
    {
        IBridgeOpt.TimeBounds memory timeBounds = getTimeBounds();
        bytes memory header = abi.encodePacked(
            timeBounds.minTimestamp,
            timeBounds.maxTimestamp,
            timeBounds.minBlockNumber,
            timeBounds.maxBlockNumber,
            uint64(afterDelayedMessagesRead)
        );
        // This must always be true from the packed encoding
        assert(header.length == HEADER_LENGTH);
        return (header, timeBounds);
    }

    function formDataHash(bytes calldata data, uint256 afterDelayedMessagesRead)
        internal
        view
        validateBatchData(data)
        returns (bytes32, IBridgeOpt.TimeBounds memory)
    {
        (bytes memory header, IBridgeOpt.TimeBounds memory timeBounds) = packHeader(
            afterDelayedMessagesRead
        );
        bytes32 dataHash = keccak256(bytes.concat(header, data));
        return (dataHash, timeBounds);
    }

    function formEmptyDataHash(uint256 afterDelayedMessagesRead)
        internal
        view
        returns (bytes32, IBridgeOpt.TimeBounds memory)
    {
        (bytes memory header, IBridgeOpt.TimeBounds memory timeBounds) = packHeader(
            afterDelayedMessagesRead
        );
        return (keccak256(header), timeBounds);
    }

    function addSequencerL2BatchImpl(
        bytes32 dataHash,
        uint256 afterDelayedMessagesRead,
        uint256 calldataLengthPosted,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        IBridgeOpt.TimeBounds memory timeBounds,
        IBridgeOpt.BatchDataLocation batchDataLocation
    ) internal returns (uint256 seqMessageIndex) {
        // if(calldataLengthPosted > 0) {
        seqMessageIndex = bridge.enqueueSequencerMessageAndSubmitBatchSpendingReport(
                dataHash,
                afterDelayedMessagesRead,
                prevMessageCount,
                newMessageCount,
                timeBounds,
                batchDataLocation,
                msg.sender,
                hostChainIsArbitrum
            );
        // } else {
        //     (seqMessageIndex, , , ) = bridge.enqueueSequencerMessage(
        //         dataHash,
        //         afterDelayedMessagesRead,
        //         prevMessageCount,
        //         newMessageCount,
        //         timeBounds,
        //         batchDataLocation
        //     );
        // }
    }

    function inboxAccs(uint256 index) external view returns (bytes32) {
        return bridge.sequencerInboxAccs(index);
    }

    function batchCount() external view returns (uint256) {
        return bridge.sequencerMessageCount();
    }

    /// @inheritdoc ISequencerInboxOpt
    function setIsBatchPoster(address addr, bool isBatchPoster_) external onlyRollupOwner {
        isBatchPoster[addr] = isBatchPoster_;
        // we used to have OwnerFunctionCalled(0) for setting the maxTimeVariation
        // so we dont use index = 0 here, even though this is the first owner function
        // to stay compatible with legacy events
        emit OwnerFunctionCalled(1);
    }

    /// @inheritdoc ISequencerInboxOpt
    function setValidKeyset(bytes calldata keysetBytes) external onlyRollupOwner {
        uint256 ksWord = uint256(keccak256(bytes.concat(hex"fe", keccak256(keysetBytes))));
        bytes32 ksHash = bytes32(ksWord ^ (1 << 255));
        require(keysetBytes.length < 64 * 1024, "keyset is too large");

        if (dasKeySetInfo[ksHash].isValidKeyset) revert AlreadyValidDASKeyset(ksHash);
        uint256 creationBlock = block.number;
        if (hostChainIsArbitrum) {
            creationBlock = ArbSys(address(100)).arbBlockNumber();
        }
        dasKeySetInfo[ksHash] = DasKeySetInfo({
            isValidKeyset: true,
            creationBlock: uint64(creationBlock)
        });
        emit SetValidKeyset(ksHash, keysetBytes);
        emit OwnerFunctionCalled(2);
    }

    /// @inheritdoc ISequencerInboxOpt
    function invalidateKeysetHash(bytes32 ksHash) external onlyRollupOwner {
        if (!dasKeySetInfo[ksHash].isValidKeyset) revert NoSuchKeyset(ksHash);
        // we don't delete the block creation value since its used to fetch the SetValidKeyset
        // event efficiently. The event provides the hash preimage of the key.
        // this is still needed when syncing the chain after a keyset is invalidated.
        dasKeySetInfo[ksHash].isValidKeyset = false;
        emit InvalidateKeyset(ksHash);
        emit OwnerFunctionCalled(3);
    }

    /// @inheritdoc ISequencerInboxOpt
    function setIsSequencer(address addr, bool isSequencer_) external onlyRollupOwner {
        isSequencer[addr] = isSequencer_;
        emit OwnerFunctionCalled(4);
    }

    function isValidKeysetHash(bytes32 ksHash) external view returns (bool) {
        return dasKeySetInfo[ksHash].isValidKeyset;
    }

    /// @inheritdoc ISequencerInboxOpt
    function getKeysetCreationBlock(bytes32 ksHash) external view returns (uint256) {
        DasKeySetInfo memory ksInfo = dasKeySetInfo[ksHash];
        if (ksInfo.creationBlock == 0) revert NoSuchKeyset(ksHash);
        return uint256(ksInfo.creationBlock);
    }
}
