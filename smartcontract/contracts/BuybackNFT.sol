// SPDX-License-Identifier: MIT
// The PaymentSplitter code is from OpenZeppelin, but slightly addapted to support
// a locked amount of shares that never get split among payees.
pragma solidity >=0.4.22 <0.9.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";


import "./ERC721Tradable.sol";

contract BuybackNFT is ERC721Tradable {
    // !!! Token IDs are indexed starting from 1 !!!
    using Counters for Counters.Counter;

    string private currentBaseURI;

    // Minting related.
    uint256 private mintPriceWei = 0.03 ether;  // The price gets stored as an uint256 representing the price in WEI.  // TODO: set to actual value

    uint32 private maxSupply = 5_000;  // TODO: set to actual value

    Counters.Counter private counterBuybackable;  // Starts at 1 (when the real value is 0). It's equal to (Nb + 1) from formulae.
    Counters.Counter private counterLastMinted; // Starts at 1 (when the real value is 0), stops at (maxSupply + 1). It never decreases.

    bool private mintingAllowed = false;
    bool private whitelistMintingAllowed = false;

    bytes32 private whitelistRootHash;
    
    mapping(address => uint256) public mintedBalance;  // How many NFTs each address has minted (different from how many it owns).
    uint256 private walletWhitelistMintLimit = 2;  // TODO: set to actual value.
    uint256 private walletMintLimit = 20;  // TODO: set to actual value.

    address[] private teamMembers =  [  // TODO: Change these to real addresses.
        0xddFC8347A32107eE5CE4825C5a2c4753Bcd580eb,
        0x9972C48FBdeB6044A4075e19345F734AcC03f84D,
        0xb3ED329E26B3867b7161c5614EB6385e471A80e1,
        0xcb41c104eFFF7962DB8CEB42Da0f0E84b80C11e1
    ];
    address private insuranceFundManager = 0xb3ED329E26B3867b7161c5614EB6385e471A80e1;  // TODO: set to actual value.

    // Buyback mechanism related
    bool private refundingAllowed = false;
    uint256 private buybackPriceWei = 0.03 ether;  // Must always be smaller than any minting price.  // TODO: set to actual value.
    uint256 private totalWeiInputs;
    uint256 private totalWeiBuybacks;
    uint256 private numIdsExtractedInsurance;  // The equivalent of how many NFTs' refund insurance was extracted.

    event PaidBack(address nftOwner, uint256 nftId);  // Buyback event.

    // address constant openseaProxyRegistryAddress = 0xF57B2c51dED3A29e6891aba85459d600256Cf317; for Rinkeby  // TODO: Replace this with the Mainnet address in the contract deployment migration!!!.
    // for MainNet: address constant openseaProxyRegistryAddress = 0xa5409ec958C83C3f309868babACA7c86DCB077c1;

    modifier onlyTeam {
        bool isTeamMember = false;
        for (uint256 iTeamMember = 0; iTeamMember < teamMembers.length; iTeamMember++) {
            if (msg.sender == teamMembers[iTeamMember]) {
                isTeamMember = true;
                break;
            }
        }

        require(
            isTeamMember,
            "Only the team members can call this function."
        );
        _;
    }

    modifier onlyManager {
        require(msg.sender == insuranceFundManager, "Only the insurance fund manager can call this function.");
        _;
    }

    // =============== PaymentSplitter state & events ===============
    event PayeeAdded(address account, uint256 shares);
    event PaymentReleased(address to, uint256 amount);
    event PaymentReceived(address from, uint256 amount);

    uint256 public _totalShares;
    uint256 public _totalReleased;
    
    mapping(address => uint256) public _shares;
    mapping(address => uint256) public _released;
    address[] public _payees;
    // ==============================================================


    // =============== Constructor and OpenSea's interfaces related (baseTokenURI and _msgSender) ===============
    constructor(
            address[] memory payees_, uint256[] memory shares_,
            bytes32 whitelistRootHash_,
            address proxyRegistryAddress_
        )
        ERC721Tradable("BuybackNFT", "BBNFT", proxyRegistryAddress_)  
        payable {
        // Check that the constructor parameters are the expected ones.
        require(payees_.length == shares_.length, "PaymentSplitter: payees and shares length mismatch");
        require(payees_.length > 0, "PaymentSplitter: no payees");

        // Make sure the initialization values are correct.
        require(mintPriceWei >= buybackPriceWei, "Buyback price must always be smaller or equal to the minting price to ensure it can be paid.");

        // ========== Conditions for the agreed payees and their shares. ==========
        // TODO: Change these conditions based on the number of payees and their agreed shares.
        require(
            payees_.length == 4, 
            "Please provide the addresses and shares of the community wallet, of the artist, of the dev and of the marketer."
        );

        require(payees_[0] == teamMembers[0], "First payee address should be of the community wallet.");
        require(payees_[1] == teamMembers[1], "Second payee address should be of the artist.");
        require(payees_[2] == teamMembers[2], "Third payee address should be of the dev.");
        require(payees_[3] == teamMembers[3], "Fourth payee address should be of the marketer.");

        require(shares_[0] == 100, "The community wallet should receive 10% (100 shares).");
        require(shares_[1] == 250, "The artist should receive 25% (250 shares).");
        require(shares_[2] == 500, "The developer should receive 50% (500 shares).");
        require(shares_[3] == 150, "The marketer should receive 15% (150 shares).");
        // ======================================================================================================

        // ========== PaymentSplitter initialization ==========
        for (uint256 i = 0; i < payees_.length; i++) {
            _addPayee(payees_[i], shares_[i]);
        }
        // ====================================================

        whitelistRootHash = whitelistRootHash_;

        // Counters are initialized to 1, since starting at 0 leads to higher gas cost for the first minter.
        counterBuybackable.increment();
        counterLastMinted.increment();

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

    // =============== Setters ===============
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

    function allowRefund() external onlyTeam {
        require(refundingAllowed == false, "Refunding is already allowed");  // Try to save some gas.
        require(numIdsExtractedInsurance == 0, "To enable refunding, make sure the insurance refund is complete.");
        refundingAllowed = true;
    }

    function forbidRefund() external onlyTeam {
        require(refundingAllowed == true, "Refunding is already forbidden");  // Try to save some gas.
        refundingAllowed = false;
    }

    function setMintPriceWei(uint256 newMintPriceWei) public onlyTeam {
        require(
            newMintPriceWei >= buybackPriceWei, 
            "The minting price must always be >= than the refund price to ensure enough ETH is in the wallet for later refunds."
        );
        mintPriceWei = newMintPriceWei;
    }

    function setBuybackPriceWei(uint256 newBuybackPriceWei) public onlyTeam {
        require(
            numIdsExtractedInsurance == 0, 
            "Before potentially reducing the buyback price, the insurance fund must be complete. Otherwise, profit takers might try to take ETH that is not present in the contract."
        );

        if (newBuybackPriceWei > buybackPriceWei) {
            // Insure the past.
            require(
                getNumBuybackable() == 0, 
                "The refunded amount can only be increased when there are no refundable NFTs to ensure enough ETH is in the wallet for later refunds."
            );
        }
        // Insure the future.
        // Theoretically, the next require is only needed when newBuybackPriceWei > buybackPriceWei, otherwise it should already be satisfied,
        // but it doesn't hurt to be extra safe.
        require(
            newBuybackPriceWei <= mintPriceWei,
            "The refunded amount cannot be larger than the minting price. Consider increasing the mint price first."
        );

        buybackPriceWei = newBuybackPriceWei;
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

    function setMaxSupply(uint32 newMaxSupply) public onlyTeam {
        require(newMaxSupply <= 10_000, "The absolute maximum supply can't be over 10,000.");
        maxSupply = newMaxSupply;
    }
    // ======================================================

    // =============== Getters ===============
    function getMintPriceWei() public view returns (uint256) {
        return mintPriceWei;
    }

    function getBuybackPriceWei() public view returns (uint256) {
        return buybackPriceWei;
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

    function getIdLastMinted() public view returns (uint256) {
        return counterLastMinted.current() - 1;
    }

    function getNumBuybackable() public view returns (uint256) {
        return counterBuybackable.current() - 1;
    }

    function getTotalSupply() public view returns (uint32) {
        return maxSupply;
    }

    function getNextMintableId() public view returns (uint256) {
        return counterLastMinted.current();
    }

    function getIdsOwnedByUser(address user_) public view returns (uint256[] memory) {
        uint256 numOwned = balanceOf(user_);
        uint256[] memory ownedIds = new uint256[](numOwned);

        uint256 idLastMinted = getIdLastMinted();
        uint256 iOwned;
        for (uint256 tokenId = 1; tokenId <= idLastMinted && iOwned < numOwned; ++tokenId) {
            if (_exists(tokenId) && ownerOf(tokenId) == user_) {
                ownedIds[iOwned] = tokenId;
                iOwned++;
            }
        }

        return ownedIds;
    }

    function getNumBurntIds() public view returns (uint256) {
        uint256 numBurnt;

        uint256 idLastMinted = getIdLastMinted();
        for (uint256 tokenId = 1; tokenId <= idLastMinted; ++tokenId) {
            if (!_exists(tokenId)) {
                numBurnt++;
            }
        }

        return numBurnt;
    }

    function getBurntIds() public view returns (uint256[] memory) {
        uint256 numBurnt = getNumBurntIds();
        uint256[] memory burntIds = new uint256[](numBurnt);

        uint256 idLastMinted = getIdLastMinted();
        uint256 iBurnt;
        for (uint256 tokenId = 1; tokenId <= idLastMinted; ++tokenId) {
            if (!_exists(tokenId)) {
                burntIds[iBurnt] = tokenId;
                iBurnt++;
            }
        }

        return burntIds;
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

    function isWhitelisted(address user_, bytes32[] calldata merkleProof_) public view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user_));
        
        return MerkleProof.verify(merkleProof_, whitelistRootHash, leaf);
    }
    // =======================================


    // =============== Minting & Refunding & Buying bought back functions ===============
    function mint(uint256 numToMint_) external payable {
        // Check all minting preconditions.
        require(mintingAllowed == true, "Minting is currently not allowed.");

        require(numToMint_ >= 1, "At least 1 NFT must be minted.");

        uint256 numMinted = getIdLastMinted();
        require(numMinted + numToMint_ <= maxSupply, "The requested number of NFTs would go over the maximum supply.");
        
        require(msg.value == numToMint_ * mintPriceWei, "Incorrect paid amount for minting the desired NFTs.");

        // Enforce wallet mint limit.
        uint256 numMintedBySender = mintedBalance[msg.sender];
        require(
            numMintedBySender + numToMint_ <= walletMintLimit, 
            "The requested number of NFTs would go over the wallet mint limit."
        );

        // The actual minting.
        uint256 nextTokenId;
        for (uint iMinted = 0; iMinted < numToMint_; iMinted++) {
            nextTokenId = getNextMintableId();
            _safeMint(msg.sender, nextTokenId);
            counterLastMinted.increment();
            counterBuybackable.increment();
        }
        mintedBalance[msg.sender] += numToMint_;
        
        totalWeiInputs += msg.value;
    }

    function mintWhitelist(uint256 numToMint_, bytes32[] calldata merkleProof_) external payable {
        // Check all whitelist minting preconditions.
        require(whitelistMintingAllowed == true, "Whitelist minting is currently not allowed.");

        require(numToMint_ >= 1, "At least 1 NFT must be minted.");

        uint256 numMinted = getIdLastMinted();
        require(numMinted + numToMint_ <= maxSupply, "The requested number of NFTs would go over the maximum supply.");
        
        require(msg.value == numToMint_ * mintPriceWei, "Incorrect paid amount for minting the desired NFTs.");

        // Check that the sender is on the whitelist.
        require(isWhitelisted(msg.sender, merkleProof_) == true, "Wallet address is not on the whitelist.");

        // Enforce whitelist wallet mint limit.
        uint256 numMintedBySender = mintedBalance[msg.sender];
        require(
            numMintedBySender + numToMint_ <= walletWhitelistMintLimit, 
            "The requested number of NFTs would go over the wallet whitelist mint limit."
        );

        // The actual minting.
        uint256 nextTokenId;
        for (uint iMinted = 0; iMinted < numToMint_; iMinted++) {
            nextTokenId = getNextMintableId();
            _safeMint(msg.sender, nextTokenId);
            counterLastMinted.increment();
            counterBuybackable.increment();
        }
        mintedBalance[msg.sender] += numToMint_;

        totalWeiInputs += msg.value;
    }

    function partialRefund(uint256 tokenId) external {
        require(refundingAllowed == true, "Refunding is not currently allowed");
        require(tokenId >= 1, "NFT ids are indexed from 1.");
        
        uint256 idLastMinted = getIdLastMinted();
        require(tokenId <= idLastMinted, "NFT id was not minted or is past the maximum supply.");

        require(ownerOf(tokenId) == msg.sender, "Wallet does not hold the NFT requested to be refunded.");

        _burn(tokenId);
        Address.sendValue(payable(msg.sender), buybackPriceWei);
        counterBuybackable.decrement();

        totalWeiBuybacks += buybackPriceWei;
    }

    function extractInsuranceFund() external onlyManager {
        require(refundingAllowed == false, "In order to extract the insurance fund, refunding must be forbidden!");

        uint256 numBuybackable = getNumBuybackable();

        uint256 numIdsRemainingToExtractFor = numBuybackable - numIdsExtractedInsurance;
        require(numIdsRemainingToExtractFor > 0, "The insurance funds were already extracted for all insured NFTs.");

        uint256 availableInsuranceFund = numIdsRemainingToExtractFor * buybackPriceWei;

        Address.sendValue(payable(insuranceFundManager), availableInsuranceFund);
        numIdsExtractedInsurance = numBuybackable;
    }

    function returnInsuranceFund() external payable {
        require(numIdsExtractedInsurance > 0, "The insurance fund is already complete.");

        require(msg.value == numIdsExtractedInsurance * buybackPriceWei, "Incorrect amount returned for the insurance fund.");

        numIdsExtractedInsurance = 0;
    }
    // =================================================

    // =============== PaymentSplitter implementation ===============
    /**
     * @dev The Ether received will be logged with {PaymentReceived} events. Note that these events are not fully
     * reliable: it's possible for a contract to receive Ether without triggering this function. This only affects the
     * reliability of the events, and not the actual splitting of Ether.
     *
     * To learn more about this see the Solidity documentation for
     * https://solidity.readthedocs.io/en/latest/contracts.html#fallback-function[fallback
     * functions].
     */
    receive() external payable virtual {
        emit PaymentReceived(_msgSender(), msg.value);
    }

    /**
     * @dev Getter for the total shares held by payees.
     */
    function totalShares() public view returns (uint256) {
        return _totalShares;
    }

    /**
     * @dev Getter for the total amount of Ether already released to payees.
     */
    function totalReleased() public view returns (uint256) {
        return _totalReleased;
    }

    function getTotalProfit() public view returns (uint256) {
        uint256 numBuybackable = getNumBuybackable();
        
        return totalWeiInputs - totalWeiBuybacks - numBuybackable * buybackPriceWei;
    }

    function getTotalInsuranceFund() public view returns (uint256) {
        uint256 numBuybackable = getNumBuybackable();

        return numBuybackable * buybackPriceWei;
    }

    function getRemainingInsuranceFund() public view returns (uint256) {
        uint256 numBuybackable = getNumBuybackable();

        return (numBuybackable - numIdsExtractedInsurance) * buybackPriceWei;
    }

    function getExtractedInsuranceFund() public view returns (uint256) {
        return numIdsExtractedInsurance * buybackPriceWei;
    }

    /**
     * @dev Getter for the amount of shares held by an account.
     */
    function shares(address account) public view returns (uint256) {
        return _shares[account];
    }

    /**
     * @dev Getter for the amount of Ether already released to a payee.
     */
    function released(address account) public view returns (uint256) {
        return _released[account];
    }

    /**
     * @dev Getter for the address of the payee number `index`.
     */
    function payee(uint256 index) public view returns (address) {
        return _payees[index];
    }

    /**
     * @dev Triggers a transfer to `account` of the amount of Ether they are owed, according to their percentage of the
     * total shares and their previous withdrawals.
     */
    function release(address payable account) public virtual {
        require(_shares[account] > 0, "PaymentSplitter: account has no shares");

        uint256 totalProfit = getTotalProfit();
        uint256 payment = _pendingPayment(account, totalProfit, released(account));

        require(payment > 0, "PaymentSplitter: account is not due payment");
        // This should never happen, but better safe than sorry:
        require(address(this).balance > 0, "Entitled to payment, but contract balance is currently 0.");

        payment = Math.min(payment, address(this).balance);  // Again, it should never happen that payment > balance.

        _released[account] += payment;
        _totalReleased += payment;

        Address.sendValue(account, payment);
        emit PaymentReleased(account, payment);
    }

    function releaseForEveryone() public {
        uint256 totalProfit = getTotalProfit();

        for (uint256 iPayee = 0; iPayee < _payees.length; iPayee++) {
            address currPayee = _payees[iPayee];
            uint256 payment = _pendingPayment(currPayee, totalProfit, released(currPayee));
            if (payment > 0) {
                release(payable(currPayee));
            }
        }
    }

    /**
     * @dev internal logic for computing the pending payment of an `account` given the token historical balances and
     * already released amounts.
     */
    function _pendingPayment(
        address account,
        uint256 totalProfit,
        uint256 alreadyReleased
    ) private view returns (uint256) {
        return (totalProfit * _shares[account]) / _totalShares - alreadyReleased;
    }

    /**
     * @dev Add a new payee to the contract.
     * @param account The address of the payee to add.
     * @param shares_ The number of shares owned by the payee.
     */
    function _addPayee(address account, uint256 shares_) private {
        require(account != address(0), "PaymentSplitter: account is the zero address");
        require(shares_ > 0, "PaymentSplitter: shares are 0");
        require(_shares[account] == 0, "PaymentSplitter: account already has shares");

        _payees.push(account);
        _shares[account] = shares_;
        _totalShares = _totalShares + shares_;
        emit PayeeAdded(account, shares_);
    }
    // ==============================================================
}
