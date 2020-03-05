pragma solidity >= 0.6.0;

import { Coordinatable } from "./controllers/Coordinatable.sol";
import { SNARKsVerifier } from "./libraries/SNARKs.sol";
import { Pairing } from "./libraries/Pairing.sol";
import { IUserInteractable } from "./interfaces/IUserInteractable.sol";
import { IRollUpable } from "./interfaces/IRollUpable.sol";
import { IMigratable } from "./interfaces/IMigratable.sol";
import { IDepositChallenge } from "./interfaces/IDepositChallenge.sol";
import { IHeaderChallenge } from "./interfaces/IHeaderChallenge.sol";
import { IMigrationChallenge } from "./interfaces/IMigrationChallenge.sol";
import { IRollUpChallenge } from "./interfaces/IRollUpChallenge.sol";
import { ITxChallenge } from "./interfaces/ITxChallenge.sol";


contract Layer2Controller is Coordinatable {
    /** Addresses where to execute the given function call */
    mapping(bytes4=>address) public proxied;

    /**
     * @notice This proxies supports the following interfaces
     *          - ICoordinatable.sol
     *          - IUserInteractable.sol
     *          - IRollUpable.sol
     *          - IChallengeable.sol
     *          - IMigratable.sol
     */
    fallback () external payable {
        bytes4 sig = abi.decode(msg.data[:4], (bytes4));
        address addr = proxied[sig];
        assembly {
            let freememstart := mload(0x40)
            calldatacopy(freememstart, 0, calldatasize())
            let success := delegatecall(not(0), addr, freememstart, calldatasize(), freememstart, 32)
            switch success
            case 0 { revert(freememstart, 32) }
            default { return(freememstart, 32) }
        }
    }

    /**
     * @dev See Coordinatable.sol's register() function
    */
    receive() external payable {
        Coordinatable.register();
    }

    function _connectUserInteractable(address addr) internal {
        _connect(addr, IUserInteractable(0).deposit.selector);
        _connect(addr, IUserInteractable(0).withdraw.selector);
        _connect(addr, IUserInteractable(0).withdrawUsingSignature.selector);
    }

    function _connectRollUpable(address addr) internal {
        _connect(addr, IRollUpable(0).newProofOfUTXORollUp.selector);
        _connect(addr, IRollUpable(0).newProofOfNullifierRollUp.selector);
        _connect(addr, IRollUpable(0).newProofOfWithdrawalRollUp.selector);
        _connect(addr, IRollUpable(0).updateProofOfUTXORollUp.selector);
        _connect(addr, IRollUpable(0).updateProofOfNullifierRollUp.selector);
        _connect(addr, IRollUpable(0).updateProofOfWithdrawalRollUp.selector);
    }

    function _connectChallengeable(
        address depositChallenge,
        address headerChallenge,
        address migrationChallenge,
        address rollUpChallenge,
        address txChallenge
    ) internal virtual {
        _connect(depositChallenge, IDepositChallenge(0).challengeMassDeposit.selector);
        _connect(headerChallenge, IHeaderChallenge(0).challengeDepositRoot.selector);
        _connect(headerChallenge, IHeaderChallenge(0).challengeTxRoot.selector);
        _connect(headerChallenge, IHeaderChallenge(0).challengeMigrationRoot.selector);
        _connect(headerChallenge, IHeaderChallenge(0).challengeTotalFee.selector);
        _connect(migrationChallenge, IMigrationChallenge(0).challengeMassMigrationToMassDeposit.selector);
        _connect(migrationChallenge, IMigrationChallenge(0).challengeERC20Migration.selector);
        _connect(migrationChallenge, IMigrationChallenge(0).challengeERC721Migration.selector);
        _connect(rollUpChallenge, IRollUpChallenge(0).challengeUTXORollUp.selector);
        _connect(rollUpChallenge, IRollUpChallenge(0).challengeNullifierRollUp.selector);
        _connect(rollUpChallenge, IRollUpChallenge(0).challengeWithdrawalRollUp.selector);
        _connect(txChallenge, ITxChallenge(0).challengeInclusion.selector);
        _connect(txChallenge, ITxChallenge(0).challengeTransaction.selector);
        _connect(txChallenge, ITxChallenge(0).challengeUsedNullifier.selector);
        _connect(txChallenge, ITxChallenge(0).challengeDuplicatedNullifier.selector);
        _connect(txChallenge, ITxChallenge(0).isValidRef.selector);
    }

    function _connectMigratable(address addr) internal virtual {
        _connect(addr, IMigratable(0).migrateTo.selector);
    }

    function _connect(address to, bytes4 sig) internal {
        proxied[sig] = to;
    }
}
