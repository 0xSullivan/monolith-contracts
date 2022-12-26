pragma solidity 0.8.16;

interface ILpDepositor {
    function tokenID() external returns (uint256);

    function setTokenID(uint256 tokenID) external returns (bool);

    function userBalances(address user, address pool)
        external
        view
        returns (uint256);

    function totalBalances(address pool) external view returns (uint256);

    function transferDeposit(
        address pool,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function whitelist(address token) external returns (bool);

    function attachedGauges(uint256 index) external returns (address);

    function attachedGaugesLength() external returns (uint256);

    function validGauges(uint256 index) external returns (address);

    function validGaugesLength() external returns (uint256);

    function detachGauges(uint256 fromIndex, uint256 toIndex) external;

    function rettachGauges(uint256 fromIndex, uint256 toIndex) external;
}
