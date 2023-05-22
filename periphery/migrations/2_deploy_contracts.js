const Router = artifacts.require("UniswapV2Router02.sol");
const WETH = artifacts.require("WETH.sol");

module.exports = async function (deployer, network, addresses) {
    const FACTORY = '';
    let wETH;
    let WETHaddr;
    if(network=='mainnet') {
        wETH = await WETH.at('0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2');
    } else {
        await deployer.deploy(WETH);
        wETH = await WETH.deployed();
        WETHaddr = wETH.address;
    }

    await deployer.deploy(Router, FACTORY, WETHaddr)
};
