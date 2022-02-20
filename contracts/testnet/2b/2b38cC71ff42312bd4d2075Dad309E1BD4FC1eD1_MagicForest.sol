// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./Pausable.sol";
import "./ERC721Enumerable.sol";
import "./Restricted.sol";

import "./Skeleton.sol";
import "./Glow.sol";
import "./AttributesPets.sol";
import "./Pets.sol";

contract MagicForest is IERC721Receiver, Pausable, Restricted {
    // maximum alpha score for a Hunter
    uint8 public constant MAX_ALPHA = 10;
    uint8 public constant MAX_VIRTUAL_ALPHA = 17;

    // struct to store a stake's token, owner, and earning values
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address indexed owner, uint256 indexed tokenId);
    event TokenClaimed(address indexed owner, uint256 indexed tokenId, uint256 earned, bool unstaked);
    event RangerUnstaked(address indexed owner, uint256 indexed tokenId, bool stolen);

    Glow public glow;
    Skeleton public skeleton;
    Pets public pets;

    mapping(address => uint256) public walletToNumberStaked;
    // maps tokenId to stake
    mapping(uint256 => Stake) public barn;
    // maps alpha to all hunter stakes with that alpha
    mapping(uint256 => Stake[]) public pack;
    // tracks location of each Hunter in Pack
    mapping(uint256 => uint256) public packIndices;
    // total alpha scores staked
    uint256 public totalAlphaStaked = 0;
    // any rewards distributed when no hunters are staked
    uint256 public unaccountedRewards = 0;
    // amount of $GLOW due for each alpha point staked
    uint256 public glowPerAlpha = 0;

    // adventurer earn 5000 $GLOW per day
    uint256 public constant DAILY_GLOW_RATE = 5000 ether;
    // adventurer must have 2 days worth of $GLOW to unstake or else it's too cold
    uint256 public constant MINIMUM_TO_EXIT = 2 days;
    // hunters take a 20% tax on all $GLOW claimed
    uint8 public constant GLOW_CLAIM_TAX_PERCENTAGE = 20;
    // there will only ever be (roughly) 2.4 billion $GLOW earned through staking
    uint256 public MAXIMUM_GLOBAL_GLOW = 2400000000 ether;
    //tax on claim
    uint256 public MAX_CLAIMING_FEE = 5000 wei; // 0.05 FOR REAL LAUNCH
    uint256 public MIN_CLAIMING_FEE = 0;

    // amount of $GLOW earned so far
    uint256 public totalGlowEarned;
    // the last time $GLOW was claimed
    uint256 public lastRangerClaimTimestamp;

    uint256 public totalRangerStaked;
    uint256 public totalSkeletonStaked;
    
    uint8[5] productionSpeedByLevel = [0, 5, 10, 20, 30];

    // Claim is disabled while the liquidity is not added
    bool public claimEnabled;

    uint80[20] public lastClaimTimestamps;
    uint8 private _nextClaimIndex;

    /**
     * @param _skeleton reference to the Skeleton NFT contract
     * @param _glow reference to the $GLOW token
     */
    constructor(address _glow, address _skeleton) {
        setGlow(_glow);
        setSkeleton(_skeleton);
    }

    /** STAKING */

    /**
     * Stakes Rangers and Skeletons in the MagicForest
     * @param tokenIds the IDs of the Rangers and Skeletons to stake
     */
    function stakeMany(uint16[] memory tokenIds)
        external
        whenNotPaused
        onlyEOA
        noReentrency
        notBlacklisted
    {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            _stakeOne(_msgSender(), tokenIds[i]);
        }
        walletToNumberStaked[_msgSender()] += tokenIds.length;
    }

    /**
     * Internal function to stake one Ranger or Skeleton in the MagicForest
     * @param account the address of the staker
     * @param tokenId the ID of the Adventurer or Hunter to stake
     */
    function _stakeOne(address account, uint16 tokenId) internal {
        require(skeleton.ownerOf(tokenId) == account, "Not your token");

        skeleton.transferFrom(account, address(this), tokenId);
        
        (bool isRanger, uint8 alphaIndex, uint8 level) = getTokenStats(tokenId);
        if (isRanger) {
            _stakeRanger(account, tokenId);
        } else  {
            AttributesPets.Boost memory walletBoost = pets.getWalletBoost(account);
            uint8 virtualAlpha = _getVirtualAlpha(alphaIndex, level, walletBoost);
            _stakeSkeleton(account, tokenId, virtualAlpha);
        }

        uint256 petId = pets.rangerTokenToPetToken(tokenId);
        if (petId != 0){
            pets.transferFrom(account, address(this), petId);
        }
    }

    /**
     * Stakes a Ranger
     * @dev Rangers go to barn
     * @param account the address of the staker
     * @param tokenId Id of the Ranger to stake
     */
    function _stakeRanger(address account, uint256 tokenId) internal whenNotPaused _updateEarnings {
        barn[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        totalRangerStaked += 1;
        emit TokenStaked(account, tokenId);
    }

    /**
     * Stakes a Skeleton
     * @dev Skeletons go to pack
     * @param account the address of the staker
     * @param tokenId Id of the Skeleton to stake
     * @param virtualAlpha Virtual alpha of the skeleton (alpha + level + boost)
     */
    function _stakeSkeleton(address account, uint256 tokenId, uint8 virtualAlpha) internal {
        totalAlphaStaked += virtualAlpha; // Portion of earnings ranges from 10 to 5
        packIndices[tokenId] = pack[virtualAlpha].length; // Store the location of the hunter in the Pack
        pack[virtualAlpha].push(
            Stake({
                owner: account,
                tokenId: uint16(tokenId),
                value: uint80(glowPerAlpha)
            })
        ); // Add the skeleton to the Pack
        totalSkeletonStaked++;
        emit TokenStaked(account, tokenId);
    }

    /** CLAIMING / UNSTAKING */

    /**
     * realize $GLOW earnings and optionally unstake tokens from the Barn / Pack
     * to unstake a Adventurer it will require it has 2 days worth of $GLOW unclaimed
     * @param tokenIds the IDs of the tokens to claim earnings from
     * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
     */
    function claimMany(uint16[] memory tokenIds, bool unstake)
        external
        payable
        whenNotPaused
        onlyEOA
        noReentrency
        notBlacklisted 
        _updateEarnings
    {
        require(claimEnabled, "Claiming not yet available");
        require(msg.value >= tokenIds.length * getClaimingFee(), "You didn't pay tax");

        _updateLastClaimTimestamps(uint80(block.timestamp));

        AttributesPets.Boost memory walletBoost = pets.getWalletBoost(_msgSender());
        uint256 lastGlowTransfer = glow.lastTransfer(_msgSender());
        uint256 numberStaked = walletToNumberStaked[_msgSender()];

        if (unstake) walletToNumberStaked[_msgSender()] -= tokenIds.length;

        uint256 owed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (bool isRanger, uint8 alphaIndex, uint8 level) = getTokenStats(tokenIds[i]);
            if (isRanger) {
                owed += _claimRanger(tokenIds[i], unstake, level, walletBoost, lastGlowTransfer, numberStaked);
            } else {
                uint8 virtualAlpha = _getVirtualAlpha(alphaIndex, level, walletBoost);
                owed += _claimSkeleton(tokenIds[i], unstake, virtualAlpha);
            }
        }

        if (owed > 0) glow.mint(_msgSender(), owed);
    }

    function _claimRanger(
        uint256 tokenId,
        bool unstake,
        uint8 level,
        AttributesPets.Boost memory walletBoost,
        uint256 lastGlowTransfer,
        uint256 numberStaked
    ) internal returns (uint256 owed) {
        require(skeleton.ownerOf(tokenId) == address(this), "Not in Magic Forest");

        Stake memory stake = barn[tokenId];

        require(stake.owner == _msgSender(), "Not your token");

        AttributesPets.Boost memory rangerBoost = pets.getRangerBoost(tokenId);

        owed = _calculateRangerRewards(level, stake.value, walletBoost, rangerBoost, lastGlowTransfer, numberStaked);

        if (unstake) {
            require(
                block.timestamp - stake.value < _getMinimumToExit(rangerBoost),
                "Need to wait some days before unstake"
            );

            if (_isStolen(tokenId, rangerBoost)) {
                // 50% chance of all $GLOW stolen
                _paySkeletonTax(owed);
                owed = 0;
                emit RangerUnstaked(stake.owner, tokenId, true);
            } else {
                emit RangerUnstaked(stake.owner, tokenId, false);
            }

            skeleton.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // send back Ranger
            uint256 petToken = pets.rangerTokenToPetToken(tokenId);
            if (petToken != 0) {
                pets.transferFrom(address(this), _msgSender(), petToken); // send back the pet
            }
            delete barn[tokenId];
            totalRangerStaked--;
        } else {
            uint256 glowClaimtaxPercentage = _getClaimTaxPercentage(rangerBoost);
            _paySkeletonTax((owed * glowClaimtaxPercentage) / 100); // percentage tax to staked hunters
            owed = (owed * (100 - glowClaimtaxPercentage)) / 100; // remainder goes to Adventurer owner
            barn[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            }); // reset stake
        }
        
        emit TokenClaimed(stake.owner, tokenId, owed, unstake);
    }

    function _claimSkeleton(uint256 tokenId, bool unstake, uint8 virtualAlpha) internal returns (uint256 owed) {
        require(skeleton.ownerOf(tokenId) == address(this), "Not in Magic Forest");

        Stake memory stake = pack[virtualAlpha][packIndices[tokenId]];

        require(stake.owner == _msgSender(), "Not your token");
        owed = _calculateSkeletonRewards(virtualAlpha, stake.value);
        if (unstake) {
            totalAlphaStaked -= virtualAlpha; // Remove Alpha from total staked
            skeleton.safeTransferFrom(address(this), _msgSender(), tokenId, ""); // Send back Hunter
            Stake memory lastStake = pack[virtualAlpha][pack[virtualAlpha].length - 1];
            pack[virtualAlpha][packIndices[tokenId]] = lastStake; // Shuffle last Hunter to current position
            packIndices[lastStake.tokenId] = packIndices[tokenId];
            pack[virtualAlpha].pop(); // Remove duplicate
            delete packIndices[tokenId]; // Delete old mapping
            totalSkeletonStaked--;
        } else {
            pack[virtualAlpha][packIndices[tokenId]] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(glowPerAlpha)
            }); // reset stake
        }
        emit TokenClaimed(stake.owner, tokenId, owed, unstake);
    }

    /**
     * Add $GLOW to claimable pot for the Pack
     * @param amount $GLOW to add to the pot
     */
    function _paySkeletonTax(uint256 amount) internal {
        if (totalAlphaStaked == 0) {
            // if there's no staked hunters
            unaccountedRewards += amount; // keep track of $GLOW due to hunters
            return;
        }
        // makes sure to include any unaccounted $GLOW
        glowPerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
        unaccountedRewards = 0;
    }

    /**
     * Tracks $GLOW earnings to ensure it stops once 2.4 billion is eclipsed
     */
    modifier _updateEarnings() {
        if (totalGlowEarned < MAXIMUM_GLOBAL_GLOW) {
            totalGlowEarned +=
                ((block.timestamp - lastRangerClaimTimestamp) *
                    totalRangerStaked *
                    DAILY_GLOW_RATE) /
                1 days;
            lastRangerClaimTimestamp = block.timestamp;
        }
        _;
    }

    /* READING */

    function calculateRewards(uint256 tokenId) external view returns (uint256) {
        (bool isRanger, uint8 alphaIndex, uint8 level) = getTokenStats(tokenId);
        if (isRanger) {
            Stake memory stake = barn[tokenId];
            if (stake.tokenId == tokenId) {
                AttributesPets.Boost memory walletBoost = pets.getWalletBoost(stake.owner);
                AttributesPets.Boost memory rangerBoost = pets.getRangerBoost(tokenId);
                uint256 lastGlowTransfer = glow.lastTransfer(stake.owner);
                uint256 numberStaked = walletToNumberStaked[stake.owner];
                return _calculateRangerRewards(level, stake.value, walletBoost, rangerBoost, lastGlowTransfer, numberStaked);
            } else {
                return 0;
            }
        } else {
            for (uint8 virtualAlpha = alphaIndex; virtualAlpha <= MAX_VIRTUAL_ALPHA; virtualAlpha++) {
                if (pack[virtualAlpha].length > packIndices[tokenId]) {
                    Stake memory stake = pack[virtualAlpha][packIndices[tokenId]];
                    if (stake.tokenId == tokenId) {
                        return _calculateSkeletonRewards(virtualAlpha, stake.value);
                    }
                }
            }
            return 0;
        }
    }

    function getClaimTaxPercentage(uint256 tokenId) external view returns(uint256){
        AttributesPets.Boost memory rangerBoost = pets.getRangerBoost(tokenId);
        return _getClaimTaxPercentage(rangerBoost);
    }

    function getMinimumToExit(uint256 tokenId) external view returns(uint256){
        AttributesPets.Boost memory rangerBoost = pets.getRangerBoost(tokenId);
        return _getMinimumToExit(rangerBoost);
    }

    function getClaimingFee() public view returns (uint256) {
        uint256 totalTimeStamp;
        for (uint8 i = 0; i < lastClaimTimestamps.length; i++) {
            totalTimeStamp += lastClaimTimestamps[i];
        }
        uint256 reduction =  (block.timestamp - (totalTimeStamp / lastClaimTimestamps.length)) * (MAX_CLAIMING_FEE - MIN_CLAIMING_FEE) / 1 days;
        return reduction >= MAX_CLAIMING_FEE - MIN_CLAIMING_FEE ? MIN_CLAIMING_FEE : MAX_CLAIMING_FEE - reduction;
    }

    /* INTERNAL COMPUTATIONS */

    function _calculateRangerRewards(
        uint8 level,
        uint80 stakeValue,
        AttributesPets.Boost memory walletBoost,
        AttributesPets.Boost memory rangerBoost,
        uint256 lastGlowTransfer,
        uint256 numberStaked
    ) internal view returns (uint256 owed) {
        uint256 dailyGlowRate = _getDailyGlowrate(level, walletBoost, rangerBoost, lastGlowTransfer, numberStaked);

        if (totalGlowEarned < MAXIMUM_GLOBAL_GLOW) {
            owed = ((block.timestamp - stakeValue) * dailyGlowRate) / 1 days;
        } else if (stakeValue > lastRangerClaimTimestamp) {
            // $GLOW production stopped already
            owed = 0; 
        } else {
            // Stop earning additional $GLOW if it's all been earned
            owed = ((lastRangerClaimTimestamp - stakeValue) * dailyGlowRate) / 1 days;
        }

        // limit adventurer wage based on their level (limited inventory)
        uint256 maxGlow = 5000 ether * level;
        owed = owed > maxGlow ? maxGlow : owed;
    }

    function _calculateSkeletonRewards(uint8 virtualAlpha, uint80 stakeValue) internal view returns(uint256) {
        return virtualAlpha * (glowPerAlpha - stakeValue);
    }

    /**
     * Computes the alpha score used for rewards computation
     * @param alphaIndex Actual alpha score
     * @param level Level of the skeleton
     * @param walletBoost Wallet boost of the pet equiped
     * @return the virtual alpha score
     */
    function _getVirtualAlpha(
        uint8 alphaIndex,
        uint8 level,
        AttributesPets.Boost memory walletBoost
    ) internal pure returns (uint8) {
        uint8 alphaFromLevel = level - 1  + (level  == 5 ? 1 : 0);
        return MAX_ALPHA - alphaIndex + walletBoost.alphaAugmentation + alphaFromLevel; // alpha index is 0-3
    }

    function _getClaimTaxPercentage(AttributesPets.Boost memory rangerBoost) internal pure returns(uint8) {
        assert(rangerBoost.claimTaxReduction <= 20);
        return GLOW_CLAIM_TAX_PERCENTAGE - rangerBoost.claimTaxReduction;
    }

    function _getMinimumToExit(AttributesPets.Boost memory rangerBoost) internal pure returns(uint256) {
        return (MINIMUM_TO_EXIT * (100 + rangerBoost.unstakeCooldownAugmentation)) / 100;
    }

    function _getDailyGlowrate(
        uint8 level,
        AttributesPets.Boost memory walletBoost,
        AttributesPets.Boost memory rangerBoost,
        uint256 lastGlowTransfer,
        uint256 numberStaked
    ) internal view returns(uint256){
        
        uint256 totalBoost = 100;

        // Bonus of increase in $GLOW production
        totalBoost += rangerBoost.productionSpeed;

        // Increase adventurer wage based on their level
        totalBoost += productionSpeedByLevel[level-1];

        // Bonus based on the number of NFTs staked
        if (numberStaked <= 5) {
            totalBoost += rangerBoost.productionSpeedByNFTStaked[0];
        }else if (numberStaked <= 10) {
            totalBoost += rangerBoost.productionSpeedByNFTStaked[1];
        } else if (numberStaked <= 20) {
            totalBoost += rangerBoost.productionSpeedByNFTStaked[2];
        } else {
            totalBoost += rangerBoost.productionSpeedByNFTStaked[3];
        }

        // Bonus based on the time spent without selling $GLOW
        if (block.timestamp  - lastGlowTransfer <= 1 days) {
            totalBoost += rangerBoost.productionSpeedByTimeWithoutTransfer[0];
        } else if (block.timestamp  - lastGlowTransfer <= 2 days) {
            totalBoost += rangerBoost.productionSpeedByTimeWithoutTransfer[1];
        } else if (block.timestamp  - lastGlowTransfer <= 3 days) {
            totalBoost += rangerBoost.productionSpeedByTimeWithoutTransfer[2];
        } else{
            totalBoost += rangerBoost.productionSpeedByTimeWithoutTransfer[3];
        }

        // Wallet bonus based on the number of NFTs staked
        if (numberStaked <= 9) {
            totalBoost += walletBoost.globalProductionSpeedByNFTStaked[0];
        } else if (numberStaked <= 19) {
            totalBoost += walletBoost.globalProductionSpeedByNFTStaked[1];
        } else if (numberStaked <= 29) {
            totalBoost += walletBoost.globalProductionSpeedByNFTStaked[2];
        } else {
            totalBoost += walletBoost.globalProductionSpeedByNFTStaked[3];
        }

        // Wallet bonus of increase in $GLOW production
        totalBoost += walletBoost.globalProductionSpeed;

        return DAILY_GLOW_RATE * totalBoost / 100;
    }

    function _chanceToGetStolen(AttributesPets.Boost memory rangerBoost) internal pure returns(uint8) {
        return 50 - rangerBoost.unstakeStealReduction + rangerBoost.unstakeStealAugmentation;
    }

    function _isStolen(uint256 tokenId, AttributesPets.Boost memory rangerBoost) internal view returns (bool) {
        uint256 randomNumber =  uint256(keccak256(abi.encodePacked(_msgSender(), blockhash(block.number - 1), tokenId)));
        uint256 treshold = _chanceToGetStolen(rangerBoost);
        return uint16(randomNumber & 0xFFFF) % 100 < treshold;
    }

    function _updateLastClaimTimestamps(uint80 ts) internal {
        lastClaimTimestamps[_nextClaimIndex] = ts;
        _nextClaimIndex = uint8((_nextClaimIndex + 1) % lastClaimTimestamps.length);
    }

    /** READ ONLY */

    function getTokenStats(uint256 tokenId) public view returns (bool isRanger, uint8 alphaIndex, uint8 level) {
        (isRanger, , , , , , , , alphaIndex, level) = skeleton.tokenTraits(tokenId);
    }

    /**
     * Chooses a random Skeleton thief when a newly minted token is stolen
     * @dev Only called by the contract Skeleton
     * @param seed a random value to choose a Skelton from
     * @return the owner of the randomly selected Skeleton thief
     */
    function randomSkeletonOwner(uint256 seed) external view returns (address) {
        if (totalAlphaStaked == 0) return address(0x0);
        uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked; // choose a value from 0 to total alpha staked
        uint256 cumulative;
        seed >>= 32;
        // loop through each bucket of Hunters with the same alpha score
        for (uint256 i = 0; i <= 20; i++) {
            cumulative += pack[i].length * i;
            // if the value is not inside of that bucket, keep going
            if (bucket >= cumulative) continue;
            // get the address of a random Hunter with that alpha score
            return pack[i][seed % pack[i].length].owner;
        }
        return address(0x0);
    }

    /* TOKEN TRANSFERS */

    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to MagicForest directly");
        return IERC721Receiver.onERC721Received.selector;
    }

    /* MONEY TRANSFERS */

    function withdraw() external onlyController {
        payable(owner()).transfer(address(this).balance);
    }

    /* GAME MANAGEMENT */

    function setPaused(bool _paused) external onlyController {
        if (_paused) _pause();
        else _unpause();
    }

    function toggleClaimEnabled() external onlyController {
        claimEnabled = !claimEnabled;
    }

    function setMaximumGlobalGlow(uint256 _maximumGlobalGlow) external onlyController {
        MAXIMUM_GLOBAL_GLOW = _maximumGlobalGlow;
    }

    function setMaxClaimingFee(uint256 _claimingFee) external onlyController {
        MAX_CLAIMING_FEE = _claimingFee;
    }

    function setMinClaimingFee(uint256 _claimingFee) external onlyController {
        MIN_CLAIMING_FEE = _claimingFee;
    }

    /* ADDRESSES SETTERS */

    function setGlow(address _glow) public onlyController {
        glow = Glow(_glow);
    }

    function setSkeleton(address _skeleton) public onlyController {
        skeleton = Skeleton(_skeleton);
    }

    function setPets(address _pets) public onlyController{
        pets = Pets(_pets);
    }
}