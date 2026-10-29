# Структура слотов в CompressedOracle

`CompressedOracleV1` упаковывает до **4 фидов** в один 256-битный storage-slot. Каждый фид занимает 48-битную «полосу» (lane), а нижние 64 бита зарезервированы под метаданные слота.

## Namespace и ключи

- База namespace: `namespace = uint256(uint160(creator)) << 96`.
- Ключ слота: `slotKey = bytes32(namespace | slotId)`, где `slotId` — `uint8`.
- Позиция фида: `positionIndex ∈ [0, 3]` — индекс полосы внутри слота.
- Идентификатор фида: `feedId = keccak256(abi.encodePacked(chainid, address(this), slotKey, positionIndex))`.

Только владелец namespace (или делегированный pusher через `namespaceRemapping`) может писать в свои слоты через `fallback`.

## Макет слота (big-endian)

```text
биты 255 … 208 : oracle[0] (48 бит)
биты 207 … 160 : oracle[1] (48 бит)
биты 159 … 112 : oracle[2] (48 бит)
биты 111 …  64 : oracle[3] (48 бит)
биты  63 …   8 : timestamp (uint56, unix milliseconds (миллисекунды))
биты   7 …   0 : reserved (в storage всегда 0)
```

Полоса фида содержит:

- `p` (32 бита) — цена в формате `U64x32` (`U64x32.decode`).
- `s` (8 бит) — индекс спреда в `Codebook256`.
- `v` (8 бит) — индекс волатильности в `Codebook256`.

## Состояние по умолчанию

При `createOracles` инициализируется **только** созданная полоса фида значением `DEFAULT_ORACLE_DATA_VALUE`:

- `p = 0`, `s = 0xFF`, `v = 0xFF` (трактуется как “unset”; при чтении спред/волатильность — `10_000`).

Несозданные полосы остаются нулевыми. `timestamp` при создании не выставляется.

## Обновления (Fallback / Signature)

Обновления полностью перезаписывают storage-slot.

- `fallback()` принимает `uint32 deadline` и далее один или несколько 32-байтовых «slot word».
- `updateBySignature()` принимает один «slot word», подписанный `feedCreator`, и может быть вызван любым адресом.

«Slot word» совпадает с макетом слота, но младший байт calldata используется под `slotId`:

```text
биты 255 …  64 : oracle[0..3]
биты  63 …   8 : timestamp (uint56, unix milliseconds (миллисекунды))
биты   7 …   0 : slotId (uint8; участвует в ключе; перед записью очищается)
```

Проверки:

- `timestamp` должен строго возрастать для каждого слота.
- `timestamp` не должен быть из будущего (`FutureTimestamp`).
- Для *текущего* (частично заполненного) слота все **несозданные полосы должны быть нулевыми**, иначе `UninializedPush`.
