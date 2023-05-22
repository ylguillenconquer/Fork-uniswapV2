const Factory = artifacts.require("UniswapV2Factory.sol");
const Token1 = artifacts.require("Token1.sol");
const Token2= artifacts.require("Token2.sol");
module.exports = async function (deployer, network, addresses) {
  await deployer.deploy(Factory, addresses[0]); //envia la transaccion para desplegar el contrato
  const factory = await Factory.deployed(); //necesitamos tener una referencia 

  let token1addr, token2addr;
  if (network=='mainnet') {
    token1addr = '';
    token2addr = '';
  } else 
  {
    await deployer.deploy(Token1);
    await deployer.deploy(Token2);
    const erc20_1 = await Token1.deployed();
    const erc20_2 = await Token2.deployed();
    token1addr = erc20_1.address;
    token2addr = erc20_2.address;

  }



  await factory.createPair(token1addr, token2addr);
};
