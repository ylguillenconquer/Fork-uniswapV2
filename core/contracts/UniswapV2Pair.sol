pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';
 
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3; //representa la cantidad minima de liquidez que se puede crear en una nueva pool
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));//Se usa para llamar a la funcion transfer del ERC20

    address public factory; //Direccion del contrato factory
    address public token0; //Direccion del contrato del token 0
    address public token1;  //Direccion del contrato del token 1

    uint112 private reserve0;  //CANTIDAD DE TOKEN 0 EN EL POOL         // uses single storage slot, accessible via getReserves
    uint112 private reserve1;  //CANTIDAD DE TOKEN 1 EN EL POOL       // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; //MARCA DE TIEMPO DEL ULTIMO BLOQUE EN EL QUE SE ACTUALIZO LA INFO DE LAS RESERVAS DEL POOL // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast; //VARIABLE QUE ALMACENA EL PRECIO ACUMULATIVO DEL TOKEN0
    uint public price1CumulativeLast; //VARIABLE QUE ALMACENA EL PRECIO ACUMULATIVO DEL TOKEN1
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event
    /**
        Los precios acumulativos se calculan como la suma de todos los precios instantaneos (en terminos del token contrario), 
        multiplicados por el numero de segundos que han transcurrido desde la ultima actualizacion de reservas.

        Pensad que los precios de los tokens en un pool varían (ademas de por el mercado), por la cantidad de liquidez. 
        El precio que pagas por cada token depende de la cantidad del otro token, por asi decirlo. De esta forma el protocolo se asegura
        de que nadie vacie el pool. Si alguien quisiera vaciar un pool de uno de los tokens, el precio tenderia a infinito
    **/

    //Variable y modifier que sirven para prevenir llamadas simultaneas a funciones que puedan interferir entre si
    uint private unlocked = 1; 
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }
    //Funcion que devuelve las reservas que tiene el pool de cada token, y el ultimo momento en el que se actualizaron
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    //Funcion privada que usa el SELECTOR para llamar a la funcion transfer del ERC20 para enviar a la direccion 'to', una cantidad 'value' de 'token'
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    //El contrato UniswapV2Factory es el que despliega los contratos de cada pool, por eso es el msg.sender
    constructor() public {
        factory = msg.sender;
    }

    //Funcion que inicializa las direcciones de cada token cuando se crea el pool
    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    //Actualiza los valores de las reservas de liquidez y los precios acumulativos de los tokens
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        //Se comprueba que los balances son menores o iguales que el valor maximoque puede almacenar uint112 (uint112(-1))
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW'); 
        //Se calcula el tiempo transcurrido entre la ultima actualizacion
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //Si este tiempo es mayor que cero y las reservas no son cero, se calculan los precios acumulativos
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        //Se calculan las reservas y el ultimo momento en el que se han actualizado
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    //funcion para calcular y cobrar una tarifa de liquidez sobre las transacciones del protocolo de Uniswap
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo(); //Se obtiene del Factory la direccion que va a recibir esas tarifas
        feeOn = feeTo != address(0); //Se establece feeOn en funcion del valor de feeTo (Si no es la direccion 0, estan activadas las tasas)
        uint _kLast = kLast; // gas savings
        if (feeOn) { //Si estan activadas las tasas
            if (_kLast != 0) {
                /* Si la raiz cuadrada actual es mayor que la raiz cuadrada anterior, significa que el volumen de transacciones 
                ha aumentado y se ha generado una nueva tarifa de liquidez. En ese caso, la funcion calcula la cantidad de tokens 
                de liquidez que se deben crear y se los asigna al destinatario de la tarifa. */
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1)); 
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity); //Si la liquidez es mayor que cero se mintean LP tokens a la direccion feeTo
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        //Se calculan las reservas de cada token. Esta funcion devuelve un tercer valor pero por ahorro de gas, no se extrae
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        //Se obtienen las cantidades actuales de cada token que se estan intercambiando
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        //Se calcula la cantidad de cada token que se agregara a la reserva
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);
        //Se calcula la cantidad de comision que se cobra con _mintFee
        bool feeOn = _mintFee(_reserve0, _reserve1);

        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
       //Si el total Supply es cero
        if (_totalSupply == 0) {
            //Se calculan la cantidad de tokens a emitir
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //Se envia una cantidad minima de tokens a la direccion 0x0 para  asegurar que siempre haya un suministro minimo de tokens en circulacion
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            //Si no es cero se calcula la liquidez teniendo en cuenta las reservas
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }

        //Se asegura de que la liquidez es mayor que cero
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        //Se mintean los LP tokens a la direccion de destino
        _mint(to, liquidity);
        //Se actualizan las reservas
        _update(balance0, balance1, _reserve0, _reserve1);
        //Si se cobro la transaccion, se calcula de nuevo kLast
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    //Funcion para quemar tokens de liquidez para retirar los fondos de un pool
    
    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
