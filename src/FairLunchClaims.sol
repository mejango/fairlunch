// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Holds the parts of each lunch's token supply that go to its creator and to a list of addresses, and hands
/// them out.
/// @dev `FairLunch` mints both here when the lunch is served. The creator's tokens vest linearly over the duration
/// fixed at creation, and anyone can send the creator what has vested with `release`.
/// A lunch's creator fixes the list at creation as a merkle root. Each entry is an address and its share of the
/// lunch's claims out of `SHARES_TOTAL`. `FairLunch` mints the claims here when the lunch is served. From then on
/// anyone can send any entry its tokens, forever. If the creator set a vesting duration, each entry's tokens vest
/// linearly over it from the moment the lunch is served, and a claim sends what has vested and hasn't been sent yet.
/// Nobody can change a list or take back what isn't claimed.
contract FairLunchClaims {
    using SafeERC20 for IERC20;

    //*********************************************************************//
    // --------------------------- custom errors ------------------------- //
    //*********************************************************************//

    error FairLunchClaims_NothingToClaim(uint256 projectId, address account);
    error FairLunchClaims_NotListed(uint256 projectId, address account, uint256 shares);
    error FairLunchClaims_NotServed(uint256 projectId);
    error FairLunchClaims_Unauthorized(address caller);

    //*********************************************************************//
    // ------------------------------- events ---------------------------- //
    //*********************************************************************//

    event Claim(uint256 indexed projectId, address indexed account, uint256 shares, uint256 tokenCount, address caller);
    event Fund(
        uint256 indexed projectId,
        IERC20 token,
        uint256 tokenCount,
        address creator,
        uint256 creatorTokenCount,
        uint32 creatorVestingDuration
    );
    event Release(uint256 indexed projectId, address indexed creator, uint256 tokenCount, address caller);
    event SetTerms(uint256 indexed projectId, uint32 percent, bytes32 root, uint32 vestingDuration);

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

    /// @notice The number of a lunch's tokens an address has been sent from its claims.
    /// @custom:param projectId The ID of the lunch's project.
    /// @custom:param account The address.
    mapping(uint256 projectId => mapping(address account => uint256)) public claimedBy;

    /// @notice The number of a lunch's tokens its creator has been sent.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint256) public creatorClaimedOf;

    /// @notice The address a lunch's creator tokens go to. Fixed when the lunch is served.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => address) public creatorOf;

    /// @notice The number of tokens minted for a lunch's creator when it was served.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint256) public creatorTokenCountOf;

    /// @notice The number of seconds over which a lunch's creator tokens vest. Zero if they're all sent at once.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint32) public creatorVestingDurationOf;

    /// @notice The number of tokens a lunch's claims have sent out so far.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint256) public totalClaimedOf;

    /// @notice When a lunch's claims were funded, which is when it was served and when they start vesting.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint48) public fundedAt;

    /// @notice The number of seconds over which a lunch's claims vest. Zero if they're all claimable at once.
    /// @custom:param projectId The ID of the lunch's project.
    mapping(uint256 projectId => uint32) public vestingDurationOf;

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

    /// @notice Send a listed address the part of a served lunch's claims that has vested for it.
    /// @dev Anyone can call this, as often as there's something vested to send. The tokens go to `account`.
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
        if (!MerkleProof.verifyCalldata({
                proof: proof,
                root: rootOf[projectId],
                leaf: keccak256(bytes.concat(keccak256(abi.encode(account, shares))))
            })) revert FairLunchClaims_NotListed({projectId: projectId, account: account, shares: shares});

        // ponytail: a list whose shares add up to more than `SHARES_TOTAL` runs out before its last claims. The list
        // is its creator's to get right.
        uint256 vested = Math.mulDiv(tokenCountOf[projectId], shares, SHARES_TOTAL);

        // What has vested so far: for this address, and for the whole list, so shares that add up to more than the
        // whole can't take tokens out ahead of the schedule.
        uint256 duration = vestingDurationOf[projectId];
        vested = _vestedOf({projectId: projectId, tokenCount: vested, duration: duration});
        uint256 available = _vestedOf({projectId: projectId, tokenCount: tokenCountOf[projectId], duration: duration})
            - totalClaimedOf[projectId];

        uint256 claimed = claimedBy[projectId][account];
        tokenCount = vested > claimed ? Math.min(vested - claimed, available) : 0;
        if (tokenCount == 0) revert FairLunchClaims_NothingToClaim({projectId: projectId, account: account});

        claimedBy[projectId][account] = claimed + tokenCount;
        totalClaimedOf[projectId] += tokenCount;
        token.safeTransfer({to: account, value: tokenCount});

        emit Claim({projectId: projectId, account: account, shares: shares, tokenCount: tokenCount, caller: msg.sender});
    }

    /// @notice Record the tokens `LUNCH` minted here for a lunch's claims and its creator, which opens both.
    /// @param projectId The ID of the lunch's project.
    /// @param token The lunch's token.
    /// @param tokenCount The number of tokens minted here for the claims.
    /// @param creator The address the creator's tokens go to.
    /// @param creatorTokenCount The number of tokens minted here for the creator.
    /// @param creatorVestingDuration The number of seconds over which the creator's tokens vest from now.
    function fund(
        uint256 projectId,
        IERC20 token,
        uint256 tokenCount,
        address creator,
        uint256 creatorTokenCount,
        uint32 creatorVestingDuration
    )
        external
        onlyLunch
    {
        tokenOf[projectId] = token;
        tokenCountOf[projectId] = tokenCount;
        creatorOf[projectId] = creator;
        creatorTokenCountOf[projectId] = creatorTokenCount;
        creatorVestingDurationOf[projectId] = creatorVestingDuration;
        fundedAt[projectId] = uint48(block.timestamp);
        emit Fund({
            projectId: projectId,
            token: token,
            tokenCount: tokenCount,
            creator: creator,
            creatorTokenCount: creatorTokenCount,
            creatorVestingDuration: creatorVestingDuration
        });
    }

    /// @notice Send a served lunch's creator the part of their tokens that has vested.
    /// @dev Anyone can call this, as often as there's something vested to send. The tokens go to the creator.
    /// @param projectId The ID of the lunch's project.
    /// @return tokenCount The number of tokens sent.
    function release(uint256 projectId) external returns (uint256 tokenCount) {
        IERC20 token = tokenOf[projectId];
        if (address(token) == address(0)) revert FairLunchClaims_NotServed(projectId);

        address creator = creatorOf[projectId];
        uint256 claimed = creatorClaimedOf[projectId];
        tokenCount = _vestedOf({
            projectId: projectId,
            tokenCount: creatorTokenCountOf[projectId],
            duration: creatorVestingDurationOf[projectId]
        }) - claimed;
        if (tokenCount == 0) revert FairLunchClaims_NothingToClaim({projectId: projectId, account: creator});

        creatorClaimedOf[projectId] = claimed + tokenCount;
        token.safeTransfer({to: creator, value: tokenCount});

        emit Release({projectId: projectId, creator: creator, tokenCount: tokenCount, caller: msg.sender});
    }

    /// @notice Fix a lunch's claims at its creation.
    /// @param projectId The ID of the lunch's project.
    /// @param percent The share of the lunch's total token supply its claims get.
    /// @param root The merkle root of the list.
    /// @param vestingDuration The number of seconds over which the claims vest once the lunch is served.
    function setTermsOf(uint256 projectId, uint32 percent, bytes32 root, uint32 vestingDuration) external onlyLunch {
        percentOf[projectId] = percent;
        rootOf[projectId] = root;
        vestingDurationOf[projectId] = vestingDuration;
        emit SetTerms({projectId: projectId, percent: percent, root: root, vestingDuration: vestingDuration});
    }

    //*********************************************************************//
    // ------------------------ internal views --------------------------- //
    //*********************************************************************//

    /// @notice The part of a number of a lunch's tokens that has vested, linearly from when the lunch was served.
    /// @param projectId The ID of the lunch's project.
    /// @param tokenCount The number of tokens vesting.
    /// @param duration The number of seconds they vest over.
    /// @return The number of them that has vested.
    function _vestedOf(uint256 projectId, uint256 tokenCount, uint256 duration) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - fundedAt[projectId];
        return elapsed < duration ? Math.mulDiv(tokenCount, elapsed, duration) : tokenCount;
    }
}
