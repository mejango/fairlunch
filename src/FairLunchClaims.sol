// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Holds the part of each lunch's token supply that goes to a list of addresses, and hands it out.
/// @dev A lunch's creator fixes the list at creation as a merkle root. Each entry is an address and its share of the
/// lunch's claims out of `SHARES_TOTAL`. `FairLunch` mints the claims here when the lunch is served. From then on
/// anyone can send any entry its tokens, forever. Nobody can change a list or take back what isn't claimed.
contract FairLunchClaims {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error FairLunchClaims_AlreadyClaimed(uint256 projectId, address account);
    error FairLunchClaims_NotListed(uint256 projectId, address account, uint256 shares);
    error FairLunchClaims_NotServed(uint256 projectId);
    error FairLunchClaims_Unauthorized(address caller);

    //*********************************************************************//
    // ------------------------------- events ---------------------------- //
    //*********************************************************************//

    event Claim(uint256 indexed projectId, address indexed account, uint256 shares, uint256 tokenCount, address caller);
    event Fund(uint256 indexed projectId, IERC20 token, uint256 tokenCount);
    event SetTerms(uint256 indexed projectId, uint32 percent, bytes32 root);

    //*********************************************************************//
    // ------------------------- public constants ------------------------ //
    //*********************************************************************//

    /// @notice What a list's shares are out of.
    uint256 public constant SHARES_TOTAL = 1e18;

    //*********************************************************************//
    // --------------- public immutable stored properties ---------------- //
    //*********************************************************************//

    /// @notice The `FairLunch` that made this contract, the only address that can set terms and fund them.
    address public immutable LUNCH;

    //*********************************************************************//
    // --------------------- public stored properties -------------------- //
    //*********************************************************************//

    /// @notice Whether an address has been sent its part of a lunch's claims.
    /// @custom:param projectId The ID of the lunch's project.
    /// @custom:param account The address.
    mapping(uint256 projectId => mapping(address account => bool)) public claimedBy;

    /// @notice The share of a lunch's total token supply its claims get, out of `JBConstants.SPLITS_TOTAL_PERCENT`.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint32) public percentOf;

    /// @notice The merkle root of a lunch's list. A leaf is `keccak256(bytes.concat(keccak256(abi.encode(account,
    /// shares))))`.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => bytes32) public rootOf;

    /// @notice A lunch's token. Zero until the lunch is served.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => IERC20) public tokenOf;

    /// @notice The number of tokens minted for a lunch's claims when it was served.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint256) public tokenCountOf;

    //*********************************************************************//
    // ---------------------------- modifiers ---------------------------- //
    //*********************************************************************//

    modifier onlyLunch() {
        if (msg.sender != LUNCH) revert FairLunchClaims_Unauthorized(msg.sender);
        _;
    }

    //*********************************************************************//
    // -------------------------- constructor ---------------------------- //
    //*********************************************************************//

    constructor() {
        LUNCH = msg.sender;
    }

    //*********************************************************************//
    // ---------------------- external transactions ---------------------- //
    //*********************************************************************//

    /// @notice Send a listed address its part of a served lunch's claims.
    /// @dev Anyone can call this. The tokens go to `account`.
    /// @param projectId The ID of the lunch's project.
    /// @param account The listed address.
    /// @param shares The address's share of the claims, out of `SHARES_TOTAL`, as listed.
    /// @param proof The merkle proof of the entry.
    /// @return tokenCount The number of tokens sent.
    function claim(
        uint256 projectId,
        address account,
        uint256 shares,
        bytes32[] calldata proof
    )
        external
        returns (uint256 tokenCount)
    {
        IERC20 token = tokenOf[projectId];
        if (address(token) == address(0)) revert FairLunchClaims_NotServed(projectId);
        if (claimedBy[projectId][account]) {
            revert FairLunchClaims_AlreadyClaimed({projectId: projectId, account: account});
        }

        if (!MerkleProof.verifyCalldata({
                proof: proof,
                root: rootOf[projectId],
                leaf: keccak256(bytes.concat(keccak256(abi.encode(account, shares))))
            })) revert FairLunchClaims_NotListed({projectId: projectId, account: account, shares: shares});

        claimedBy[projectId][account] = true;

        // ponytail: a list whose shares add up to more than `SHARES_TOTAL` runs out before its last claims. The list
        // is its creator's to get right.
        tokenCount = Math.mulDiv(tokenCountOf[projectId], shares, SHARES_TOTAL);
        token.safeTransfer({to: account, value: tokenCount});

        emit Claim({projectId: projectId, account: account, shares: shares, tokenCount: tokenCount, caller: msg.sender});
    }

    /// @notice Record the tokens `LUNCH` minted here for a lunch's claims, which opens them.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's token.
    /// @param tokenCount The number of tokens minted here.
    function fund(uint256 projectId, IERC20 token, uint256 tokenCount) external onlyLunch {
        tokenOf[projectId] = token;
        tokenCountOf[projectId] = tokenCount;
        emit Fund({projectId: projectId, token: token, tokenCount: tokenCount});
    }

    /// @notice Fix a lunch's claims at its creation.
    /// @param projectId The ID of the lunch's project.
    /// @param percent The share of the lunch's total token supply its claims get.
    /// @param root The merkle root of the list.
    function setTermsOf(uint256 projectId, uint32 percent, bytes32 root) external onlyLunch {
        percentOf[projectId] = percent;
        rootOf[projectId] = root;
        emit SetTerms({projectId: projectId, percent: percent, root: root});
    }
}
