const BuybackNFT = artifacts.require("BuybackNFT");

module.exports = function (deployer) {
  deployer.deploy(
    BuybackNFT,
    [
        "0xddFC8347A32107eE5CE4825C5a2c4753Bcd580eb", 
        "0x9972C48FBdeB6044A4075e19345F734AcC03f84D", 
        "0xb3ED329E26B3867b7161c5614EB6385e471A80e1", 
        "0xcb41c104eFFF7962DB8CEB42Da0f0E84b80C11e1"
    ],
    [292, 236, 236, 236],
    "0xF57B2c51dED3A29e6891aba85459d600256Cf317",
    "0xDEADBEEF"
  );
};