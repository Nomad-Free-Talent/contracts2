// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {SecureMerkleTrie} from "../library/trie/SecureMerkleTrie.sol";
import {MerkleTrie} from "../library/trie/MerkleTrie.sol";
import {RLPReader} from "../library/rlp/RLPReader.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {RLPWriter} from "../library/rlp/RLPWriter.sol";
import {TransactionDecoder} from "../library/TransactionDecoder.sol";

import {ValidationUtility} from "./ValidationUtility.sol";
import {Shared} from "./Shared.sol";

contract ValidationProcessor is ValidationUtility, Shared {
    using RLPReader for bytes;
    using RLPReader for RLPReader.RLPItem;
    using TransactionDecoder for bytes;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    using TransactionDecoder for TransactionDecoder.Transaction;

  
    function _verifyAndFinalize(
        bytes32 validationId,
        bytes32 trustedPreviousSegmentHash,
        ValidationEvidence calldata evidence
    ) internal {
        if (!validationSetIDs.contains(validationId)) {
            revert ValidationNotFoundError();
        }

        ValidationRecord storage record = validationRecords[validationId];

        if (record.phase != ValidationPhase.Awaiting) {
            revert ValidationAlreadySettledError();
        }

        if (
            record.timestampInit + validatorParams.CHALLENGE_TIMEOUT_PERIOD() <
            Time.timestamp()
        ) {
            revert ValidationTimedOutError();
        }

        uint256 messageCount = record.authorizedMessages.length;
        if (
            evidence.messageMerkleEvidence.length != messageCount ||
            evidence.messagePositions.length != messageCount
        ) {
            revert InvalidEvidenceCountError();
        }

        bytes32 previousSegmentHash = keccak256(evidence.precedingSegmentRLP);
        if (previousSegmentHash != trustedPreviousSegmentHash) {
            revert InvalidSegmentDigestError();
        }

        ChainSegmentInfo memory previousSegment = _decodeSegmentHeaderRLP(
            evidence.precedingSegmentRLP
        );
        ChainSegmentInfo memory incorporationSegment = _decodeSegmentHeaderRLP(
            evidence.incorporationSegmentRLP
        );

        if (incorporationSegment.ancestorDigest != previousSegmentHash) {
            revert InvalidAncestorDigestError();
        }

        (bool participantExists, bytes memory participantRLP) = SecureMerkleTrie
            .get(
                abi.encodePacked(record.protocolDestination),
                evidence.participantMerkleEvidence,
                previousSegment.worldStateDigest
            );

        if (!participantExists) {
            revert ParticipantNotFoundError();
        }

        ParticipantState memory participant = _decodeParticipantRLP(
            participantRLP
        );

        for (uint256 i = 0; i < messageCount; i++) {
            MessageDetails memory message = record.authorizedMessages[i];

            if (participant.sequence > message.sequence) {
                _finalizeValidation(ValidationPhase.Confirmed, record);
                return;
            }

            if (
                participant.holdings <
                incorporationSegment.networkFee * message.fuelLimit
            ) {
                _finalizeValidation(ValidationPhase.Confirmed, record);
                return;
            }

            participant.holdings -=
                incorporationSegment.networkFee *
                message.fuelLimit;
            participant.sequence++;

            bytes memory messageLeaf = RLPWriter.writeUint(
                evidence.messagePositions[i]
            );

            (bool messageExists, bytes memory messageRLP) = MerkleTrie.get(
                messageLeaf,
                evidence.messageMerkleEvidence[i],
                incorporationSegment.messageTreeDigest
            );

            if (!messageExists) {
                revert MessageNotFoundError();
            }

            if (message.messageDigest != keccak256(messageRLP)) {
                revert InvalidMessageEvidenceError();
            }
        }

        _finalizeValidation(ValidationPhase.Confirmed, record);
    }

    function _finalizeValidation(
        ValidationPhase outcome,
        ValidationRecord storage record
    ) internal {
        if (outcome == ValidationPhase.Confirmed) {
            record.phase = ValidationPhase.Confirmed;
            _distributeHalfDeposit(msg.sender);
            _distributeHalfDeposit(record.witnessAuthorizer);
            emit ValidationConfirmed(record.attestationId);
        } else if (outcome == ValidationPhase.Rejected) {
            record.phase = ValidationPhase.Rejected;
            _distributeFullDeposit(record.validator);
            emit ValidationRejected(record.attestationId);
        }

        delete validationRecords[record.attestationId];
        validationSetIDs.remove(record.attestationId);
    }

    function _getEpochFromTimestamp(
        uint256 _timestamp
    ) internal view returns (uint256) {
        return
            (_timestamp - validatorParams.CONSENSUS_LAUNCH_TIMESTAMP()) /
            validatorParams.VALIDATOR_EPOCH_TIME();
    }

    function _getCurrentEpoch() internal view returns (uint256) {
        return _getEpochFromTimestamp(block.timestamp);
    }

    function _distributeHalfDeposit(address recipient) internal  {
        (bool success, ) = payable(recipient).call{
            value: validatorParams.DISPUTE_SECURITY_DEPOSIT() / 2
        }("");
        if (!success) {
            revert BondTransferFailedError();
        }
    }

    function _distributeFullDeposit(address recipient) internal   {
        (bool success, ) = payable(recipient).call{
            value: validatorParams.DISPUTE_SECURITY_DEPOSIT()
        }("");
        if (!success) {
            revert BondTransferFailedError();
        }
    }

    function _getTimestampFromEpoch(
        uint256 _epoch
    ) internal view returns (uint256) {
        return
            validatorParams.CONSENSUS_LAUNCH_TIMESTAMP() +
            _epoch *
            validatorParams.VALIDATOR_EPOCH_TIME();
    }

    function _getConsensusRootAt(
        uint256 _epoch
    ) internal view returns (bytes32) {
        uint256 slotTimestamp = validatorParams.CONSENSUS_LAUNCH_TIMESTAMP() +
            _epoch *
            validatorParams.VALIDATOR_EPOCH_TIME();
        return _getConsensusRootFromTimestamp(slotTimestamp);
    }

    function _getConsensusRootFromTimestamp(
        uint256 _timestamp
    ) internal view returns (bytes32) {
        (bool success, bytes memory data) = validatorParams
            .CONSENSUS_BEACON_ROOT_ADDRESS()
            .staticcall(abi.encode(_timestamp));

        if (!success || data.length == 0) {
            revert ConsensusRootMissingError();
        }

        return abi.decode(data, (bytes32));
    }

    function _getLatestBeaconBlockRoot() internal view returns (bytes32) {
        uint256 latestSlot = _getEpochFromTimestamp(block.timestamp);
        return _getConsensusRootAt(latestSlot);
    }

    function _decodeParticipantRLP(
        bytes memory participantRLP
    ) internal pure returns (ParticipantState memory participant) {
        RLPReader.RLPItem[] memory participantFields = participantRLP
            .toRLPItem()
            .readList();
        participant.sequence = participantFields[0].readUint256();
        participant.holdings = participantFields[1].readUint256();
    }

         function _isWithinEIP4788Window(
        uint256 _timestamp
    ) internal view returns (bool) {
        return _getEpochFromTimestamp(_timestamp) <= _getCurrentEpoch() + validatorParams.BEACON_TIME_WINDOW();
    }

}