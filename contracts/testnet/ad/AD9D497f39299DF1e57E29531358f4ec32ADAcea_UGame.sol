// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IRandomizer.sol";
import "./interfaces/IUNFT.sol";
import "./interfaces/IUBlood.sol";
import "./interfaces/IURing.sol";
import "./interfaces/IUAmulet.sol";
import "./interfaces/IUGold.sol";
import "./interfaces/IUArena.sol";
import "./interfaces/IUGame.sol";

contract UGame is IUGame, Ownable, ReentrancyGuard, Pausable {

   constructor() {
    _pause();
  }

  /** CONTRACTS */
  IRandomizer public randomizer;
  IUArena public uArena;
  IUBlood public uBlood;
  IUNFT public uNFT;
  IURing public uRing;
  IUAmulet public uAmulet;
  IUGold public uGold;

  /** EVENTS */
  event ManyFYMinted(address indexed owner, uint16[] tokenIds);
  event FYStolen(address indexed originalOwner, address indexed newOwner, uint256 indexed tokenId);
  event FYLeveledUp(address indexed owner, uint256 indexed tokenId);
  event ManyRingsMinted(address indexed owner, uint256 indexed amount);
  event ManyAmuletsMinted(address indexed owner, uint256 indexed amount);
  event ManyGoldMinted(address indexed owner, uint256 indexed amount);

  /** PUBLIC VARS */
  bool public PRE_SALE_STARTED;
  uint16 public MAX_PRE_SALE_MINTS = 3;

  bool public PUBLIC_SALE_STARTED;
  uint16 public MAX_PUBLIC_SALE_MINTS = 5;

  uint256 public MINT_PRICE_GEN0 = 2.5 ether; // AVAX
  uint256 public MAX_GEN0_TOKENS = 12_000; // number of GEN0 tokens (payable with AVAX)

  uint256 public MINT_COST_REDUCE_INTERVAL = 1 hours; // Cost is reduced every 1 hour
  uint8 public MINT_COST_REDUCE_PERCENT = 1; // Cost decreaases periodically
  uint8 public MINT_COST_INCREASE_PERCENT = 2; // Cost increases after every mint batch

  uint256 public GEN1_BLOOD_MINT_COST = 13_500 ether;
  uint256 public GEN1_MIN_BLOOD_MINT_COST = 5_000 ether;
  uint256 public GEN1_LAST_MINT_TIME = block.timestamp;
  
  // Max amount of $BLOOD that can be in circulations at any point in time
  uint256 public MAXIMUM_BLOOD_SUPPLY = 2_500_000_000 ether; // TODO: I think minting blood should be done from this GAME contract and not from the ARENA!

  uint256 public DAILY_BLOOD_RATE = 500 ether;
  uint256 public DAILY_BLOOD_PER_LEVEL = 1_000 ether;
  
  uint256 public RING_DAILY_BLOOD_RATE = 100 ether;
  uint256 public RING_BLOOD_MINT_COST = 10_000 ether;
  uint256 public RING_MIN_BLOOD_MINT_COST = 5_000 ether;
  uint256 public RING_LAST_MINT_TIME = block.timestamp;

  uint256 public LEVEL_DOWN_AFTER_DAYS = 7 days;
  uint256 public AMULET_BLOOD_MINT_COST = 160_000 ether;
  uint256 public AMULET_LEVEL_DOWN_INCREASE_DAYS = 3 days;
  uint256 public AMULET_MIN_BLOOD_MINT_COST = 5_000 ether;
  uint256 public AMULET_LAST_MINT_TIME = block.timestamp;

  uint256 public GOLD_MAX_TOKENS = 1_000;
  uint256 public GOLD_BLOOD_MINT_COST = 1_000_000 ether;

  // The multi-sig wallet that will receive the funds on withdraw
  address public WITHDRAW_ADDRESS;

  /** PRIVATE VARS */
  mapping(address => bool) private _admins;
  mapping(address => bool) private _preSaleAddresses;
  mapping(address => uint8) private _preSaleMints;
  mapping(address => uint8) private _publicSaleMints;

  /** MODIFIERS */
  modifier onlyEOA() {
    require(tx.origin == _msgSender(), "Game: Only EOA");
    _;
  }

  modifier requireVariablesSet() {
    require(address(randomizer) != address(0), "Game: Randomizer contract not set");
    require(address(uBlood) != address(0), "Game: Blood contract not set");
    require(address(uNFT) != address(0), "Game: NFT contract not set");
    require(address(uArena) != address(0), "Game: Arena contract not set");
    require(address(uRing) != address(0), "Game: Ring contract not set");
    require(address(uAmulet) != address(0), "Game: Amulet contract not set");
    require(address(uGold) != address(0), "Game: Gold contract not set");
    require(WITHDRAW_ADDRESS != address(0), "Game: Withdrawal address must be set");
    _;
  }

  /** MINTING FUNCTIONS */
  /** 
  * Mint NFTs with AVAX.
  * 90% Fighters, 10% Yakuza.
  * Presale 2.7 AVAX. maxMint = 3 per Wallet. Also check staked NFTs.
  * Pubsale 3.0 AVAX. maxMint = 5 per Wallet. Also check staked NFTs.
  */
  function mintGen0(uint256 amount) external payable whenNotPaused nonReentrant onlyEOA {
    // Checks
    require(PRE_SALE_STARTED || PUBLIC_SALE_STARTED, "Game: GEN0 sale has not started yet");
    if (PRE_SALE_STARTED) {
      require(_preSaleAddresses[_msgSender()], "Game: You are not on the whitelist");
      require(_preSaleMints[_msgSender()] + amount <= MAX_PRE_SALE_MINTS, "Game: You cannot mint more GEN0 during pre-sale");
    } else {
      require(_publicSaleMints[_msgSender()] + amount <= MAX_PUBLIC_SALE_MINTS, "Game: You cannot mint more GEN0");
    }
    uint16 tokensMinted = uNFT.tokensMinted();
    uint256 maxTokens = uNFT.MAX_TOKENS();
    require(tokensMinted + amount <= maxTokens, "Game: All tokens minted");
    require(tokensMinted + amount <= MAX_GEN0_TOKENS, "Game: All GEN0 tokens minted");
    require(msg.value >= amount * MINT_PRICE_GEN0, "Game: Invalid payment amount");

    uint256 seed = 0;
    uint16[] memory tokenIds = new uint16[](amount);

    for (uint i = 0; i < amount; i++) {
      if (PRE_SALE_STARTED) {
        _preSaleMints[_msgSender()]++;
      } else {
        _publicSaleMints[_msgSender()]++;
      }
      tokensMinted++;

      seed = randomizer.randomSeed(tokensMinted);
      uNFT.mint(_msgSender(), seed, true);
      tokenIds[i] = tokensMinted;
    }
    uNFT.updateOriginAccess(tokenIds);

    emit ManyFYMinted(_msgSender(), tokenIds); // GEN0 minted
  }

  /**
  * Mint an NFT with $BLOOD.
  * 90% Fighter, 10% Yakuza.
  * GEN1 NFTs can be stolen by Yakuza.
  */
  function mintGen1(uint256 amount) external whenNotPaused nonReentrant onlyEOA {
    // Checks
    require(PUBLIC_SALE_STARTED, "Game: GEN1 sale has not started yet");
    uint16 tokensMinted = uNFT.tokensMinted();
    uint256 maxTokens = uNFT.MAX_TOKENS();
    require(tokensMinted + amount <= maxTokens, "Game: All tokens minted");
    require(amount > 0 && amount <= 10, "Game: Invalid mint amount (max 10)");

    // Effects
    uint256 totalBloodCost = getGen1MintCost() * amount;
    require(totalBloodCost > 0, "Game: GEN1 mint cost cannot be 0");

    // Burn $BLOOD for the mints first
    uBlood.burn(_msgSender(), totalBloodCost);
    uBlood.updateOriginAccess();
    

    // Interactions
    uint16[] memory tokenIds = new uint16[](amount);
    address recipient;
    uint256 seed;

    for (uint k = 0; k < amount; k++) {
      tokensMinted++;
      seed = randomizer.randomSeed(tokensMinted);
      recipient = _selectRecipient(seed);
      tokenIds[k] = tokensMinted;

      if (recipient != _msgSender()) { // Stolen
        uNFT.mint(recipient, seed, false);
        emit FYStolen(_msgSender(), recipient, tokensMinted);
      } else { // Not Stolen
        uNFT.mint(recipient, seed, false);
      }

      // Increase the price after mint
      GEN1_BLOOD_MINT_COST = getGen1MintCost() + (GEN1_BLOOD_MINT_COST * MINT_COST_INCREASE_PERCENT/100);
    }
    
    GEN1_LAST_MINT_TIME = block.timestamp;
    uNFT.updateOriginAccess(tokenIds); 
    emit ManyFYMinted(_msgSender(), tokenIds); // GEN1 minted
  }

  // TODO: Write tests
  function getGen1MintCost() public view returns (uint256 newCost) {
    uint256 intervalDiff = (block.timestamp - GEN1_LAST_MINT_TIME) / MINT_COST_REDUCE_INTERVAL;
    uint256 reduceBy = (GEN1_BLOOD_MINT_COST * MINT_COST_REDUCE_PERCENT / 100) * intervalDiff;
    
    if (GEN1_BLOOD_MINT_COST > reduceBy) {
      newCost = GEN1_BLOOD_MINT_COST - reduceBy;
    } else {
      newCost = 0;
    }

    if (newCost < GEN1_MIN_BLOOD_MINT_COST) newCost = GEN1_MIN_BLOOD_MINT_COST;

    return newCost;
  }

  function mintRing(uint256 amount) external whenNotPaused nonReentrant onlyEOA {
    uint256 totalCost = amount * getRingMintCost();

    // This will fail if not enough $BLOOD is available
    uBlood.burn(_msgSender(), totalCost);
    uRing.mint(_msgSender(), amount);

    // Increase the price after mint
    RING_BLOOD_MINT_COST = getRingMintCost() + (RING_BLOOD_MINT_COST * MINT_COST_INCREASE_PERCENT/100);
    RING_LAST_MINT_TIME = block.timestamp;

    emit ManyRingsMinted(_msgSender(), amount);
  }

  // TODO: Write tests
  function getRingMintCost() public view returns (uint256 newCost) {
    uint256 intervalDiff = (block.timestamp - RING_LAST_MINT_TIME) / MINT_COST_REDUCE_INTERVAL;
    uint256 reduceBy = (RING_BLOOD_MINT_COST * MINT_COST_REDUCE_PERCENT / 100) * intervalDiff;
    
    if (RING_BLOOD_MINT_COST > reduceBy) {
      newCost = RING_BLOOD_MINT_COST - reduceBy;
    } else {
      newCost = 0;
    }

    if (newCost < RING_MIN_BLOOD_MINT_COST) newCost = RING_MIN_BLOOD_MINT_COST;

    return newCost;
  }

  function mintAmulet(uint256 amount) external whenNotPaused nonReentrant onlyEOA {
    uint256 totalCost = amount * getAmuletMintCost();

    // This will fail if not enough $BLOOD is available
    uBlood.burn(_msgSender(), totalCost);
    uAmulet.mint(_msgSender(), amount);

    // Increase the price after mint
    AMULET_BLOOD_MINT_COST = getAmuletMintCost() + (AMULET_BLOOD_MINT_COST * MINT_COST_INCREASE_PERCENT/100);

    AMULET_LAST_MINT_TIME = block.timestamp;

    emit ManyAmuletsMinted(_msgSender(), amount);
  }

  // TODO: Write tests
  function getAmuletMintCost() public view returns (uint256 newCost) {
    uint256 intervalDiff = (block.timestamp - AMULET_LAST_MINT_TIME) / MINT_COST_REDUCE_INTERVAL;
    uint256 reduceBy = (AMULET_BLOOD_MINT_COST * MINT_COST_REDUCE_PERCENT / 100) * intervalDiff;
    
    if (AMULET_BLOOD_MINT_COST > reduceBy) {
      newCost = AMULET_BLOOD_MINT_COST - reduceBy;
    } else {
      newCost = 0;
    }

    if (newCost < AMULET_MIN_BLOOD_MINT_COST) newCost = AMULET_MIN_BLOOD_MINT_COST;

    return newCost;
  }

  function mintGold(uint256 amount) external whenNotPaused nonReentrant onlyEOA {
    uint256 tokensMinted = uGold.tokensMinted();
    require(tokensMinted + amount <= GOLD_MAX_TOKENS, "Game: All Gold has been minted");

    uint256 totalCost = amount * GOLD_BLOOD_MINT_COST;

    // This will fail if not enough $BLOOD is available
    uBlood.burn(_msgSender(), totalCost);
    uGold.mint(_msgSender(), amount);
    emit ManyGoldMinted(_msgSender(), amount);
  }

  // TODO: Test it. Can this be exploited? Did my token get stolen?
  function getOwnerOfFYToken(uint256 tokenId) public view returns(address ownerOf) {
    if (uArena.isStaked(tokenId)) {
      IUArena.Stake memory stake = uArena.getStake(tokenId);
      ownerOf = stake.owner;
    } else {
      ownerOf = uNFT.ownerOf(tokenId);
    }
    
    require(ownerOf != address(0), "Game: The owner cannot be address(0)");

    return ownerOf;
  }

  // TODO: Rename this to getFyTokenTraits()
  // onlyEOA will not work here, as the Arena is calling this function
  function getTokenTraits(uint256 tokenId) external view returns (IUNFT.FighterYakuza memory) { 
    return _getTokenTraits(tokenId);
  }

  // TODO: Rename this to _getFyTokenTraits()
  /**
  * Return the actual level of the NFT (might have lost levels along the way)!
  * onlyEOA will not work here, as the Arena is calling this function
  */
  function _getTokenTraits(uint256 tokenId) private view returns (IUNFT.FighterYakuza memory) {
    // Get current on-chain traits from the NFT contract
    IUNFT.FighterYakuza memory traits = uNFT.getTokenTraits(tokenId);
    address ownerOfToken = getOwnerOfFYToken(tokenId); // We need to get the actual owner of this token NOT use the _msgSender() here

    // If level is already 0, then return immediately 
    if (traits.level == 0) return traits;

    // Lose 1 level every X days in which you didn't upgrade your NFT level
    uint256 amuletsInWallet = getBalanceOfActiveAmulets(ownerOfToken);
    // Amulets increase your level down days, thus your level goes down slower
    uint256 LEVEL_DOWN_AFTER_DAYS_NEW = (amuletsInWallet * AMULET_LEVEL_DOWN_INCREASE_DAYS) + LEVEL_DOWN_AFTER_DAYS;
    uint16 reduceLevelBy = uint16((block.timestamp - traits.lastLevelUpgradeTime) / LEVEL_DOWN_AFTER_DAYS_NEW);

    if (reduceLevelBy > traits.level) {
      traits.level = 0;
    } else {
      traits.level = traits.level - reduceLevelBy;
    }

    return traits; 
  }

  // TODO: Test it
  /**
  * Get the number of Amulets that are "active", meaning they have an effect on the game
  */
  function getBalanceOfActiveAmulets(address owner) public view returns(uint256) {
    uint256 tokenCount = uAmulet.balanceOf(owner);
    uint256 activeTokens = 0;

    for (uint256 i; i < tokenCount; i++) {
      uint256 tokenId = uAmulet.tokenOfOwnerByIndex(owner, i);
      IUAmulet.Amulet memory traits = uAmulet.getTokenTraits(tokenId);
      if (block.timestamp >= traits.lastTransferTimestamp + 1 days) {
        activeTokens++;
      }
    }

    return activeTokens;
  }

  /**
   * 10% chance to be given to a random staked Yakuza
   * @param seed a random value to select a recipient from
   * @return the address of the recipient (either the minter or the Yakuza thief's owner)
   */
  function _selectRecipient(uint256 seed) private view returns (address) {
    if (((seed >> 245) % 10) != 0) return _msgSender();
    address thief = uArena.randomYakuzaOwner(seed >> 144);
    if (thief == address(0x0)) return _msgSender();
    return thief;
  }


  /** STAKING */
  // TODO: Test this
  function calculateAllStakingRewards(uint256[] memory tokenIds) external view returns (uint256 owed) {
    for (uint256 i; i < tokenIds.length; i++) {
      owed += _calculateStakingRewards(tokenIds[i]);
    }
    return owed;
  }

  // TODO: Test this
  function calculateStakingRewards(uint256 tokenId) external view returns (uint256 owed) {
    return _calculateStakingRewards(tokenId);
  }

  // TODO: Test this very well!!!
  // onlyEOA will not work here, as the Arena is calling this function
  function _calculateStakingRewards(uint256 tokenId) private view returns (uint256 owed) {
    // Must check these, as getTokenTraits will be allowed since this contract is an admin
    uint64 lastTokenWrite = uNFT.getTokenWriteBlock(tokenId);
    require(lastTokenWrite < block.number, "Game: Nope!");
    uint256 tokenMintBlock = uNFT.getTokenMintBlock(tokenId);
    require(tokenMintBlock < block.number, "Game: Nope!");
    require(uArena.isStaked(tokenId), "Game: Token is not staked");
    
    IUArena.Stake memory myStake;
    IUNFT.FighterYakuza memory traits = _getTokenTraits(tokenId);
    address ownerOfToken = getOwnerOfFYToken(tokenId);

    if (traits.isFighter) { // Fighter
      myStake = uArena.getStake(tokenId);
      owed += (block.timestamp - myStake.stakeTimestamp) * DAILY_BLOOD_RATE / 1 days;

      uint256 ringsInWallet = getBalanceOfActiveRings(ownerOfToken);
      owed += (block.timestamp - myStake.stakeTimestamp) * (traits.level * (DAILY_BLOOD_PER_LEVEL + ringsInWallet * RING_DAILY_BLOOD_RATE)) / 1 days;
    } else { // Yakuza
      uint8 rank = traits.rank;
      uint256 bloodPerRank = uArena.getBloodPerRank();
      myStake = myStake = uArena.getStake(tokenId);
      owed = (rank) * (bloodPerRank - myStake.bloodPerRank); // Calculate portion of tokens based on rank TODO: can this become negative when all but 1 Yakuza are unstaked???
    }

    return owed;
  }

  // TODO: Test it
  /**
  * Get the number of Rings that are "active", meaning they have an effect on the game
  */
  function getBalanceOfActiveRings(address owner) public view returns(uint256) {
    uint256 tokenCount = uRing.balanceOf(owner);
    uint256 activeTokens = 0;

    for (uint256 i; i < tokenCount; i++) {
      uint256 tokenId = uRing.tokenOfOwnerByIndex(owner, i);
      IURing.Ring memory traits = uRing.getTokenTraits(tokenId);
      if (block.timestamp >= traits.lastTransferTimestamp + 1 days) {
        activeTokens++;
      }
    }

    return activeTokens;
  }

  /** LEVELING UP NFT */
  /**
   * Burn $BLOOD to level up your NFT.
   */
  function levelUpNft(uint256 tokenId, uint16 levelsToUpgrade) external whenNotPaused nonReentrant onlyEOA {
    // Checks
    require(uNFT.isFighter(tokenId), "Game: Only fighters can be leveled up");
    // Token can also belong to the ARENA e.g. when it is staked
    address tokenOwner = getOwnerOfFYToken(tokenId);
    require(tokenOwner == _msgSender(), "Game: You don't own this token");
    
    // Effects
    IUNFT.FighterYakuza memory traits = _getTokenTraits(tokenId);
    uint256 totalBloodCost = getLevelUpBloodCost(traits.level, levelsToUpgrade);
    uBlood.burn(_msgSender(), totalBloodCost);
    uBlood.updateOriginAccess();

    // Interactions
    uint16[] memory tokenIds = new uint16[](1);
    tokenIds[0] = uint16(tokenId);

    // Claim $BLOOD before level up to prevent issues where higher levels would improve the whole staking period instead of just future periods
    // This also resets the stake meaning the player needs to wait 2 days to unstake after leveling up
    if (uArena.isStaked(tokenId)) {
      uArena.claimManyFromArena(tokenIds, false);
    }

    // Level up
    uint16 newLevel = traits.level + levelsToUpgrade;
    uNFT.setTraitLevel(tokenId, newLevel);
    uNFT.updateOriginAccess(tokenIds); // This leads to waiting for the NEXT BLOCK to mined BEFORE being able to see the effect of your level up

    emit FYLeveledUp(_msgSender(), tokenId);
  }

  // TODO: Test
  function getLevelUpBloodCost(uint16 currentLevel, uint16 levelsToUpgrade) public view onlyEOA returns (uint256 totalBloodCost) {
    require(currentLevel >= 0, "Game: Invalid currentLevel provided.");
    require(levelsToUpgrade >= 1, "Game: Invalid levelsToUpgrade provided.");

    totalBloodCost = 0;

    for (uint16 i = 1; i <= levelsToUpgrade; i++) {
      totalBloodCost += _getBloodCostPerLevel(currentLevel + i);
    }
    require(totalBloodCost > 0, "Game: Error calculating level up $BLOOD cost.");

    return totalBloodCost;
  }

  /**
  * There is no formula that can generate the below numbers that we need - so there we go, one by one :-p
  */
  function _getBloodCostPerLevel(uint16 level) private pure returns (uint256 price) {
    if (level == 0) return 0 ether;
    if (level == 1) return 500 ether;
    if (level == 2) return 1000 ether;
    if (level == 3) return 2250 ether;
    if (level == 4) return 4125 ether;
    if (level == 5) return 6300 ether;
    if (level == 6) return 8505 ether;
    if (level == 7) return 10206 ether;
    if (level == 8) return 11510 ether;
    if (level == 9) return 13319 ether;
    if (level == 10) return 14429 ether;
    if (level == 11) return 18036 ether;
    if (level == 12) return 22545 ether;
    if (level == 13) return 28181 ether;
    if (level == 14) return 35226 ether;
    if (level == 15) return 44033 ether;
    if (level == 16) return 55042 ether;
    if (level == 17) return 68801 ether;
    if (level == 18) return 86002 ether;
    if (level == 19) return 107503 ether;
    if (level == 20) return 134378 ether;
    if (level == 21) return 167973 ether;
    if (level == 22) return 209966 ether;
    if (level == 23) return 262457 ether;
    if (level == 24) return 328072 ether;
    if (level == 25) return 410090 ether;
    if (level == 26) return 512612 ether;
    if (level == 27) return 640765 ether;
    if (level == 28) return 698434 ether;
    if (level == 29) return 761293 ether;
    if (level == 30) return 829810 ether;
    if (level == 31) return 904492 ether;
    if (level == 32) return 985897 ether;
    if (level == 33) return 1074627 ether;
    if (level == 34) return 1171344 ether;
    if (level == 35) return 1276765 ether;
    if (level == 36) return 1391674 ether;
    if (level == 37) return 1516924 ether;
    if (level == 38) return 1653448 ether;
    if (level == 39) return 1802257 ether;
    if (level == 40) return 1964461 ether;
    if (level == 41) return 2141263 ether;
    if (level == 42) return 2333976 ether;
    if (level == 43) return 2544034 ether;
    if (level == 44) return 2772997 ether;
    if (level == 45) return 3022566 ether;
    if (level == 46) return 3294598 ether;
    if (level == 47) return 3591112 ether;
    if (level == 48) return 3914311 ether;
    if (level == 49) return 4266600 ether;
    if (level == 50) return 4650593 ether;
    if (level == 51) return 5069147 ether;
    if (level == 52) return 5525370 ether;
    if (level == 53) return 6022654 ether;
    if (level == 54) return 6564692 ether;
    if (level == 55) return 7155515 ether;
    if (level == 56) return 7799511 ether;
    if (level == 57) return 8501467 ether;
    if (level == 58) return 9266598 ether;
    if (level == 59) return 10100593 ether;
    if (level == 60) return 11009646 ether;
    if (level == 61) return 12000515 ether;
    if (level == 62) return 13080560 ether;
    if (level == 63) return 14257811 ether;
    if (level == 64) return 15541015 ether;
    if (level == 65) return 16939705 ether;
    if (level == 66) return 18464279 ether;
    if (level == 67) return 20126064 ether;
    if (level == 68) return 21937409 ether;
    if (level == 69) return 23911777 ether;
    if (level == 70) return 26063836 ether;
    if (level == 71) return 28409582 ether;
    if (level == 72) return 30966444 ether;
    if (level == 73) return 33753424 ether;
    if (level == 74) return 36791232 ether;
    if (level == 75) return 40102443 ether;
    if (level == 76) return 43711663 ether;
    if (level == 77) return 47645713 ether;
    if (level == 78) return 51933826 ether;
    if (level == 79) return 56607872 ether;
    if (level == 80) return 61702579 ether;
    if (level == 81) return 67255812 ether;
    if (level == 82) return 73308835 ether;
    if (level == 83) return 79906630 ether;
    if (level == 84) return 87098226 ether;
    if (level == 85) return 94937067 ether;
    if (level == 86) return 103481403 ether;
    if (level == 87) return 112794729 ether;
    if (level == 88) return 122946255 ether;
    if (level == 89) return 134011418 ether;
    if (level == 90) return 146072446 ether;
    if (level == 91) return 159218965 ether;
    if (level == 92) return 173548673 ether;
    if (level == 93) return 189168053 ether;
    if (level == 94) return 206193177 ether;
    if (level == 95) return 224750564 ether;
    if (level == 96) return 244978115 ether;
    if (level == 97) return 267026144 ether;
    if (level == 98) return 291058498 ether;
    if (level == 99) return 329514746 ether;
    if (level == 100) return 350000000 ether;
    require(false, "Game: This level is not supported yet");
    return price;
  }

  /** OWNER ONLY FUNCTIONS */
  function setContracts(address _rand, address _uBlood, address _uNFT, address _uArena, address _uRing, address _uAmulet, address _uGold) external onlyOwner {
    randomizer = IRandomizer(_rand);
    uBlood = IUBlood(_uBlood);
    uNFT = IUNFT(_uNFT);
    uArena = IUArena(_uArena);
    uRing = IURing(_uRing);
    uAmulet = IUAmulet(_uAmulet);
    uGold = IUGold(_uGold);
  }
 
  function setPaused(bool paused) external requireVariablesSet onlyOwner {
    if (paused) _pause();
    else _unpause();
  }

  function setMaxGen0Tokens(uint256 number) external onlyOwner {
    MAX_GEN0_TOKENS = number;
  }
  
  function setMintPriceGen0(uint256 number) external onlyOwner {
    MINT_PRICE_GEN0 = number;
  }

  function setMaximumBloodSupply(uint256 number) external onlyOwner {
    MAXIMUM_BLOOD_SUPPLY = number;
  }

  function setDailyBloodRate(uint256 number) external onlyOwner {
    DAILY_BLOOD_RATE = number;
  }

  function setDailyBloodPerLevel(uint256 number) external onlyOwner {
    DAILY_BLOOD_PER_LEVEL = number;
  }

  function setLevelDownAfterDays(uint256 number) external onlyOwner {
    LEVEL_DOWN_AFTER_DAYS = number;
  }

  function setRingBloodMintCost(uint256 number) external onlyOwner {
    RING_BLOOD_MINT_COST = number;
  }

  function setRingDailyBloodRate(uint256 number) external onlyOwner {
    RING_DAILY_BLOOD_RATE = number;
  }

  function setRingMinBloodMintCost(uint256 number) external onlyOwner {
    RING_MIN_BLOOD_MINT_COST = number;
  }

  function setAmuletBloodMintCost(uint256 number) external onlyOwner {
    AMULET_BLOOD_MINT_COST = number;
  }

  function setAmuletLevelDownIncreaseDays(uint256 number) external onlyOwner {
    AMULET_LEVEL_DOWN_INCREASE_DAYS = number;
  }

  function setAmuletMinBloodMintCost(uint256 number) external onlyOwner {
    AMULET_MIN_BLOOD_MINT_COST = number;
  }

  function setGoldMaxTokens(uint256 number) external onlyOwner {
    GOLD_MAX_TOKENS = number;
  }

  function setGoldBloodMintCost(uint256 number) external onlyOwner {
    GOLD_BLOOD_MINT_COST = number;
  }

  function setPreSaleStarted(bool started) external onlyOwner {
    PRE_SALE_STARTED = started;
  }

  function setMaxPreSaleMints(uint16 number) external onlyOwner {
    MAX_PRE_SALE_MINTS = number;
  }

  function setPublicSaleStarted(bool started) external onlyOwner {
    PUBLIC_SALE_STARTED = started;
  }

  function setMaxPublicSaleMints(uint16 number) external onlyOwner {
    MAX_PUBLIC_SALE_MINTS = number;
  }

  function setGen1BloodMintCost(uint256 number) external onlyOwner {
    GEN1_BLOOD_MINT_COST = number;
  }

  function setGen1MinBloodMintCost(uint256 number) external onlyOwner {
    GEN1_MIN_BLOOD_MINT_COST = number;
  }

  function setMintCostReduceInterval(uint256 number) external onlyOwner {
    MINT_COST_REDUCE_INTERVAL = number;
  }

  function setMintCostReducePercent(uint8 number) external onlyOwner {
    MINT_COST_REDUCE_PERCENT = number;
  }

  function setMintCostIncreasePercent(uint8 number) external onlyOwner {
    MINT_COST_INCREASE_PERCENT = number;
  }

  function addToPresale(address[] memory addresses) external onlyOwner {
    for (uint i = 0; i < addresses.length; i++) {
      address addr = addresses[i];
      _preSaleAddresses[addr] = true;
    }
  }

  function removeFromPresale(address[] memory addresses) external onlyOwner {
     for (uint i = 0; i < addresses.length; i++) {
      address addr = addresses[i];
      delete _preSaleAddresses[addr];
    }
  }

  function addAdmin(address addr) external onlyOwner {
    _admins[addr] = true;
  }

  function removeAdmin(address addr) external onlyOwner {
    delete _admins[addr];
  }

  // TODO: WRITE TESTS
  // Address can only be set once
  function setWithdrawAddress(address addr) external onlyOwner {
    require(WITHDRAW_ADDRESS == address(0), "Game: You cannot change the withdraw address anymore");
    require(addr != address(0), "Game: Cannot be set to the zero address");

    WITHDRAW_ADDRESS = addr;
  }

  function withdraw() external onlyOwner {
    payable(WITHDRAW_ADDRESS).transfer(address(this).balance);
  }
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IURing is IERC721Enumerable {

    struct Ring {
        uint256 mintedTimestamp;
        uint256 mintedBlockNumber;
        uint256 lastTransferTimestamp;
    }
    
    function tokensMinted() external returns (uint256);

    function mint(address recipient, uint256 amount) external; // onlyAdmin
    function burn(uint256 tokenId) external; // onlyAdmin
    function getTokenTraits(uint256 tokenId) external view returns (Ring memory); // onlyAdmin
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IUNFT is IERC721Enumerable {

    struct FighterYakuza {
        bool isFighter;
        bool isGen0;
        uint8 courage;
        uint8 cunning;
        uint8 brutality;
        uint8 rank;
        uint256 lastRankUpgradeTime;
        uint16 level;
        uint256 lastLevelUpgradeTime;
        uint256 lastUpgradeTime;
        uint64 mintedBlockNumber;
    }

    function MAX_TOKENS() external returns (uint256);
    function tokensMinted() external returns (uint16);

    function isFighter(uint256 tokenId) external view returns(bool);

    function updateOriginAccess(uint16[] memory tokenIds) external; // onlyAdmin
    function mint(address recipient, uint256 seed, bool isGen0) external; // onlyAdmin
    function burn(uint256 tokenId) external; // onlyAdmin
    function setTraitLevel(uint256 tokenId, uint16 level) external; // onlyAdmin
    function setTraitRank(uint256 tokenId, uint8 rank) external; // onlyAdmin
    function setTraitCourage(uint256 tokenId, uint8 courage) external; // onlyAdmin
    function setTraitCunning(uint256 tokenId, uint8 cunning) external; // onlyAdmin
    function setTraitBrutality(uint256 tokenId, uint8 brutality) external; // onlyAdmin
    function getTokenTraits(uint256 tokenId) external view returns (FighterYakuza memory); // onlyAdmin
    function getYakuzaRanks() external view returns(uint8[4] memory); // onlyAdmin
    function getAddressWriteBlock() external view returns(uint64); // onlyAdmin
    function getTokenWriteBlock(uint256 tokenId) external view returns(uint64); // onlyAdmin
    function getTokenMintBlock(uint256 tokenId) external view returns(uint64); // onlyAdmin
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IUGold is IERC721Enumerable {

    struct Gold {
        uint256 mintedTimestamp;
        uint256 mintedBlockNumber;
        uint256 lastTransferTimestamp;
    }

    function tokensMinted() external returns (uint256);
    
    function mint(address recipient, uint256 amount) external; // onlyAdmin
    function burn(uint256 tokenId) external; // onlyAdmin
    function getTokenTraits(uint256 tokenId) external view returns (Gold memory); // onlyAdmin
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "./IUNFT.sol";

interface IUGame {
    function MAXIMUM_BLOOD_SUPPLY() external returns (uint256);

    function getTokenTraits(uint256 tokenId) external view returns (IUNFT.FighterYakuza memory);
    function calculateStakingRewards(uint256 tokenId) external view returns (uint256 owed);
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

interface IUBlood {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function updateOriginAccess() external;
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function totalSupply() external view returns (uint256);
}

// SPDX-License-Identifier: MIT LICENSE 

pragma solidity 0.8.11;

interface IUArena {

  struct Stake {
    uint16 tokenId;
    uint256 bloodPerRank;
    uint256 stakeTimestamp;
    address owner;
  }
  
  function stakeManyToArena(uint16[] calldata tokenIds) external;
  function claimManyFromArena(uint16[] calldata tokenIds, bool unstake) external;
  function randomYakuzaOwner(uint256 seed) external view returns (address);
  function getStakedTokenIds(address owner) external view returns (uint256[] memory);
  function getStake(uint256 tokenId) external view returns (Stake memory);
  function isStaked(uint256 tokenId) external view returns (bool);
  function getBloodPerRank() external view returns(uint256);
}

// SPDX-License-Identifier: MIT LICENSE

pragma solidity 0.8.11;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

interface IUAmulet is IERC721Enumerable {

    struct Amulet {
        uint256 mintedTimestamp;
        uint256 mintedBlockNumber;
        uint256 lastTransferTimestamp;
    }

    function tokensMinted() external returns (uint256);
    
    function mint(address recipient, uint256 amount) external; // onlyAdmin
    function burn(uint256 tokenId) external; // onlyAdmin
    function getTokenTraits(uint256 tokenId) external view returns (Amulet memory); // onlyAdmin
}

// SPDX-License-Identifier: MIT LICENSE 

pragma solidity 0.8.11;

interface IRandomizer {
    function random(uint256 tokenId) external returns (uint8);
    function randomSeed(uint256 tokenId) view external returns (uint256);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (utils/introspection/IERC165.sol)

pragma solidity ^0.8.0;

/**
 * @dev Interface of the ERC165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[EIP].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[EIP section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (utils/Context.sol)

pragma solidity ^0.8.0;

/**
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.5.0) (token/ERC721/extensions/IERC721Enumerable.sol)

pragma solidity ^0.8.0;

import "../IERC721.sol";

/**
 * @title ERC-721 Non-Fungible Token Standard, optional enumeration extension
 * @dev See https://eips.ethereum.org/EIPS/eip-721
 */
interface IERC721Enumerable is IERC721 {
    /**
     * @dev Returns the total amount of tokens stored by the contract.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns a token ID owned by `owner` at a given `index` of its token list.
     * Use along with {balanceOf} to enumerate all of ``owner``'s tokens.
     */
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);

    /**
     * @dev Returns a token ID at a given `index` of all the tokens stored by the contract.
     * Use along with {totalSupply} to enumerate all tokens.
     */
    function tokenByIndex(uint256 index) external view returns (uint256);
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (token/ERC721/IERC721.sol)

pragma solidity ^0.8.0;

import "../../utils/introspection/IERC165.sol";

/**
 * @dev Required interface of an ERC721 compliant contract.
 */
interface IERC721 is IERC165 {
    /**
     * @dev Emitted when `tokenId` token is transferred from `from` to `to`.
     */
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables `approved` to manage the `tokenId` token.
     */
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);

    /**
     * @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its assets.
     */
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /**
     * @dev Returns the number of tokens in ``owner``'s account.
     */
    function balanceOf(address owner) external view returns (uint256 balance);

    /**
     * @dev Returns the owner of the `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`, checking first that contract recipients
     * are aware of the ERC721 protocol to prevent tokens from being forever locked.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be have been allowed to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Transfers `tokenId` token from `from` to `to`.
     *
     * WARNING: Usage of this method is discouraged, use {safeTransferFrom} whenever possible.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;

    /**
     * @dev Gives permission to `to` to transfer `tokenId` token to another account.
     * The approval is cleared when the token is transferred.
     *
     * Only a single account can be approved at a time, so approving the zero address clears previous approvals.
     *
     * Requirements:
     *
     * - The caller must own the token or be an approved operator.
     * - `tokenId` must exist.
     *
     * Emits an {Approval} event.
     */
    function approve(address to, uint256 tokenId) external;

    /**
     * @dev Returns the account approved for `tokenId` token.
     *
     * Requirements:
     *
     * - `tokenId` must exist.
     */
    function getApproved(uint256 tokenId) external view returns (address operator);

    /**
     * @dev Approve or remove `operator` as an operator for the caller.
     * Operators can call {transferFrom} or {safeTransferFrom} for any token owned by the caller.
     *
     * Requirements:
     *
     * - The `operator` cannot be the caller.
     *
     * Emits an {ApprovalForAll} event.
     */
    function setApprovalForAll(address operator, bool _approved) external;

    /**
     * @dev Returns if the `operator` is allowed to manage all of the assets of `owner`.
     *
     * See {setApprovalForAll}
     */
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /**
     * @dev Safely transfers `tokenId` token from `from` to `to`.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `to` cannot be the zero address.
     * - `tokenId` token must exist and be owned by `from`.
     * - If the caller is not `from`, it must be approved to move this token by either {approve} or {setApprovalForAll}.
     * - If `to` refers to a smart contract, it must implement {IERC721Receiver-onERC721Received}, which is called upon a safe transfer.
     *
     * Emits a {Transfer} event.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes calldata data
    ) external;
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (security/ReentrancyGuard.sol)

pragma solidity ^0.8.0;

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `nonReentrant` guard, functions marked as
 * `nonReentrant` may not call one another. This can be worked around by making
 * those functions `private`, and then adding `external` `nonReentrant` entry
 * points to them.
 *
 * TIP: If you would like to learn more about reentrancy and alternative ways
 * to protect against it, check out our blog post
 * https://blog.openzeppelin.com/reentrancy-after-istanbul/[Reentrancy After Istanbul].
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values being non-zero value makes deployment a bit more expensive,
    // but in exchange the refund on every call to nonReentrant will be lower in
    // amount. Since refunds are capped to a percentage of the total
    // transaction's gas, it is best to keep them low in cases like this one, to
    // increase the likelihood of the full refund coming into effect.
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and making it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        // On the first call to nonReentrant, _notEntered will be true
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");

        // Any calls to nonReentrant after this point will fail
        _status = _ENTERED;

        _;

        // By storing the original value once again, a refund is triggered (see
        // https://eips.ethereum.org/EIPS/eip-2200)
        _status = _NOT_ENTERED;
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (security/Pausable.sol)

pragma solidity ^0.8.0;

import "../utils/Context.sol";

/**
 * @dev Contract module which allows children to implement an emergency stop
 * mechanism that can be triggered by an authorized account.
 *
 * This module is used through inheritance. It will make available the
 * modifiers `whenNotPaused` and `whenPaused`, which can be applied to
 * the functions of your contract. Note that they will not be pausable by
 * simply including this module, only once the modifiers are put in place.
 */
abstract contract Pausable is Context {
    /**
     * @dev Emitted when the pause is triggered by `account`.
     */
    event Paused(address account);

    /**
     * @dev Emitted when the pause is lifted by `account`.
     */
    event Unpaused(address account);

    bool private _paused;

    /**
     * @dev Initializes the contract in unpaused state.
     */
    constructor() {
        _paused = false;
    }

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() public view virtual returns (bool) {
        return _paused;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is not paused.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    /**
     * @dev Modifier to make a function callable only when the contract is paused.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    /**
     * @dev Triggers stopped state.
     *
     * Requirements:
     *
     * - The contract must not be paused.
     */
    function _pause() internal virtual whenNotPaused {
        _paused = true;
        emit Paused(_msgSender());
    }

    /**
     * @dev Returns to normal state.
     *
     * Requirements:
     *
     * - The contract must be paused.
     */
    function _unpause() internal virtual whenPaused {
        _paused = false;
        emit Unpaused(_msgSender());
    }
}

// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts v4.4.1 (access/Ownable.sol)

pragma solidity ^0.8.0;

import "../utils/Context.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
abstract contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor() {
        _transferOwnership(_msgSender());
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}