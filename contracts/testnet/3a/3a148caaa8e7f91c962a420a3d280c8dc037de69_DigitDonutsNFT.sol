// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ERC721.sol";
import "./Counters.sol";
import "./Ownable.sol";
import "./Pauseable.sol";
import "./ERC721URIStorage.sol";
import "./ERC721Enumerable.sol";
import "./ERC2981PerTokenRoyalties.sol";


contract DigitDonutsNFT is  ERC721Enumerable,ERC721URIStorage, Ownable, ERC2981PerTokenRoyalties  {

//start of variables
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIds;

    uint256 public TOTAL_NFT;
    uint256 public nodeExpirySecs;
    uint256 public nodeFees;

    string private metadataURL;
    string private baseURL;
    //owner is receiving address for baking fees and royalties
    //address private receivingAddress;
    uint256 private contractRoyalties = 1000; //10%

    bool private stakingActive = false;
    // number of tokens have been minted so far
    uint16 public minted;
    
    //keeping track of Donuts expiry
    mapping(uint256 => uint256) public expiryTimeOf;
    
    constructor() ERC721("DigitDonuts", "DiDo") {
            TOTAL_NFT = 10000;
            baseURL = "http://digitdonuts.shop/metadata";
            /*
            1) Token royalties receiving address defaults to owner of this contract.
            2) BakingFees and expiry is not set. when minted, adds 60 days
            */
            
    }
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Enumerable, ERC721, ERC2981PerTokenRoyalties)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
       function _beforeTokenTransfer(address from,address to,uint256 tokenId) 
       internal override(ERC721, ERC721Enumerable) {
       super._beforeTokenTransfer(from, to, tokenId);
        }

        function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
        }

        function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
        {
        return super.tokenURI(tokenId);
        }

    function setTotalNft(uint256 newTotal)  public onlyOwner
    {
            TOTAL_NFT = newTotal;

    }

    function setBaseURI(string memory _baseURI) external onlyOwner { 
        baseURL = _baseURI;
        for (uint256 id = 0; id < minted; id++) { 
        // issue: takes long time to update for more than 50 NFTs
        _setTokenURI(id, string(abi.encodePacked(baseURL, "/", Strings.toString(id), ".json")));
        }   
    }


    function mint(bool stake, uint16 amount)
        public onlyOwner 
       // returns (uint256)
    {
        require(!stake || stakingActive, "Staking not activated");
        require(minted + amount <= TOTAL_NFT, "All tokens minted");
        require(amount > 0 && amount <= 10000, "Invalid mint amount"); //max mint 10000 at one go
        
        //uint16[] memory tokenIds = new uint16[](amount);
        //address[] memory owners = new address[](amount);


         for (uint i = 0; i < amount; i++) {
            uint256 newItemId = _tokenIds.current();
            _mint(_msgSender(), newItemId);
            _setTokenURI(newItemId, string(abi.encodePacked(baseURL, "/", Strings.toString(newItemId), ".json")));
            _setTokenRoyalty(newItemId, owner(), contractRoyalties);
            expiryTimeOf[i] = block.timestamp + 5184000;
            _tokenIds.increment();
            minted++;
         }
       

       // return newItemId;
    }
    //have to append tokenid
    function burn(uint256 tokenId)  
     public onlyOwner
    {
        _burn(tokenId);
        minted--;
    }
    function setBakingFeesData(uint256 expirySecs, uint256 _nodeFees)  
     public onlyOwner
    {
        nodeExpirySecs = expirySecs;
        nodeFees = _nodeFees;
    }

    function setStakingActive(bool _staking) public onlyOwner {
        stakingActive = _staking;
    }

    function getDonutExpiry(uint256 nftId)
    public view returns (uint256)
    {
        return expiryTimeOf[nftId];
    }
    function payBakingFees(uint256 nftId) public  payable 
    {
        require(nodeFees <= address(this).balance,"Cannot afford");
        //TODO: send payment to receiver address
       (bool success,) = owner().call{value: nodeFees}("");
       expiryTimeOf[nftId] += nodeExpirySecs; //(set duration in secs)
        require(success, "Failed to send money");
    }

}