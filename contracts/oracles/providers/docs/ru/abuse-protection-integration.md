# Предложение: интеграция пула и фабрики со слоем защиты от абьюза оракула

Статус: черновик / на ревью
Область: изменения в **AMM-пуле** и **фабрике AMM-пулов** для использования read-пути защиты от
абьюза, уже реализованного в `contracts/oracles/providers/OracleBase.sol`. Сторона price-provider
уже реализована как `ProtectedPriceProvider` / `ProtectedPriceProviderL2` (см. §4).

---

## TL;DR

- **Что уже есть:** оракул (`OracleBase`, общий для Pyth/Chainlink) имеет слой защиты от абьюза —
  платная регистрация пула, блеклист, событие `PriceRead` и атрибутируемое чтение
  `price(feedId, pool)`. Менять оракул не нужно. **Сторона price-provider тоже готова** —
  отдельные `ProtectedPriceProvider` / `ProtectedPriceProviderL2` (только атрибутируемое чтение — см. §4).
- **Что надо доделать на стороне AMM** (этот документ):
  - **Фабрика** реализует `IPoolFactory`: только `isPool(address)` (+ событие `PoolCreated`). Оракул
    обращается к ней **только на регистрации**.
  - **Пул** экспонирует `inSwap()` (transient — провайдер, через которого он читает) и non-view
    `getBidAndAskPrice()`, который помечает себя in-swap и зовёт
    `ProtectedPriceProvider.getBidAndAskPrice()` (без аргументов); `swap()` идёт этим же путём.
  - (**Price provider** на стороне AMM ничего не требует — `ProtectedPriceProvider` / `…L2` уже
    готовы; достаточно направить пул на один из них и `register`-нуть. См. §4.)
- **Доступ:** on-chain чтение — **только** через `price(feedId, pool)` (пулы) или `integratorPrice`
  (вайтлист интеграторов): нужна регистрация пула и отсутствие блеклиста. Публичные геттеры
  `getOracleData` / `getOracleDataBulk` / `price(bytes32)` **отключены** (ревертят `ReadDisabled`);
  off-chain читают сырое хранилище / события, не Solidity-геттер.
- **Экономика:** блеклист = отзыв доступа; повторный `register` = искупление (платная). Поднять
  `registrationFee`, если появятся абьюзеры.
- **Безопасность:** in-swap маркер живёт **на пуле** — пул может пометить только себя, поэтому не может
  подставить чужой пул. Провайдер форвардит своего **реального вызывающего** (`msg.sender`) как пул, а
  оракул связывает чтение через `pool.inSwap() == provider`. Фабрика используется только на `register`
  (через `isPool` + набор одобренных фабрик), на read-пути — никогда.

---

## 1. Контекст

Оракул-провайдер (`OracleBase`, наследуется `PythOracle` и `ChainlinkOracle`) содержит слой
read-доступа / защиты от абьюза: ончейн-*потребление* цены требует зарегистрированного, не-блеклистнутого
пула, каждое такое чтение атрибутируется событием, а мейнтейнер может заблеклистить абьюзеров, которые
восстанавливаются только повторной оплатой регистрационной комиссии.

Что уже есть на оракуле (доп. изменений оракула не требуется):

```solidity
interface IPoolFactory { function isPool(address pool) external view returns (bool); }     // валидируется на register
interface IPool        { function inSwap() external view returns (address priceProvider); } // запрашивается на чтении

// OracleBase (providers)
function price(bytes32 feedId, address pool)
    external returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime); // non-view, эмитит PriceRead
function register(bytes32 feedId, address pool, address factory) external payable;       // платит комиссию, вайтлистит пул, снимает блеклист
function addApprovedFactory(address factory) external; // ADMIN
function blacklisted(address) external view returns (bool);
function registrationFee() external view returns (uint256);
event PriceRead(address indexed reader, bytes32 indexed feedId);
```

Оракул аутентифицирует чтение пула так:

1. price provider пула зовёт `oracle.price(feedId, pool)`, форвардя пул (своего `msg.sender`);
2. оракул требует `pool != 0` и `IPool(pool).inSwap() == msg.sender` (вызывающий провайдер) — пул
   должен был пометить себя in-swap именно с этим провайдером;
3. оракул требует `!blacklisted[pool]` и `registeredPool[feedId][pool]` (пул оплатил регистрацию для фида);
4. оракул читает данные и эмитит `PriceRead(pool, feedId)`.

Части, всё ещё за стороной AMM:

- **фабрика**, реализующая `isPool` (чтобы оракул валидировал пул на `register`);
- **пул**, экспонирующий `inSwap()` и `getBidAndAskPrice()`, который помечает себя in-swap со своим
  провайдером и читает через готовый `ProtectedPriceProvider`.

Часть price-provider готова: `ProtectedPriceProvider` / `ProtectedPriceProviderL2` читают оракул
исключительно через атрибутируемое `price(feedId, pool)`, форвардя своего вызывающего (см. §4).

Providers-оракул **отключает** публичные геттеры (`getOracleData` / `getOracleDataBulk` /
`price(bytes32)` ревертят `ReadDisabled`): единственное ончейн-чтение — атрибутируемое
`price(feedId, pool)` (пулы) / `integratorPrice` (интеграторы). Легаси `PriceProvider`, читавший через
`getOracleData`, поэтому больше не может читать providers-оракул ончейн — полностью заменён на
`ProtectedPriceProvider`.

---

## 2. Изменения фабрики (`IPoolFactory`)

Фабрика AMM-пулов должна отслеживать созданные пулы и предоставлять проверку членства. Достаточно
простого `mapping` — public-геттер уже удовлетворяет `IPoolFactory.isPool`; on-chain перечисление не
нужно (оракул зовёт только `isPool(address)` на регистрации; off-chain список обеспечивает `PoolCreated`):

```solidity
mapping(address => bool) public isPool; // public-геттер == IPoolFactory.isPool(address) -> bool

// при создании пула:
isPool[pool] = true;
emit PoolCreated(pool, ...);
```

`oracle.register(feedId, pool, factory)` использует это (против ADMIN-одобренной фабрики) для валидации
«это настоящий пул одобренной фабрики». **На read-пути фабрика не участвует** — in-swap аттестация живёт
на пуле (§3).

---

## 3. Изменения пула (`MetricOmmPool`)

**Пул владеет in-swap маркером** и экспонирует собственный `getBidAndAskPrice()` («проброшенная» точка
входа). Он помечает себя in-swap со своим провайдером непосредственно перед чтением и зовёт провайдер
**без аргументов**; `swap()` идёт тем же путём. Любое чтение через пул атрибутируется на пул (оракул
эмитит `PriceRead(pool, feedId)`).

```solidity
// transient-слот (Solidity >=0.8.24, evm_version = prague — уже задан в foundry.toml)
address transient private _inSwapPriceProvider;

/// @notice Запрашивается оракулом для привязки чтения к вызывающему провайдеру (0 вне свапа).
function inSwap() external view returns (address) {
    return _inSwapPriceProvider;
}

/// @notice Проброшенная точка входа — non-view (пишет transient-маркер, оракул эмитит).
function getBidAndAskPrice() public returns (uint128 bid, uint128 ask) {
    _inSwapPriceProvider = PRICE_PROVIDER;                       // пометить себя in-swap с провайдером
    return IPriceProvider(PRICE_PROVIDER).getBidAndAskPrice();   // без аргументов; см. §4
}
```

В существующем месте чтения в свапе (`var/MetricOmmPool.sol:565`) читать цену через собственный
`getBidAndAskPrice()` пула, а не вызывать провайдер напрямую.

Заметки:

- Пул передаёт провайдеру **ничего**; провайдер форвардит пул (своего `msg.sender`) в оракул, а оракул
  запрашивает `pool.inSwap()` и связывает его с этим провайдером.
- `getBidAndAskPrice()` — **non-view** (пишет transient-маркер, оракул эмитит событие).
- **Используйте transient storage (EIP-1153)** для `_inSwapPriceProvider`: авто-очистка в конце tx, так
  что устаревший маркер не протечёт в более поздний несвязанный вызов; reentrancy-safe и дёшево. Для
  последовательных свапов в одной tx (мульти-хоп роутер) каждый пул заново выставляет свой маркер прямо
  перед своим чтением.
- Никакого постоянного состояния, ручной очистки и доп. reentrancy-guard сверх существующего swap-guard.

Пул должен быть `register`-нут на оракуле для своего фида, чтобы использовать этот on-chain путь (см. §5).

---

## 4. Price provider — реализован (`ProtectedPriceProvider` / `ProtectedPriceProviderL2`)

Сторона провайдера **уже реализована** двумя самостоятельными контрактами —
`contracts/ProtectedPriceProvider.sol` (L1) и `contracts/ProtectedPriceProviderL2.sol` (L2),
пригодными и для Pyth, и для Chainlink. Они читают **исключительно** через атрибутируемый non-view путь;
открытого `getOracleData` / `view`-геттера цены на них **нет**. Существующие `PriceProvider` /
`PriceProviderL2` **не тронуты в исходниках**, но поскольку оракул отключил публичные геттеры, на которые
они опирались, они больше не могут читать providers-оракул ончейн — полностью заменены здесь.

Единственная точка чтения — non-view и **без аргументов**, форвардит `msg.sender` (вызывающий пул):

```solidity
// contracts/ProtectedPriceProvider.sol — единственная точка чтения
function getBidAndAskPrice() external returns (uint128 bid, uint128 ask) {
    (bid, ask) = _getBidAndAskPrice();
    if (bid == 0 || ask == type(uint128).max) revert FeedStalled();
}
```

Атрибутируемое чтение оракула объявлено в собственном минимальном интерфейсе
(`contracts/interfaces/IPricedOracle.sol`) — отдельно от `IOffchainOracle`, чтобы существующие
реализации (compressed-оракул, моки) не были обязаны его реализовывать:

```solidity
interface IPricedOracle {
    function price(bytes32 feedId, address pool)
        external returns (uint256 mid, uint256 spread, uint16 spread1, uint256 refTime);
}

// внутри ProtectedPriceProvider — форвардит пул (msg.sender) в оракул
function _getBidAndAskPrice() internal returns (uint128, uint128) {
    (uint256 mid, uint256 spread,, uint256 refTime) =
        IPricedOracle(address(offchainOracle)).price(offchainFeedId, msg.sender);
    return _computeBidAsk(mid, spread, refTime); // staleness / guard / CL-deviation / spread / marginStep
}
```

Заметки:

- Провайдер форвардит `msg.sender` (пул, который его вызвал) как атрибутируемого читателя — его нельзя
  подделать для подставления чужого пула, т.к. провайдер всегда сообщает своего реального вызывающего.
- Вся нижележащая логика ценообразования (staleness, price guard, confidence-spread,
  marginStep, инвариант `bid < ask`) **идентична** легаси `PriceProvider` и живёт в общем хелпере
  `_computeBidAsk(mid, spread, refTime)` — изменился только источник данных.
- `getBidAndAskPrice()` — **non-view** (оракул эмитит `PriceRead` и применяет блеклист/регистрацию на
  уровне пула).
- **L2 (`ProtectedPriceProviderL2`)**: то же самое, но принимает `FUTURE_TOLERANCE` в конструкторе и
  использует L2-aware проверку staleness, допускающую `refTime` оракула чуть впереди `block.timestamp`.
- `view`-ветки на этих контрактах **нет**, и публичные геттеры оракула тоже отключены; off-chain
  потребители читают сырое хранилище / события / индексер.

---

## 5. Жизненный цикл регистрации и блеклиста

- **On-chain чтение пулов ТРЕБУЕТ регистрации.** `price(feedId, pool)` требует
  `registeredPool[feedId][pool]` — пул должен быть зарегистрирован (оплачен) для этого фида и не быть
  в блеклисте, чтобы использовать атрибутируемый on-chain путь.
- **Off-chain чтение остаётся бесплатным.** Агрегаторы/арбитражёры и дашборды читают сырое хранилище /
  события / индексер — ончейн Solidity-геттера для вызова нет (`getOracleData` / `getOracleDataBulk` /
  `price(bytes32)` ревертят `ReadDisabled` для всех). Это и есть экономическая модель: ончейн-*потребление*
  цены требует зарегистрированного пула; пассивное off-chain-наблюдение бесплатно и неустранимо в
  публичной сети.
- **Регистрация (`register{value}(feedId, pool, factory)`)** записывает пул в per-feed вайтлист
  (`registeredPool`), принимает комиссию и **снимает блеклист с пула**. Переплата НЕ возвращается.
  `register` пермишенлесс (платить за валидный пул может кто угодно) и валидирует пул через `isPool`
  одобренной фабрики. Это также путь *восстановления* из блеклиста.
- **Экономический сдерживатель.** `registrationFee` по умолчанию `1 wei` — намеренно минимальный пока;
  поднять через `setRegistrationFee`, если появятся абьюзеры. Абьюз → мейнтейнер блеклистит пул
  (наблюдая по событиям `PriceRead`) → восстановление требует снова заплатить комиссию.
- **Кто платит / вывод средств.** Деплоер пула один раз вызывает `register`. Накопленный ETH ADMIN
  выводит целиком через `withdrawEth` — снятие всего баланса (комиссии плюс любой операционный резерв)
  намеренно.

---

## 6. Сквозной поток свапа

```
EOA → MetricOmmPool.swap()
        MetricOmmPool → MetricOmmPool.getBidAndAskPrice()                // проброшенная точка входа пула
            MetricOmmPool: _inSwapPriceProvider = PRICE_PROVIDER         // пометить себя in-swap (transient)
            MetricOmmPool → ProtectedPriceProvider.getBidAndAskPrice()   // без аргументов
                              ProtectedPriceProvider → oracle.price(offchainFeedId, MetricOmmPool)  // форвардит msg.sender (пул)
                                oracle: require(pool != 0 && IPool(pool).inSwap() == msg.sender)    // pool.inSwap() == provider
                                oracle: require(!blacklisted[pool])
                                oracle: require(registeredPool[offchainFeedId][pool])
                                oracle: emit PriceRead(pool, offchainFeedId)
                          ProtectedPriceProvider применяет spread / staleness / guard / CL-deviation
        ← bid/ask
        (transient in-swap маркер авто-очищается в конце tx)
```

Off-chain / агрегаторы читают сырое хранилище / события / индексер; публичные геттеры отключены, поэтому
ни один контракт не может потребить цену ончейн без зарегистрированного пула.

---

## 7. Соображения безопасности

- **In-swap маркер живёт на пуле**: `getBidAndAskPrice()` выставляет `_inSwapPriceProvider` только для
  себя — пул никогда не может пометить чужой пул, поэтому чтение нельзя атрибутировать/заблеклистить на
  пул, который его не выполнял. (Кросс-пульного `setInSwap`, который можно было бы абьюзить, нет.)
- **Провайдер форвардит своего реального вызывающего**: провайдер передаёт свой `msg.sender` (пул) в
  оракул, поэтому его нельзя обмануть, заставив читать «как» другой пул.
- **Привязка вызывающего в оракуле** (`pool.inSwap() == msg.sender`): чтение валидно, только если пул
  объявил in-swap именно этого провайдера. Атакующий, вызывающий `oracle.price(feed, V)` напрямую (для
  некоторого зарегистрированного пула `V`), не пройдёт: `V.inSwap()` вернёт реального провайдера `V` —
  или `0` вне собственного свапа `V` — но не атакующего.
- **Фабрика только на регистрации**: пул можно зарегистрировать, только если `isPool` ADMIN-одобренной
  фабрики его признаёт; read-путь фабрику не запрашивает. *Заметка:* `removeApprovedFactory` блокирует
  новые регистрации, но не чтения уже зарегистрированных пулов этой фабрики — при необходимости их
  блеклистить.
- **Transient-маркер**: нет утечки между вызовами/транзакциями; нет окна reentrancy, т.к. маркер
  выставляется и потребляется в рамках одной синхронной цепочки вызовов.
- **Общий price provider**: один `ProtectedPriceProvider` может обслуживать много пулов; оракул резолвит
  и блеклистит **пул** (форварднутый `msg.sender`), а не общий провайдер, поэтому блеклист одного пула
  не ломает остальные.
- **Мульти-хоп роутеры**: каждый пул заново выставляет свой маркер прямо перед своим чтением;
  последовательные чтения в одной tx видят каждый свой пул.

---

## 8. Обратная совместимость и миграция

- Существующие `PriceProvider` / `PriceProviderL2` **не тронуты в исходниках** — их
  `getBidAndAskPrice()` продолжает работать для off-chain интеграций,
  но ончейн они больше не могут читать providers-оракул (геттеры, которые они использовали, отключены).
  Атрибутируемый путь — **отдельная** пара контрактов (`ProtectedPriceProvider` /
  `ProtectedPriceProviderL2`), поэтому переход opt-in по каждому пулу: направить пул на защищённый
  провайдер, добавить пулу `inSwap()` и `register`-нуть; ничто не форсит миграцию существующих деплоев.
- Существующие пулы, не принявшие `inSwap()`, будут падать на `oracle.price(feed, pool)` с
  `InvalidInSwap` до апгрейда. Апгрейд пула и вызов `addApprovedFactory` планировать вместе.

---

## 9. Открытые вопросы / решения

1. **Доставка адреса пула/фабрики — решено.** Пул передаёт провайдеру **ничего**; провайдер форвардит
   пул (своего `msg.sender`), поэтому никакой адрес фабрики/пула не нужно протаскивать через вызов.
   Фабрика упоминается только на `register`.

---

## 10. План тестирования (сторона AMM)

- Фабрика: членство `isPool`; off-chain список через `PoolCreated`.
- Пул: `inSwap()` возвращает провайдер во время чтения и `0` иначе (transient авто-очистка между
  вызовами); `swap` помечает in-swap, затем читает; своп заблеклистенного пула ревертит
  `Blacklisted(pool)`; незарегистрированный пул — `NotRegistered(feedId, pool)`.
- ProtectedPriceProvider: `getBidAndAskPrice()` даёт паритет с вычислением легаси `PriceProvider` для
  чистого пула и эмитит `PriceRead(pool, feedId)`; ревертит `FeedStalled` на sentinel `(0, max)`.
- Спуфинг: контракт `X`, вызывающий `oracle.price(feed, V)` для зарегистрированного пула `V`, ревертит
  `InvalidInSwap` (т.к. `V.inSwap() != X`); чтение `X` «как себя» всё равно требует, чтобы `X` был
  зарегистрированным пулом, чей `inSwap()` возвращает вызывающий провайдер.
- Восстановление: заблеклистить пул → своп ревертит → `register{value: fee}` → своп снова проходит.
