pragma solidity >= 0.6.0;

import { Layer2 } from "../../storage/Layer2.sol";
import { Challengeable } from "../Challengeable.sol";
import { SplitRollUp } from "../../../node_modules/merkle-tree-rollup/contracts/library/Types.sol";
import { SubTreeRollUpLib } from "../../../node_modules/merkle-tree-rollup/contracts/library/SubTreeRollUpLib.sol";
import { RollUpLib } from "../../../node_modules/merkle-tree-rollup/contracts/library/RollUpLib.sol";
import { SMT256 } from "../../../node_modules/smt-rollup/contracts/SMT.sol";
import {
    Block,
    Challenge,
    Transaction,
    Outflow,
    MassDeposit,
    Types
} from "../../libraries/Types.sol";
import { Deserializer } from "../../libraries/Deserializer.sol";

contract RollUpChallenge is Challengeable {
    using SubTreeRollUpLib for SplitRollUp;
    using SMT256 for SMT256.OPRU;
    using Types for Outflow;

    function challengeUTXORollUp(
        uint utxoRollUpId,
        uint[] calldata _deposits,
        uint numOfUTXOs,
        bytes calldata
    ) external {
        Block memory _block = Deserializer.blockFromCalldataAt(3);
        Challenge memory result = _challengeResultOfUTXORollUp(_block, utxoRollUpId, numOfUTXOs, _deposits);
        _execute(result);
    }

    function challengeNullifierRollUp(
        uint nullifierRollUpId,
        uint numOfNullifiers,
        bytes calldata
    ) external {
        Block memory _block = Deserializer.blockFromCalldataAt(2);
        Challenge memory result = _challengeResultOfNullifierRollUp(
            _block,
            nullifierRollUpId,
            numOfNullifiers
        );
        _execute(result);
    }

    function challengeWithdrawalRollUp(
        uint withdrawalRollUpId,
        uint numOfWithdrawals,
        bytes calldata
    ) external {
        Block memory _block = Deserializer.blockFromCalldataAt(2);
        Challenge memory result = _challengeResultOfWithdrawalRollUp(_block, withdrawalRollUpId, numOfWithdrawals);
        _execute(result);
    }

    /** Computes challenge here */
    function _challengeResultOfUTXORollUp(
        Block memory _block,
        uint _utxoRollUpId,
        uint _utxoNum,
        uint[] memory _deposits
    )
        internal
        view
        returns (Challenge memory)
    {
        /// Check submitted _deposits are equal to the leaves in the MassDeposits
        uint depositIndex = 0;
        for(uint i = 0; i < _block.body.massDeposits.length; i++) {
            MassDeposit memory massDeposit = _block.body.massDeposits[i];
            bytes32 merged = bytes32(0);
            bytes32 target = massDeposit.merged;
            while(merged != target) {
                /// merge _deposits until it matches with the submitted mass deposit's merged leaves.
                merged = keccak256(abi.encodePacked(merged, _deposits[depositIndex]));
                depositIndex++;
            }
        }
        require(depositIndex == _deposits.length, "Submitted _deposits are different with the MassDeposits");

        /// Assign a new array
        uint[] memory outputs = new uint[](_utxoNum);
        uint index = 0;
        /// Append _deposits first
        for (uint i = 0; i < _deposits.length; i++) {
            outputs[index++] = _deposits[i];
        }
        /// Append UTXOs from transactions
        for (uint i = 0; i < _block.body.txs.length; i++) {
            Transaction memory transaction = _block.body.txs[i];
            for(uint j = 0; j < transaction.outflow.length; j++) {
                if(transaction.outflow[j].isUTXO()) {
                    outputs[index++] = transaction.outflow[j].note;
                }
            }
        }
        require(_utxoNum == index, "Submitted invalid num of utxo num");

        /// Start a new tree if there's no room to add the new outputs
        uint startingIndex;
        uint startingRoot;
        if (_block.header.prevUTXOIndex + _utxoNum < POOL_SIZE) {
            /// it uses the latest tree
            startingIndex = _block.header.prevUTXOIndex;
            startingRoot = _block.header.prevUTXORoot;
        } else {
            /// start a new tree
            startingIndex = 0;
            startingRoot = 0;
        }
        /// Submitted invalid next output index
        if (_block.header.nextUTXOIndex != (startingIndex + _utxoNum)) {
            return Challenge(
                true,
                _block.submissionId,
                _block.header.proposer,
                "UTXO tree flushed"
            );
        }

        /// Check validity of the roll up using the storage based Poseidon sub-tree roll up
        SplitRollUp memory rollUpProof = Layer2.proof.ofUTXORollUp[_utxoRollUpId];
        bool isValidRollUp = rollUpProof.verify(
            SubTreeRollUpLib.newSubTreeOPRU(
                uint(startingRoot),
                startingIndex,
                uint(_block.header.nextUTXORoot),
                SUB_TREE_DEPTH,
                outputs
            )
        );

        return Challenge(
            !isValidRollUp,
            _block.submissionId,
            _block.header.proposer,
            "UTXO roll up"
        );
    }

    /// Possibility to cost a lot of failure gases because of the 'already slashed' _blocks
    function _challengeResultOfNullifierRollUp(
        Block memory _block,
        uint nullifierRollUpId,
        uint numOfNullifiers
    )
        internal
        view
        returns (Challenge memory)
    {
        /// Assign a new array
        bytes32[] memory nullifiers = new bytes32[](numOfNullifiers);
        /// Get outputs to append
        uint index = 0;
        for (uint i = 0; i < _block.body.txs.length; i++) {
            Transaction memory transaction = _block.body.txs[i];
            for (uint j = 0; j < transaction.inflow.length; j++) {
                nullifiers[index++] = transaction.inflow[j].nullifier;
            }
        }
        require(index == numOfNullifiers, "Invalid length of the nullifiers");

        /// Get rolled up root
        SMT256.OPRU memory proof = Layer2.proof.ofNullifierRollUp[nullifierRollUpId];
        bool isValidRollUp = proof.verify(
            _block.header.prevNullifierRoot,
            _block.header.nextNullifierRoot,
            RollUpLib.merge(bytes32(0), nullifiers)
        );

        return Challenge(
            !isValidRollUp,
            _block.submissionId,
            _block.header.proposer,
            "Nullifier roll up"
        );
    }

    function _challengeResultOfWithdrawalRollUp(
        Block memory _block,
        uint withdrawalRollUpId,
        uint numOfWithdrawals
    )
        internal
        view
        returns (Challenge memory)
    {
        /// Assign a new array
        bytes32[] memory withdrawals = new bytes32[](numOfWithdrawals);
        /// Append Withdrawal notes from transactions
        uint index = 0;
        for (uint i = 0; i < _block.body.txs.length; i++) {
            Transaction memory transaction = _block.body.txs[i];
            for(uint j = 0; j < transaction.outflow.length; j++) {
                if(transaction.outflow[j].isWithdrawal()) {
                    withdrawals[index++] = transaction.outflow[j].withdrawalNote();
                }
            }
        }
        require(numOfWithdrawals == index, "Submitted invalid num of utxo num");
        /// Start a new tree if there's no room to add the new withdrawals
        uint startingIndex;
        bytes32 startingRoot;
        if (_block.header.prevWithdrawalIndex + numOfWithdrawals < POOL_SIZE) {
            /// it uses the latest tree
            startingIndex = _block.header.prevWithdrawalIndex;
            startingRoot = _block.header.prevWithdrawalRoot;
        } else {
            /// start a new tree
            startingIndex = 0;
            startingRoot = 0;
        }
        /// Submitted invalid index of the next withdrawal tree
        if (_block.header.nextWithdrawalIndex != (startingIndex + numOfWithdrawals)) {
            return Challenge(
                true,
                _block.submissionId,
                _block.header.proposer,
                "Withdrawal tree flushed"
            );
        }

        /// Check validity of the roll up using the storage based Keccak sub-tree roll up
        SplitRollUp memory proof = Layer2.proof.ofWithdrawalRollUp[withdrawalRollUpId];
        uint[] memory uintLeaves;
        assembly {
            uintLeaves := withdrawals
        }
        bool isValidRollUp = proof.verify(
            SubTreeRollUpLib.newSubTreeOPRU(
                uint(startingRoot),
                startingIndex,
                uint(_block.header.nextWithdrawalRoot),
                SUB_TREE_DEPTH,
                uintLeaves
            )
        );

        return Challenge(
            !isValidRollUp,
            _block.submissionId,
            _block.header.proposer,
            "Withdrawal roll up"
        );
    }
}
