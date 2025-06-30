// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title PropertyToken
 * @dev ERC1155 token representing fractional ownership of real estate properties
 */
contract PropToken is ERC1155, Ownable, ReentrancyGuard, Pausable {
    using Strings for uint256;
    
    struct Property {
        uint256 id;
        string propertyAddress;
        string zipCode;
        uint256 totalSupply;
        uint256 currentValuation;
        uint256 lastValuationUpdate;
        uint256 monthlyRent;
        bool isActive;
        address propertyOwner;
        string metadataURI;
        PropertyType propertyType;
        uint256 purchasePrice;
        uint256 createdAt;
    }
    
    enum PropertyType {
        Residential,
        Commercial,
        Industrial,
        Mixed
    }
    
    mapping(uint256 => Property) public properties;
    mapping(uint256 => mapping(address => uint256)) public shareholdings;
    mapping(address => bool) public authorizedManagers;
    
    uint256 public nextPropertyId = 1;
    uint256 public constant SHARES_PER_PROPERTY = 10000;
    uint256 public constant PLATFORM_FEE_BASIS_POINTS = 200; // 2%
    
    address public propertyVault;
    address public crossChainManager;
    
    event PropertyTokenized(
        uint256 indexed propertyId,
        address indexed owner,
        uint256 totalSupply,
        uint256 initialValuation
    );
    
    event SharesTransferred(
        uint256 indexed propertyId,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    
    event PropertyValuationUpdated(
        uint256 indexed propertyId,
        uint256 oldValuation,
        uint256 newValuation
    );
    
    modifier onlyAuthorized() {
        require(
            authorizedManagers[msg.sender] || msg.sender == owner(),
            "Not authorized"
        );
        _;
    }
    
    constructor(
        string memory _uri,
        address _propertyVault,
        address initialOwner
    ) ERC1155(_uri) Ownable(initialOwner) {
        propertyVault = _propertyVault;
    }
    
    /**
     * @dev Tokenize a new property
     */
    function tokenizeProperty(
        string memory _propertyAddress,
        string memory _zipCode,
        uint256 _initialValuation,
        uint256 _monthlyRent,
        PropertyType _propertyType,
        string memory _metadataURI,
        address _propertyOwner
    ) external onlyAuthorized returns (uint256) {
        uint256 propertyId = nextPropertyId++;
        
        properties[propertyId] = Property({
            id: propertyId,
            propertyAddress: _propertyAddress,
            zipCode: _zipCode,
            totalSupply: SHARES_PER_PROPERTY,
            currentValuation: _initialValuation,
            lastValuationUpdate: block.timestamp,
            monthlyRent: _monthlyRent,
            isActive: true,
            propertyOwner: _propertyOwner,
            metadataURI: _metadataURI,
            propertyType: _propertyType,
            purchasePrice: _initialValuation,
            createdAt: block.timestamp
        });
        
        // Mint shares according to tokenomics
        _mint(_propertyOwner, propertyId, 1000, ""); // 10% to owner
        _mint(propertyVault, propertyId, 300, ""); // 3% to platform
        _mint(address(this), propertyId, 8700, ""); // 87% available for investors
        
        emit PropertyTokenized(propertyId, _propertyOwner, SHARES_PER_PROPERTY, _initialValuation);
        
        return propertyId;
    }
    
    /**
     * @dev Purchase property shares
     */
    function purchaseShares(
        uint256 _propertyId,
        uint256 _shares
    ) external payable nonReentrant whenNotPaused {
        require(properties[_propertyId].isActive, "Property not active");
        require(_shares > 0, "Invalid share amount");
        require(balanceOf(address(this), _propertyId) >= _shares, "Insufficient shares available");
        
        uint256 sharePrice = getSharePrice(_propertyId);
        uint256 totalCost = sharePrice * _shares;
        uint256 platformFee = (totalCost * PLATFORM_FEE_BASIS_POINTS) / 10000;
        
        require(msg.value >= totalCost + platformFee, "Insufficient payment");
        
        // Transfer shares to buyer
        _safeTransferFrom(address(this), msg.sender, _propertyId, _shares, "");
        shareholdings[_propertyId][msg.sender] += _shares;
        
        // Send payment to property vault
        (bool success, ) = propertyVault.call{value: totalCost}("");
        require(success, "Payment transfer failed");
        
        // Return excess payment
        if (msg.value > totalCost + platformFee) {
            payable(msg.sender).transfer(msg.value - totalCost - platformFee);
        }
        
        emit SharesTransferred(_propertyId, address(this), msg.sender, _shares);
    }
    
    /**
     * @dev Get current share price for a property
     */
    function getSharePrice(uint256 _propertyId) public view returns (uint256) {
        Property memory property = properties[_propertyId];
        return property.currentValuation / SHARES_PER_PROPERTY;
    }
    
    /**
     * @dev Update property valuation (called by Chainlink Functions)
     */
    function updatePropertyValuation(
        uint256 _propertyId,
        uint256 _newValuation
    ) external onlyAuthorized {
        require(properties[_propertyId].isActive, "Property not active");
        
        uint256 oldValuation = properties[_propertyId].currentValuation;
        properties[_propertyId].currentValuation = _newValuation;
        properties[_propertyId].lastValuationUpdate = block.timestamp;
        
        emit PropertyValuationUpdated(_propertyId, oldValuation, _newValuation);
    }
    
    /**
     * @dev Mint tokens (for cross-chain operations)
     */
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external onlyAuthorized {
        _mint(to, id, amount, data);
    }
    
    /**
     * @dev Set authorized manager
     */
    function setAuthorizedManager(address _manager, bool _authorized) external onlyOwner {
        authorizedManagers[_manager] = _authorized;
    }
    
    /**
     * @dev Set property vault address
     */
    function setPropertyVault(address _propertyVault) external onlyOwner {
        propertyVault = _propertyVault;
    }
    
    /**
     * @dev Set cross-chain manager address
     */
    function setCrossChainManager(address _crossChainManager) external onlyOwner {
        crossChainManager = _crossChainManager;
    }
    
    /**
     * @dev Get property details
     */
    function getProperty(uint256 _propertyId) external view returns (Property memory) {
        return properties[_propertyId];
    }
    
    /**
     * @dev Override URI function for dynamic metadata
     */
    function uri(uint256 _propertyId) public view override returns (string memory) {
        return string(abi.encodePacked(super.uri(_propertyId), properties[_propertyId].metadataURI));
    }
    
    /**
     * @dev Emergency pause
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause
     */
    function unpause() external onlyOwner {
        _unpause();
    }
}