# Шпаргалка по упаковке битов

## «Slot word» (32 байта)

`CompressedOracleV1` принимает 32-байтовые **slot word** как в `fallback()`, так и в `updateBySignature()`.

Формат slot word:

```text
bits 255 … 208 : oracle[0].p (32b) | oracle[0].s (8b) | oracle[0].v (8b)
bits 207 … 160 : oracle[1].p (32b) | oracle[1].s (8b) | oracle[1].v (8b)
bits 159 … 112 : oracle[2].p (32b) | oracle[2].s (8b) | oracle[2].v (8b)
bits 111 …  64 : oracle[3].p (32b) | oracle[3].s (8b) | oracle[3].v (8b)
bits  63 …   8 : timestamp (uint56, unix milliseconds (миллисекунды))
bits   7 …   0 : slotId (uint8)
```

Замечания:

- `p` — цена в формате `U64x32` (в storage хранится `uint32`).
- `s` / `v` — индексы в `Codebook256.TABLE` (декодируются в bps).
- `slotId` используется для вычисления storage-ключа, но **не сохраняется**: перед записью младший байт очищается.
- Контракт перезаписывает слот целиком: при апдейте одной полосы нужно передавать корректные значения и для остальных.

## Payload для `fallback` (off-chain → on-chain)

`fallback()` ожидает:

```text
[word0(32)][word1(32)]...
```

где каждый `wordN` — это slot word из секции выше.

## Payload для `updateBySignature` (off-chain → on-chain)

`updateBySignature(feedCreator, newSlotValue, signature)` ожидает `newSlotValue` в виде одного slot word (тот же формат), подписанного `feedCreator` по сообщению:

```text
keccak256(abi.encode(chainid, oracleAddress, feedCreator, newSlotValue))
```

## Обязательные проверки

- deadline на push-путях НЕТ: слово несёт собственный timestamp, replay гасится монотонностью.
- `timestamp` не должен быть из будущего (`FutureTimestamp` иначе).
- `timestamp` должен строго возрастать для каждого слота (старые апдейты игнорируются).
- Для *текущего* (частично заполненного) слота несозданные полосы должны быть нулевыми (`UninializedPush` иначе).
