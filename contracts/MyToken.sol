// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/extensions/ERC1155BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MyToken is Initializable, ERC1155Upgradeable, OwnableUpgradeable, ERC1155PausableUpgradeable, ERC1155BurnableUpgradeable, UUPSUpgradeable {
    // 记录用户对特定 NFT 合约和 tokenId 的授权数量
    mapping(address => mapping(address => mapping(uint256 => uint256))) public approvedAmounts;

    // 挂单结构体
    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 amount;
        address paymentToken; // ERC20 代币地址，0x0 表示以太币
        uint256 price; // 每单位 NFT 的价格
        bool active; // 挂单是否有效
    }

    // 挂单记录
    mapping(uint256 => Listing) public listings;
    uint256 public listingIdCounter;

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) initializer public {
        __ERC1155_init("");
        __Ownable_init(initialOwner);
        __ERC1155Pausable_init();
        __ERC1155Burnable_init();
        __UUPSUpgradeable_init();
        listingIdCounter = 1;
    }

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function mint(address account, uint256 id, uint256 amount, bytes memory data) public onlyOwner {
        _mint(account, id, amount, data);
    }

    function mintBatch(address to, uint256[] memory ids, uint256[] memory amounts, bytes memory data) public onlyOwner {
        _mintBatch(to, ids, amounts, data);
    }

    function _authorizeUpgrade(address newImplementation) internal onlyOwner override {}

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Upgradeable, ERC1155PausableUpgradeable)
    {
        super._update(from, to, ids, values);
    }

    // 事件
    event NFTApproved(address indexed nftContract, address indexed owner, uint256 id, uint256 amount, bool approved);
    event NFTListed(uint256 indexed listingId, address indexed seller, address nftContract, uint256 tokenId, uint256 amount, address paymentToken, uint256 price);
    event NFTPurchased(uint256 indexed listingId, address indexed buyer, address indexed seller, address nftContract, uint256 tokenId, uint256 amount, uint256 totalPrice);
    event ListingCancelled(uint256 indexed listingId);

    // // 授权指定 NFT 合约的 tokenId 和数量
    // function approveNFT(address nftContract, uint256 id, uint256 amount) external {
    //     require(nftContract != address(0), "Invalid NFT contract address");
    //     require(amount > 0, "Approval amount must be greater than 0");
    //     require(IERC1155Upgradeable(nftContract).balanceOf(msg.sender, id) >= amount, "Insufficient NFT balance");

    //     approvedAmounts[msg.sender][nftContract][id] = amount;
    //     IERC1155Upgradeable(nftContract).setApprovalForAll(address(this), true);
    //     emit NFTApproved(nftContract, msg.sender, id, amount, true);
    // }

    // 挂单 NFT
    function listNFT(address nftContract, uint256 tokenId, uint256 amount, address paymentToken, uint256 price) external returns (uint256) {
        require(nftContract != address(0), "Invalid NFT contract address");
        require(amount > 0, "Listing amount must be greater than 0");
        require(price > 0, "Price must be greater than 0");
        require(IERC1155Upgradeable(nftContract).balanceOf(msg.sender, tokenId) >= amount, "Insufficient NFT balance");
        require(approvedAmounts[msg.sender][nftContract][tokenId] >= amount, "Insufficient approved amount");

        uint256 listingId = listingIdCounter++;
        listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            amount: amount,
            paymentToken: paymentToken,
            price: price,
            active: true
        });

        emit NFTListed(listingId, msg.sender, nftContract, tokenId, amount, paymentToken, price);
        return listingId;
    }

    // 购买 NFT
    function buyNFT(uint256 listingId, uint256 amount) external payable {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing is not active");
        require(amount > 0 && amount <= listing.amount, "Invalid purchase amount");
        require(IERC1155Upgradeable(listing.nftContract).balanceOf(listing.seller, listing.tokenId) >= amount, "Seller has insufficient NFT balance");
        require(approvedAmounts[listing.seller][listing.nftContract][listing.tokenId] >= amount, "Seller has insufficient approved amount");

        uint256 totalPrice = listing.price * amount;

        // 处理支付
        if (listing.paymentToken == address(0)) {
            // eth支付
            require(msg.value >= totalPrice, "Insufficient ETH sent");
            payable(listing.seller).transfer(totalPrice);
            if (msg.value > totalPrice) {
                payable(msg.sender).transfer(msg.value - totalPrice); // 退还多余的 ETH
            }
        } else {
            // ERC20 代币支付
            IERC20 token = IERC20(listing.paymentToken);
            require(token.transferFrom(msg.sender, listing.seller, totalPrice), "Payment failed");
        }

        // 更新挂单
        listing.amount -= amount;
        approvedAmounts[listing.seller][listing.nftContract][listing.tokenId] -= amount;
        if (listing.amount == 0) {
            listing.active = false;
        }

        // 转移 NFT
        IERC1155Upgradeable(listing.nftContract).safeTransferFrom(listing.seller, msg.sender, listing.tokenId, amount, "");
        emit NFTPurchased(listingId, msg.sender, listing.seller, listing.nftContract, listing.tokenId, amount, totalPrice);
    }

    // 取消挂单
    function cancelListing(uint256 listingId) external {
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender, "Only seller can cancel");
        require(listing.active, "Listing is not active");

        listing.active = false;
        emit ListingCancelled(listingId);
    }

    // 查询指定 NFT 合约的余额
    function getNFTBalance(address nftContract, address account, uint256 id) external view returns (uint256) {
        require(nftContract != address(0), "Invalid NFT contract address");
        return IERC1155Upgradeable(nftContract).balanceOf(account, id);
    }

    // 查询指定 NFT 合约和 tokenId 的授权数量
    function getApprovedAmount(address account, address nftContract, uint256 id) external view returns (uint256) {
        require(nftContract != address(0), "Invalid NFT contract address");
        return approvedAmounts[account][nftContract][id];
    }

    // // 授权 ERC20 代币
    // function approveERC20(address tokenAddress, address spender, uint256 amount) external {
    //     require(amount > 0, "Amount must be greater than 0");
    //     IERC20 token = IERC20(tokenAddress);
    //     token.approve(spender, amount);
    // }

    // // ERC20 货币转账 
    // function transferERC20(address tokenAddress, address to, uint256 amount) external {
    //     require(amount > 0, "Transfer amount must be greater than 0");
    //     IERC20 token = IERC20(tokenAddress);
    //     token.transferFrom(msg.sender, to, amount);
    // }
}