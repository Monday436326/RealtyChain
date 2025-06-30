// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

// Forward declaration to avoid circular dependency
interface IPropertyToken {
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
        uint8 propertyType; // Using uint8 instead of enum for interface
        uint256 purchasePrice;
        uint256 createdAt;
    }
    
    function SHARES_PER_PROPERTY() external view returns (uint256);
    function nextPropertyId() external view returns (uint256);
    function getProperty(uint256 _propertyId) external view returns (Property memory);
    function updatePropertyValuation(uint256 _propertyId, uint256 _newValuation) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/**
 * @title PropertyVault
 * @dev Manages property finances, rent distribution, and yield calculations
 */
contract PropVault is 
    Ownable, 
    ReentrancyGuard, 
    Pausable, 
    AutomationCompatibleInterface,
    FunctionsClient,
    VRFConsumerBaseV2
{
    struct PropertyFinances {
        uint256 propertyId;
        uint256 totalRentCollected;
        uint256 totalExpenses;
        uint256 reserveFund;
        uint256 lastDistribution;
        uint256 pendingDistribution;
        bool autoDistributionEnabled;
    }
    
    struct YieldData {
        uint256 monthlyYield;
        uint256 annualYield;
        uint256 totalROI;
        uint256 lastCalculated;
    }
    
    IPropertyToken public immutable propertyToken;
    AggregatorV3Interface public immutable ethUsdPriceFeed;
    
    mapping(uint256 => PropertyFinances) public propertyFinances;
    mapping(uint256 => YieldData) public yieldData;
    mapping(uint256 => mapping(address => uint256)) public claimableYield;
    mapping(address => uint256) public userTotalYield;
    
    uint256 public constant MANAGEMENT_FEE_BASIS_POINTS = 100; // 1%
    uint256 public constant PERFORMANCE_FEE_BASIS_POINTS = 1000; // 10%
    uint256 public constant RESERVE_REQUIREMENT_MONTHS = 6;
    
    // Chainlink VRF
    VRFCoordinatorV2Interface public immutable vrfCoordinator;
    uint64 public subscriptionId;
    bytes32 public keyHash;
    uint32 public callbackGasLimit = 100000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;
    mapping(uint256 => uint256) public vrfRequestToPropertyId;
    
    // Chainlink Functions
    bytes32 public donId;
    uint64 public functionsSubscriptionId;
    string public valuationSourceCode;
    
    event RentDeposited(uint256 indexed propertyId, uint256 amount, uint256 timestamp);
    event YieldDistributed(uint256 indexed propertyId, uint256 totalAmount, uint256 timestamp);
    event YieldClaimed(address indexed investor, uint256 indexed propertyId, uint256 amount);
    event PropertyValuationRequested(uint256 indexed propertyId, uint256 indexed requestId);
    event ExpenseRecorded(uint256 indexed propertyId, uint256 amount, string description);
    
    modifier onlyPropertyOwner(uint256 _propertyId) {
        IPropertyToken.Property memory property = propertyToken.getProperty(_propertyId);
        require(msg.sender == property.propertyOwner, "Not property owner");
        _;
    }
    
    constructor(
        address _propertyToken,
        address _ethUsdPriceFeed,
        address _vrfCoordinator,
        address _functionsRouter,
        bytes32 _donId,
        address initialOwner
    ) 
        Ownable(initialOwner)
        FunctionsClient(_functionsRouter) 
        VRFConsumerBaseV2(_vrfCoordinator) 
    {
        propertyToken = IPropertyToken(_propertyToken);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        vrfCoordinator = VRFCoordinatorV2Interface(_vrfCoordinator);
        donId = _donId;
    }
    
    /**
     * @dev Deposit monthly rent for a property
     */
    function depositRent(uint256 _propertyId) external payable onlyPropertyOwner(_propertyId) {
        require(msg.value > 0, "No rent amount");
        
        PropertyFinances storage finances = propertyFinances[_propertyId];
        finances.totalRentCollected += msg.value;
        
        // Calculate management fee
        uint256 managementFee = (msg.value * MANAGEMENT_FEE_BASIS_POINTS) / 10000;
        uint256 netRent = msg.value - managementFee;
        
        // Add to pending distribution
        finances.pendingDistribution += netRent;
        
        emit RentDeposited(_propertyId, msg.value, block.timestamp);
        
        // Auto-distribute if enabled
        if (finances.autoDistributionEnabled) {
            _distributeYield(_propertyId);
        }
    }
    
    /**
     * @dev Distribute yield to token holders
     */
    function distributeYield(uint256 _propertyId) external {
        _distributeYield(_propertyId);
    }
    
    function _distributeYield(uint256 _propertyId) internal nonReentrant {
        PropertyFinances storage finances = propertyFinances[_propertyId];
        require(finances.pendingDistribution > 0, "No pending distribution");
        
        uint256 totalShares = propertyToken.SHARES_PER_PROPERTY();
        uint256 distributionAmount = finances.pendingDistribution;
        
        // Calculate yield per share
        uint256 yieldPerShare = distributionAmount / totalShares;
        
        // Update yield data
        YieldData storage yield = yieldData[_propertyId];
        yield.monthlyYield = yieldPerShare;
        yield.lastCalculated = block.timestamp;
        
        // Reset pending distribution
        finances.pendingDistribution = 0;
        finances.lastDistribution = block.timestamp;
        
        emit YieldDistributed(_propertyId, distributionAmount, block.timestamp);
    }
    
    /**
     * @dev Claim yield for a specific property
     */
    function claimYield(uint256 _propertyId) external nonReentrant {
        uint256 shares = propertyToken.balanceOf(msg.sender, _propertyId);
        require(shares > 0, "No shares owned");
        
        uint256 claimableAmount = calculateClaimableYield(msg.sender, _propertyId);
        require(claimableAmount > 0, "No yield to claim");
        
        claimableYield[_propertyId][msg.sender] = 0;
        userTotalYield[msg.sender] += claimableAmount;
        
        (bool success, ) = payable(msg.sender).call{value: claimableAmount}("");
        require(success, "Yield transfer failed");
        
        emit YieldClaimed(msg.sender, _propertyId, claimableAmount);
    }
    
    /**
     * @dev Calculate claimable yield for an investor
     */
    function calculateClaimableYield(address _investor, uint256 _propertyId) public view returns (uint256) {
        uint256 shares = propertyToken.balanceOf(_investor, _propertyId);
        if (shares == 0) return 0;
        
        YieldData memory yield = yieldData[_propertyId];
        return (shares * yield.monthlyYield) + claimableYield[_propertyId][_investor];
    }
    
    /**
     * @dev Request property valuation update using Chainlink Functions
     */
  function requestPropertyValuation(uint256 _propertyId) external returns (bytes32) {
    IPropertyToken.Property memory property = propertyToken.getProperty(_propertyId);

    string[] memory args = new string[](2);
    args[0] = property.propertyAddress;
    args[1] = property.zipCode;


    bytes32 requestId = _sendRequest(
        bytes(valuationSourceCode),

        functionsSubscriptionId, // uint64
        callbackGasLimit,        // uint32
        donId                    // bytes32
    );

    vrfRequestToPropertyId[uint256(requestId)] = _propertyId;

    emit PropertyValuationRequested(_propertyId, uint256(requestId));

    return requestId;
}

    
    /**
     * @dev Fulfill Chainlink Functions request
     */
    function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        uint256 propertyId = vrfRequestToPropertyId[uint256(requestId)];
        
        if (err.length == 0) {
            uint256 newValuation = abi.decode(response, (uint256));
            propertyToken.updatePropertyValuation(propertyId, newValuation);
        }
    }
    
    /**
     * @dev Chainlink Automation upkeep check
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        // Check if any property needs monthly distribution
        for (uint256 i = 1; i < propertyToken.nextPropertyId(); i++) {
            PropertyFinances memory finances = propertyFinances[i];
            if (finances.autoDistributionEnabled && 
                finances.pendingDistribution > 0 &&
                block.timestamp >= finances.lastDistribution + 30 days) {
                upkeepNeeded = true;
                performData = abi.encode(i, "distribute");
                break;
            }
        }
    }
    
    /**
     * @dev Chainlink Automation upkeep perform
     */
    function performUpkeep(bytes calldata performData) external override {
        (uint256 propertyId, string memory action) = abi.decode(performData, (uint256, string));
        
        if (keccak256(bytes(action)) == keccak256(bytes("distribute"))) {
            _distributeYield(propertyId);
        }
    }
    
    /**
     * @dev Fulfill VRF request (for random property selection features)
     */
    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        // Implementation for random property selection features
        // Could be used for investment recommendations, fair launch mechanisms, etc.
    }
    
    /**
     * @dev Record property expense
     */
    function recordExpense(
        uint256 _propertyId,
        uint256 _amount,
        string memory _description
    ) external onlyPropertyOwner(_propertyId) {
        propertyFinances[_propertyId].totalExpenses += _amount;
        emit ExpenseRecorded(_propertyId, _amount, _description);
    }
    
    /**
     * @dev Set auto-distribution for a property
     */
    function setAutoDistribution(uint256 _propertyId, bool _enabled) external onlyPropertyOwner(_propertyId) {
        propertyFinances[_propertyId].autoDistributionEnabled = _enabled;
    }
    
    /**
     * @dev Get property financial data
     */
    function getPropertyFinances(uint256 _propertyId) external view returns (PropertyFinances memory) {
        return propertyFinances[_propertyId];
    }
    
    /**
     * @dev Get yield data for a property
     */
    function getYieldData(uint256 _propertyId) external view returns (YieldData memory) {
        return yieldData[_propertyId];
    }
    
    /**
     * @dev Emergency functions
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Update Chainlink parameters
     */
    function updateChainlinkParams(
        uint64 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        string memory _valuationSourceCode
    ) external onlyOwner {
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        callbackGasLimit = _callbackGasLimit;
        valuationSourceCode = _valuationSourceCode;
    }
    
    /**
     * @dev Withdraw accumulated fees
     */
    function withdrawFees(uint256 amount) external onlyOwner {
        require(address(this).balance >= amount, "Insufficient balance");
        payable(owner()).transfer(amount);
    }
    
    /**
     * @dev Receive function to accept Ether
     */
    receive() external payable {}
}