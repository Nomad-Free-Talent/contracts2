// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

interface IValidatorRegistrySystem {
    error QueryValidationFailed();
    error ValidatorNodeAlreadyExists();
    error ValidatorNodeNotFound();
    error UnauthorizedProtocolAccess();

    error ValidatorNodeOffline();


    struct ValidatorNodeProfile {

        bytes20 validatorIdentityHash;

        bool operationalStatus;

        address nodeManagerAddress;

        string serviceEndpointUrl;

        address[] collateralTokenList;

        uint256[] collateralAmountList;
    }

    function enrollValidatorNode(
        address nodeAddress, 
        string calldata endpointUrl
    ) external;

    function removeValidatorNode(
        address nodeAddress
    ) external;

    function suspendValidatorNode(
        address nodeAddress
    ) external;

    function reactivateValidatorNode(
        address nodeAddress
    ) external;

    function validateNodeRegistration(
        address nodeAddress
    ) external view returns (bool);

  
}