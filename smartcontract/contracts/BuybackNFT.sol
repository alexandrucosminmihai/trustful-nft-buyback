// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/finance/PaymentSplitter.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";


import "./ERC721Tradable.sol";

contract BuybackNFT is ERC721Tradable, PaymentSplitter {
    // !!! Token IDs are indexed starting from 1 !!!
    using Counters for Counters.Counter;

    string private currentBaseURI;

    // Minting related.
    uint256 private mintPriceWei = 0.035 ether;  // The price gets stored as an uint256 representing the price in WEI.
    uint256 private whitelistMintPriceWei = 0.025 ether;

    uint32 private maxSupplyPublic = 9_900;
    uint32 private maxSupplyTeam = 100;

    Counters.Counter private counterMintedPublic;  // Starts at 1.
    Counters.Counter private counterMintedTeam;  // Starts at 1.

    bool private mintingAllowed = false;
    bool private whitelistMintingAllowed = false;

    bytes32 private whitelistRootHash;
    
    mapping(address => uint256) public mintedBalance;  // How many NFTs each address has minted (different from how many it owns).
    uint256 private walletWhitelistMintLimit = 5;
    uint256 private walletMintLimit = 10;

    // TODO: Replace these with the real addresses.
    // These are addresses from the Rinkeby test net.
    address constant communityAddress = 0xddFC8347A32107eE5CE4825C5a2c4753Bcd580eb;
    address constant artistAddress = 0x9972C48FBdeB6044A4075e19345F734AcC03f84D;
    address constant devAddress = 0xb3ED329E26B3867b7161c5614EB6385e471A80e1;
    address constant marketingAddress = 0xcb41c104eFFF7962DB8CEB42Da0f0E84b80C11e1;
    // address constant openseaProxyRegistryAddress = 0xF57B2c51dED3A29e6891aba85459d600256Cf317;  // TODO: Replace this with the Mainnet address in the contract deployment migration!!!.
    // for MainNet: address constant openseaProxyRegistryAddress = 0xa5409ec958C83C3f309868babACA7c86DCB077c1;

    modifier onlyTeam {
        require(
            msg.sender == devAddress || msg.sender == artistAddress || msg.sender == marketingAddress,
            "Only the team members can call this function."
        );
        _;
    }


    // ===== Constructor and OpenSea's interfaces related (baseTokenURI and _msgSender) =====
    /*
        payees = ["0x5B38Da6a701c568545dCfcB03FcB875f56beddC4", "0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2"]
        shares = [60, 40]
    */
    constructor(
            address[] memory _payees, uint256[] memory _shares, address _proxyRegistryAddress,
            bytes32 _whitelistRootHash
        ) 
        ERC721Tradable("BuybackNFT", "BBNFT", _proxyRegistryAddress) 
        PaymentSplitter(_payees, _shares) 
        payable {
        // Check that the constructor parameters are the expected ones.
        require(
            _payees.length == 4, 
            "Please provide the address of the community wallet, of the artist, of the dev and of the marketer."
        );
        require(
            _shares.length == 4, 
            "Please provide the shares of the community wallet, of the artist, of the dev and of the marketer."
        );

        require(_payees[0] == communityAddress, "First payee address should be of the community wallet.");
        require(_payees[1] == artistAddress, "Second payee address should be of the artist.");
        require(_payees[2] == devAddress, "Third payee address should be of the dev.");
        require(_payees[3] == marketingAddress, "Forth payee address should be of the marketer.");

        require(_shares[0] == 292, "The community wallet should receive 29.2% (292 shares).");
        require(_shares[1] == _shares[2] && _shares[1] == _shares[3], "The artist, the dev, and the marketer should receive equal shares.");
        require(_shares[1] == 236, "Every team member should receive 23.6% (236 shares).");

        whitelistRootHash = _whitelistRootHash;

        // counterMintedPublic and counterMintedTeam are initialized to 1, since starting at 0 leads to higher gas cost
        // for the first public/team minter.
        counterMintedPublic.increment();
        counterMintedTeam.increment();

        currentBaseURI = "http://18.133.31.150/api/";  // TODO: Replace this with the actual base uri of the backend.
    }

    function baseTokenURI() override public view returns (string memory) {
        return currentBaseURI;
    }

    function setBaseURI(string memory baseURI) public onlyTeam {
        currentBaseURI = baseURI;
    }

    function _msgSender()
        internal
        override (Context)
        view
        returns (address sender)
    {
        return ContextMixin.msgSender();
    }

    // ===== Minting configurations =====
    function allowWhitelistMint() external onlyTeam {
        require(whitelistMintingAllowed == false, "Whitelist minting is already allowed.");  // Try to save some gas.
        whitelistMintingAllowed = true;
    }

    function forbidWhitelistMint() external onlyTeam {
        require(whitelistMintingAllowed == true, "Whitelist minting is already forbidden.");  // Try to save some gas.
        whitelistMintingAllowed = false;
    }

    function allowMint() external onlyTeam {
        require(mintingAllowed == false, "Minting is already allowed.");  // Try to save some gas.
        mintingAllowed = true;
    }

    function forbidMint() external onlyTeam {
        require(mintingAllowed == true, "Minting is already forbidden.");  // Try to save some gas.
        mintingAllowed = false;
    }

    function setMintPriceWei(uint256 newMintPriceWei) public onlyTeam {
        mintPriceWei = newMintPriceWei;
    }

    function setWhitelistMintPriceWei(uint256 newWhitelistMintPriceWei) public onlyTeam {
        whitelistMintPriceWei = newWhitelistMintPriceWei;
    }

    function setWalletMintLimit(uint256 newMintLimit) public onlyTeam {
        walletMintLimit = newMintLimit;
    }

    function setWalletWhitelistMintLimit(uint256 newWhitelistMintLimit) public onlyTeam {
        walletWhitelistMintLimit = newWhitelistMintLimit;
    }


    function setWhitelistRootHash(bytes32 newWhitelistRootHash) external onlyTeam {
        whitelistRootHash = newWhitelistRootHash;
    }

    function setMaxSupplyPublic(uint32 newMaxSupplyPublic) public onlyTeam {
        require(newMaxSupplyPublic + maxSupplyTeam <= 10_000, "The absolute maximum supply can't be over 10,000.");
        maxSupplyPublic = newMaxSupplyPublic;
    }


    // ===== Minting =====
    function mint(uint256 numToMint) external payable {
        // Check all minting preconditions.
        require(mintingAllowed == true, "Minting is currently not allowed.");

        require(numToMint >= 1, "At least 1 NFT must be minted.");

        uint256 numMintedPublic = counterMintedPublic.current() - 1;  // Possibly cheaper than calling getNumMintedPublic.
        require(numMintedPublic + numToMint <= maxSupplyPublic, "The requested number of NFTs would go over the maximum public supply.");
        
        require(msg.value == numToMint * mintPriceWei, "Incorrect paid amount for minting the desired NFTs.");

        // Enforce wallet mint limit.
        uint256 numMintedBySender = mintedBalance[msg.sender];
        require(
            numMintedBySender + numToMint <= walletMintLimit, 
            "The requested number of NFTs would go over the wallet mint limit."
        );

        // The actual minting.
        uint256 nextTokenId;
        for (uint iMinted = 0; iMinted < numToMint; iMinted++) {
            nextTokenId = getNextTokenId();
            _safeMint(msg.sender, nextTokenId);
            counterMintedPublic.increment();
        }
        mintedBalance[msg.sender] += numToMint;
    }

    function mintWhitelist(uint256 _numToMint, bytes32[] calldata _merkleProof) external payable {
        // Check all whitelist minting preconditions.
        require(whitelistMintingAllowed == true, "Whitelist minting is currently not allowed.");

        require(_numToMint >= 1, "At least 1 NFT must be minted.");

        uint256 numMintedPublic = counterMintedPublic.current() - 1;  // Possibly cheaper than calling getNumMintedPublic.
        require(numMintedPublic + _numToMint <= maxSupplyPublic, "The requested number of NFTs would go over the maximum public supply.");
        
        require(msg.value == _numToMint * whitelistMintPriceWei, "Incorrect paid amount for minting the desired NFTs.");

        // Check that the sender is on the whitelist.
        require(isWhitelisted(msg.sender, _merkleProof) == true, "You are not on the whitelist.");

        // Enforce whitelist wallet mint limit.
        uint256 numMintedBySender = mintedBalance[msg.sender];
        require(
            numMintedBySender + _numToMint <= walletWhitelistMintLimit, 
            "The requested number of NFTs would go over the wallet whitelist mint limit."
        );

        // The actual minting.
        uint256 nextTokenId;
        for (uint iMinted = 0; iMinted < _numToMint; iMinted++) {
            nextTokenId = getNextTokenId();
            _safeMint(msg.sender, nextTokenId);
            counterMintedPublic.increment();
        }
        mintedBalance[msg.sender] += _numToMint;
    }

    function mintTeam(address destination, uint256 numToMint) external onlyTeam {
        uint256 numMintedTeam = counterMintedTeam.current() - 1;  // Possibly cheaper than calling getNumMintedTeam.
        require(numMintedTeam + numToMint <= maxSupplyTeam, "The requested amount of NFTs would go over the maximum team supply.");

        uint256 nextTokenId;
        for (uint iMinted = 0; iMinted < numToMint; iMinted++) {
            nextTokenId = getNextTokenId();
            _safeMint(destination, nextTokenId);
            counterMintedTeam.increment();
        }
    }

    // ===== Getters =====
    function getMintPriceWei() public view returns (uint256) {
        return mintPriceWei;
    }

    function getWhitelistMintPriceWei() public view returns (uint256) {
        return whitelistMintPriceWei;
    }

    function getWalletMintLimit() public view returns (uint256) {
        return walletMintLimit;
    }

    function getWalletWhitelistMintLimit() public view returns (uint256) {
        return walletWhitelistMintLimit;
    }

    function getNumMintedByAddress(address minter) public view returns (uint256) {
        return mintedBalance[minter];
    }

    function getNumMintedPublic() public view returns (uint256) {
        return counterMintedPublic.current() - 1;
    }

    function getNumMintedTeam() public view returns (uint256) {
        return counterMintedTeam.current() - 1;
    }

    function getNumMinted() public view returns (uint256) {
        return counterMintedPublic.current() + counterMintedTeam.current() - 2;
    }

    function getPublicSupply() public view returns (uint32) {
        return maxSupplyPublic;
    }

    function getTeamSupply() public view returns (uint32) {
        return maxSupplyTeam;
    }

    function getTotalSupply() public view returns (uint32) {
        return maxSupplyPublic + maxSupplyTeam;
    }

    function getNextTokenId() public view returns (uint256) {
        // return (counterMintedPublic.current() - 1) + (counterMintedTeam.current() - 1) + 1;
        // gets "optimized" to:
        return counterMintedPublic.current() + counterMintedTeam.current() - 1;
    }

    function getWhitelistRootHash() public view returns (bytes32) {
        return whitelistRootHash;
    }

    function isMintingAllowed() public view returns (bool) {
        return mintingAllowed;
    }

    function isWhitelistMintingAllowed() public view returns (bool) {
        return whitelistMintingAllowed;
    }

    function isWhitelisted(address _user, bytes32[] calldata _merkleProof) public view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(_user));
        
        return MerkleProof.verify(_merkleProof, whitelistRootHash, leaf);
    }

    // ===== Auxiliary =====
    function random() internal view returns (uint256) {
        return uint256(keccak256(abi.encode(block.timestamp, block.difficulty)));
    }
}
