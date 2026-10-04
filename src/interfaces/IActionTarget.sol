// SPDX-License-Identifier: MIT
pragma solidity =0.8.17;

struct TokenActionPair {
    address tokenAddress;
    uint256 actionId;
}

interface IExtensionCenterEvents {
    event AddAccount(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        address indexed account,
        uint256 accountCount
    );
    event RemoveAccount(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        address indexed account,
        uint256 accountCount
    );
    event UpdateVerificationInfo(
        address indexed tokenAddress,
        uint256 round,
        uint256 indexed actionId,
        address indexed account,
        string verificationKey,
        string verificationInfo
    );
    event SetExtensionDelegate(
        address indexed extension,
        address indexed delegate
    );
    event RegisterAction(
        address indexed tokenAddress,
        uint256 indexed actionId,
        address indexed extension,
        address factory
    );
}

interface IExtensionCenterErrors {
    error OnlyExtensionOrDelegate();
    error OnlyAccountOrExtensionOrDelegate();
    error AccountAlreadyJoined();
    error VerificationInfoLengthMismatch(uint256 expected);
    error ActionNotVotedInCurrentRound();
    error InvalidExtensionFactory();
    error ActionAlreadyRegisteredToOtherAction();
    error InvalidExtensionAddress();
    error InvalidAccountAddress();
    error RoundExceedsJoinRound(uint256 currentRound);
    error ExtensionCreatorMismatch(address creator, address author);
    error ExtensionTokenAddressMismatch(address expected, address actual);
    error ExtensionActionIdMismatch(uint256 expected, uint256 actual);
}

interface IExtensionCenter is IExtensionCenterEvents, IExtensionCenterErrors {
    function uniswapV2FactoryAddress() external view returns (address);
    function launchAddress() external view returns (address);
    function stakeAddress() external view returns (address);
    function submitAddress() external view returns (address);
    function voteAddress() external view returns (address);
    function joinAddress() external view returns (address);
    function verifyAddress() external view returns (address);
    function mintAddress() external view returns (address);
    function randomAddress() external view returns (address);

    // must be called before any other function
    function registerActionIfNeeded(
        address tokenAddress,
        uint256 actionId
    ) external returns (address extensionAddress);

    function addAccount(
        address tokenAddress,
        uint256 actionId,
        address account,
        string[] calldata verificationInfos
    ) external;

    function removeAccount(
        address tokenAddress,
        uint256 actionId,
        address account
    ) external returns (bool);

    function updateVerificationInfo(
        address tokenAddress,
        uint256 actionId,
        address account,
        string[] calldata verificationInfos
    ) external;

    function setExtensionDelegate(address delegate) external;

    function extension(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address);

    function factory(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address);

    function extensionDelegate(
        address extensionAddress
    ) external view returns (address);

    function extensionTokenActionPair(
        address extensionAddress
    ) external view returns (address tokenAddress, uint256 actionId);

    function isAccountJoined(
        address tokenAddress,
        uint256 actionId,
        address account
    ) external view returns (bool);

    function isAccountJoinedByRound(
        address tokenAddress,
        uint256 actionId,
        address account,
        uint256 round
    ) external view returns (bool);

    function actionIdsByAccount(
        address tokenAddress,
        address account,
        address[] calldata factories
    )
        external
        view
        returns (
            uint256[] memory actionIds,
            address[] memory extensions,
            address[] memory factories_
        );

    function accounts(
        address tokenAddress,
        uint256 actionId
    ) external view returns (address[] memory);

    function accountsCount(
        address tokenAddress,
        uint256 actionId
    ) external view returns (uint256);

    function accountsAtIndex(
        address tokenAddress,
        uint256 actionId,
        uint256 index
    ) external view returns (address);

    function accountsByRound(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (address[] memory);

    function accountsByRoundCount(
        address tokenAddress,
        uint256 actionId,
        uint256 round
    ) external view returns (uint256);

    function accountsByRoundAtIndex(
        address tokenAddress,
        uint256 actionId,
        uint256 index,
        uint256 round
    ) external view returns (address);

    function verificationInfo(
        address tokenAddress,
        uint256 actionId,
        address account,
        string calldata verificationKey
    ) external view returns (string memory);

    function verificationInfoByRound(
        address tokenAddress,
        uint256 actionId,
        address account,
        string calldata verificationKey,
        uint256 round
    ) external view returns (string memory);
}
