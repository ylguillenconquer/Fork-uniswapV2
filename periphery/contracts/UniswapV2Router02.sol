pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint;

    address public immutable override factory;
    address public immutable override WETH;

    modifier ensure(uint deadline) { //modifier que se asegura de que no ha pasado demasiado tiempo
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory; //UniswapV2Factory.sol 
        WETH = _WETH; // WETH.sol, ETH que cumple con el estandar ERC20
    }

    receive() external payable {
        assert(msg.sender == WETH); // este contrato solo acepta ETH de la funcion fallback de WETH
    }

    // **** ADD LIQUIDITY ****
    // funcion internal
    function _addLiquidity(
        address tokenA, //direccion del token A
        address tokenB, //direccion del token B
        uint amountADesired, //cantidad de A que el usuario quiere agregar
        uint amountBDesired, //cantidad de B que el usuario quiere agregar
        uint amountAMin, //cantidad minima de A que el usuario esta dispuesto a agregar
        uint amountBMin ////cantidad minima de B que el usuario esta dispuesto a agregar
    ) internal virtual returns (uint amountA, uint amountB) {
        // si no existe el par, crea el par llamando al Factory
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        //calculamos las reservas de los tokens del pool
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);

        if (reserveA == 0 && reserveB == 0) {
            //Si no hay nada en el pool, se devuelve la cantidad 'deseada' de cada token
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else { //si hay liquidez en el pool calculamos con quote
       // quote calcula, dada una cantidad de tokens, la cantidad equivalente del otro token
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                //Si es menos que la cantidad deseada, debe ser al menos mayor que la minima aceptada
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else { //si no, se calcula lo mismo con el otro token
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    //Funcion external
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline //momento limite en el que se debe ejecutar la transaccion
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        //Llama a la funcion internal para añadir liquidez
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        //pairFor saca la dirección del par (pool)
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //TransferHelper.sol es una libreria para facilitar transferencias de tokens ERC20.
        //Aqui se esta enviando la cantidad de cada token a la direccion del pool
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        //Se crean LP tokens para el usuaior que agrega liquidez
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline //momento limite en el que se debe ejecutar la transaccion
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
       //Se llama a la funcion internal pero esta vez con los datos de  WETH
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        //se obtiene la direccion del par
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        //se transfiere la cantidad de Token al pool
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        //deposit() sirve para depositar ETH en el contrato y recibir WETH
        IWETH(WETH).deposit{value: amountETH}();
        //Transfiere despues esa cantidad al par
        assert(IWETH(WETH).transfer(pair, amountETH));
        //Se crean los LP tokens
        liquidity = IUniswapV2Pair(pair).mint(to);
        // Se devuelve al usuario la cantidad que sobre de ETH
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity, //liquidez que se quiere retirar
        uint amountAMin, //cantidad minima de tokens que el usuario espera recibir del token A
        uint amountBMin, //cantidad minima de tokens que el usuario espera recibir del token B
        address to,
        uint deadline //momento limite en el que se debe ejecutar la transaccion
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        //Se obtiene la direccion del par
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //se envian los LP tokens al pool
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        //Se queman los tokens y se obtiene la cantidad correspondiente de cada token
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to); 
        //se ordenan estos tokens
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        //Esta linea es una sentencia condicional que significa que si tokenA = token0, amount A = amount 0
        // y tokenB = token1 y amountB=amount1 (Si no, alreves)
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        //Se comprueba que se extraen cantidades mayor o igual que las minimas exigidas
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {

        //llama a la funcion remove liquidity con los datos de ETH. En este caso, la direccion to es la de este contrato
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), //
            deadline
        );
        //Se transfieren los tokens a la direccion to
        TransferHelper.safeTransfer(token, to, amountToken);
        //se sacan los ETH correspondientes y despues se transfieren a la direccio to
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, //booleano que indica si el usuario aprueba el gasto maximo de tokens o no. 
        //Si es false solo se aprueba el gasto de la cantidad de liquidez especificada
        uint8 v, bytes32 r, bytes32 s //firma para el permiso
    ) external virtual override returns (uint amountA, uint amountB) {

        //se obtiene la direccion del par
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        //Se verifica la valor de approveMax y se establece la cantidad de tokens que se pueden gastar
        uint value = approveMax ? uint(-1) : liquidity;
        //Se llama a la funcion permit, que basicamente permite que el owner de los tokens de permisos 
        //al contrato de Uniswap gestiones los tokens de liquidez en su nombre
        //Se parece a approve pero aqui por ejemplo usamos la firma
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //Finalmente se llama a removeLiquidity (funcion explicada mas arriba)
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        //Se obtiene la direccion del par
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        //Se verifica la valor de approveMax y se establece la cantidad de tokens que se pueden gastar
        uint value = approveMax ? uint(-1) : liquidity;
        //Se llama a la funcion permit para darle permisos a la direccion del contrato a que gestione los tokens de liquidez
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //Se llama a la funcion removeLiquidity para retirar la liquidez
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****

    // Esto es para tokens ERC20 que imponen una tarifa o comision en cada transaccion que involucra al token
    //En esta funcion se incluye la cantidad minima de tokens y de ETH que el usuario desea recibir, asi que hacer la funcion de esta forma
    //ayuda a que el usuario reciba minimo esta cantidad a pesar de la comision
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        //Se llama a removeLiquidity para retirar la liquidez y se envia a la direccion del contrato
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this), 
            deadline
        );
        //Se  transfiere a la direccion to los tokens del contrato
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        //Se extraen y se transfieren los ethers a la direccion to
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    //Igual que la funcion anterior pero con Permit
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        //Se obtiene la direccion del par
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        //Se verifica la valor de approveMax y se establece la cantidad de tokens que se pueden gastar        
        uint value = approveMax ? uint(-1) : liquidity;
        //Se llama a permit para darle permisos al contrato para que gestione los tokens de liquidez
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        //Se llama a la funcion anterior para retirar la liquidez
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair

    //Funcion interna que realiza el swap 

    /* EXPLICACION DEL ARRAY PATH
    Este array es como la 'ruta' que se sigue para hacer el swap. 
    Si por ejemplo nosotros queremos intercambiar el token X por el token Z, path contendrá lo siguiente: 
    [X, Y, Z]
    Siendo X y Z las direcciones de los tokens y la direccion Y seria la del token intermedio.

    Cuando se desea intercambiar un token por otro en UniswapV2, es posible que no haya un par de intercambio directo entre los 
    dos tokens. 
    En este caso, se puede utilizar un token intermedio que se intercambia por el token de entrada y luego se intercambia por 
    el token de salida deseado.
     */
    function _swap(
        uint[] memory amounts, //array con las cantidades de tokens para hacer el swap
        address[] memory path, //array con las direcciones de los tokens
        address _to) 
        internal virtual {
        for (uint i; i < path.length - 1; i++) { //Se itera el array path
            //Se separan los tokens de entrada y de salida
            (address input, address output) = (path[i], path[i + 1]); 
            //Se halla la direccion de token0 ordenandolos con sortTokens
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            //En esta sentencia condicional se asignan de forma correcta la cantidad de cada token a su direccion
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            //Se calcula la direccion to de la siguiente manera:
            //Si el indice es menor que el tamaño de path menos 2, to se calcula con la funcion pairFor de UniswapV2Library
            //Si esto no se cumple, se usa el parametro de entrada _to. Esto sucede porque ya no quedan mas direcciones en path
            //asi que el intercambio ha llegado a su fin, y ya los tokens se transfieren a la direccion especificada _to
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            //Despues se hace el swap llamando a la funcion del contrato UniswapV2Pair
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    //Intercambio de Tokens
    function swapExactTokensForTokens(
        uint amountIn, //cantidad de tokens que se desea intercambiar
        uint amountOutMin, //cantidad minima de tokens que se espera recibir
        address[] calldata path, //array con las direcciones de los tokens 
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        //Se obtiene el array que contiene los montos de cada token usando la funcion de getAmountsOut 
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        //Es necesario que este monto del token de salida obtenido supere la cantidad minima exigida, si no se revierte la tx
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        //Si se cumple, se transfieren los tokens de entrada a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );

        //Se llama a la funcion interna _swap (comentada anteriormente) para realizar el intercambio
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax, //cantidad maxima de tokens de entrada que el usuario esta dispuesto a intercambiar
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        //Se obtiene el array que contiene los montos de cada token usando la funcion de getAmountsOut 
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        //En este caso se comprueba que el monto no supera el maximo que se esta dispuesto a intercambiar
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        //Si se cumple, se transfieren los tokens de entrada a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        //Se realiza el swap
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        //Se comprueba que el inicio dla 'ruta' es la direccion correcta de WETH
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se obtienen los montos de cada token
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
         //Es necesario que este monto del token de salida obtenido supere la cantidad minima exigida, si no se revierte la tx
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        //Si se cumple se deposita la cantidad especificada de ETH para extraer WETH y poder operar
        IWETH(WETH).deposit{value: amounts[0]}();
        //se transfieren los WETH al contrato del par
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        //Se llama a _swap para hacer el intercambio
        _swap(amounts, path, to);
    }
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        //Se comprueba que la direccion de WETH se encuentra en la posicion correcta de la 'ruta'
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se obtienen las cantidades de cada token
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        //En este caso se comprueba que el monto no supera el maximo que se esta dispuesto a intercambiar
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        //Si se cumple, se transfieren los tokens de salida a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        //Se realiza el swap
        _swap(amounts, path, address(this));
        //se extraen los ETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        //Se envian estos ETH a la direccion de destino
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        //Se comprueba que la direccion de WETH se encuentra en la posicion correcta de la 'ruta'
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se obtienen los montos de cada token
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        //Es necesario que este monto del token de salida (WETH) obtenido supere la cantidad minima exigida, si no se revierte la tx
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        //Se transfieren los tokens de entrada a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        //Se hace el swap
        _swap(amounts, path, address(this));
        //Se intercambian los WETH por WETH
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        //Se transfieren a la direccion de destino
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        //Se comprueba que el inicio de la 'ruta' es la direccion correcta de WETH
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se obtienen los montos de cada token
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        //Se asegura de que tiene balance suficiente para la cantidad de ETH que se quiere cambiar 
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        //Si se cumple se cambian los ETH por WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        //Se transfieren a la direccion del contrato
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        //Se realiza el swap
        _swap(amounts, path, to);
        //Si 'sobran' ethers despues del swap, se transfieren de vuelta
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }





    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair

    //Funciones que permiten hacer swap con tokens que tienen una tarifa de transferencia incorporada
    //Se aseguran de que apesar de esta tarifa, se reciban los tokens minimos exigidos
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) { //recorremos la 'ruta'
            //Se hallan las direcciones de entrada y salida utilizando path
            (address input, address output) = (path[i], path[i + 1]);
            //Se halla la direccion del 'primer token' 
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            //Se obtiene el swap
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;

            { // scope to avoid stack too deep errors

            //Se obtienen las reservas del pool
            (uint reserve0, uint reserve1,) = pair.getReserves();
            //Se calculan las reservas de cada token con esta sentencia condicional 
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            //Se obtienen la cantidad de tokens de entrada y de salida del par
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            //Se determina el valor de entrada y salida de los dos tokens
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            //Si el tamaño de path menos dos es menor que i, la direccion to será la del par, y sino, sera la de destino
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            //Se llama a la funcion swap del contrato del par
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        //Se transfieren los tokens de entrada a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        //Se obtiene el saldo del ultimo token de la ruta en la direccion to
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        //Se realiza el intercambio de tokens
        _swapSupportingFeeOnTransferTokens(path, to);
        //Se verifica que se haya obtenido la cantidad minima de tokens de salida despues del intercambio
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        //Se asegura de que la ruta comienza en la direccion de WETH
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se halla la cantidad de tokens de entrada
        uint amountIn = msg.value;
        //Se cambian ETH por WETH
        IWETH(WETH).deposit{value: amountIn}();
        //Se transfieren estos WETH al par de intercambio
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        //Se obtiene el sald del ultimo token en la ruta en la direccion to
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        //Se realiza el intercambio de tokens
        _swapSupportingFeeOnTransferTokens(path, to);
         //Se verifica que se haya obtenido la cantidad minima de tokens de salida despues del intercambio
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        //Se comprueba que la direccion de WETH se encuentra en la posicion correcta de la 'ruta'
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        //Se transfieren los tokens de entrada a la direccion del par
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        //Se realiza el swap pero con direccion de destino la de este contrato
        _swapSupportingFeeOnTransferTokens(path, address(this));
        //Se calcula la cantidad de WETH de salida 
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        //Se comprueba que esta cantidad es igual o superior a la exigida
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        //Se cambian estos WETH por ETH
        IWETH(WETH).withdraw(amountOut);
        //Se transfieren estos ETH a la direccion de destino
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
