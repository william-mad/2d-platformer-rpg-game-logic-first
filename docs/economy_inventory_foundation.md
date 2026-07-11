# Economy inventory foundation

This foundation separates immutable item descriptions from mutable inventory state. `ItemDefinition` resources contain catalog metadata such as names, tags, values, stack hints, weight, and food properties. `InventoryModel` stores only runtime quantities and reservations; it does not modify definition resources.

## Stable item IDs

Inventory entries use stable item IDs instead of `Resource` references. String IDs remain predictable across JSON serialization, do not depend on a resource being loaded, and let a later transaction layer validate catalog membership without coupling the inventory model to the catalog. IDs are trimmed before storage, and empty or whitespace-only IDs are rejected.

`ItemCatalog` recursively loads item definitions from `res://data/items` by default. It keeps the first valid definition for an ID, reports invalid definitions and duplicates, and returns deterministic sorted ID lists.

## Quantities and reservations

The total quantity is all stock owned for an item. The reserved quantity is the sum committed to active reservations. Available quantity is:

```text
available = total - reserved
```

Adding stock changes the total without changing reservations. Direct removal can use only available stock, so it cannot take items promised to an activity.

A reservation has a stable, non-empty ID and one or more positive item quantities. Creating a multi-item reservation validates the entire request before storing anything. Its lifecycle ends in exactly one of two ways:

- `consume_reservation()` subtracts every reserved quantity from total stock and deletes the reservation.
- `release_reservation()` deletes the reservation without changing total stock, making those quantities available again.

Both paths are atomic. Snapshot dictionaries returned by the model are deep copies and cannot mutate authoritative state.

## Save schema

Inventory saves currently use schema version 1:

```json
{
  "version": 1,
  "quantities": {
    "raw_slime_meat": 4,
    "slime_gel": 2
  },
  "reservations": {
    "cook.job.17": {
      "raw_slime_meat": 2
    }
  }
}
```

Loading validates the complete document before replacing existing state. It rejects unsupported versions, missing or malformed fields, non-positive quantities, invalid IDs, empty reservations, and individual or combined reservations exceeding total stock. An empty dictionary is rejected because it is not a versioned save; a versioned save with empty `quantities` and `reservations` is a valid empty inventory.

## Future cooking example

```gdscript
var inventory := InventoryModel.new()
inventory.add(&"raw_slime_meat", 4)

var result := inventory.reserve_items(
	&"cook.job.17",
	{&"raw_slime_meat": 2}
)
if result.success:
	# Later, after the cooking activity succeeds:
	inventory.consume_reservation(&"cook.job.17")
	# If it is cancelled instead, call release_reservation().
```

The future cooking system will be responsible for catalog validation and granting outputs. The inventory itself intentionally knows nothing about recipes.

## Gold and merchant trading

Gold is the ordinary catalog item `gold_coin`, stored as an integer quantity in the same authoritative `InventoryModel` as every other item. There is no wallet or parallel currency state. The configured Mom NPC uses her existing persistent NPC inventory for both stock and gold; the player uses the existing persistent player inventory.

Positive `ItemDefinition.base_value` values mark ordinarily tradable items. `MerchantComponent` is the single pricing source: the price to the player is the base value multiplied by `price_to_player_multiplier`, while the price from the player is the base value multiplied by `price_from_player_multiplier`. Godot's positive `roundi` rule is applied once after multiplication and a positive tradable price is clamped to at least one gold. Zero-value items and gold itself are excluded from ordinary item trading.

`TradeService` stages the complete item and gold exchange in inventory snapshots before applying either authoritative result. Buying moves merchant item to player and player gold to merchant; selling reverses both legs. Invalid quantity or price, overflow, insufficient stock or gold, destination overflow, and any failed staged leg leave both live inventories untouched. If an authoritative apply unexpectedly fails, both exact pre-trade snapshots are restored. Only available quantities may move, so reservations protect stock and gold from trading.

Mom's starting profile supplies 100 gold and 5 cooked slime meat only when `NpcLocations` creates her persistent record for the first time. Existing records always restore their saved stock and reservations, so scene changes and save/load do not refill the shop. The existing definitive-death drop path treats merchant gold and stock like all other inventory items; knockout still does not drop inventory.

The signal-driven trade screen opens through the existing NPC interaction action, uses the HUD's established modal pause ownership, and refreshes on inventory and reservation signals without polling. The player development component offers a separate disabled-by-default `development_add_trade_gold` option that adds 50 gold once in a debug build.

Dynamic pricing, timed restocking, bargaining, reputation discounts, taxes, credit, debt, multiple currencies, protected merchant items, crafting, recipes, equipment, and item use remain deferred.

## Persistent NPC ownership

Each live persistent `SocialNpc` has one `NpcInventoryComponent`, which owns its one mutable `InventoryModel`. While the NPC is live, that component is authoritative. The NPC's persistent location record contains only the most recently captured JSON-safe snapshot returned by `InventoryModel.get_save_data()`.

When the NPC is off-screen, the nested record block is authoritative and has the same versioned `version`, `quantities`, and `reservations` fields as an ordinary inventory save. No off-screen `InventoryModel` is instantiated or retained. Unrelated world-simulation updates copy and commit complete records, preserving the inventory block without interpreting it.

After a scene-authored NPC passes wrong-scene and duplicate-instance registration checks, an existing valid record inventory is restored atomically into the live component exactly once. A new record captures the accepted scene component's inventory. The reverse handoff uses the canonical live-record capture path reached by unregister, travel, scene exit, simulation synchronization, and save preparation.

Old records with no `inventory` field are normalized to a fresh valid empty block and restore as empty. If a present block fails `InventoryModel` validation, no partial data is applied: a warning identifies the NPC and failure, the valid live inventory is preserved, and the record's malformed block is replaced by a fresh live snapshot. Reservations persist through capture, scene changes, off-screen storage, and save/load.

NPC inventory gameplay remains deferred. This persistence layer does not add stock generation, wallets, merchants, loot, recipes, eating, equipment, travel behavior, or NPC inventory UI.

## Persistent player inventory and screen

The canonical player scene has one `PlayerInventoryComponent`, which owns the live player's single mutable `InventoryModel`. Its versioned snapshot is stored under `inventory` inside the existing player node save block. `PlayerRuntime` carries that same block through scene transitions, while normal save loading reaches the same `Player.apply_save_data()` restoration path. Missing old-save inventory resets to a valid empty inventory; malformed data is rejected atomically and preserves current valid state.

The autoloaded `PlayerHud` binds the current player's model to the read-only `PlayerInventoryScreen`. The existing `inventory` input action (`I`) toggles the screen. Opening pauses through `PauseSystem` without displaying the ordinary pause-stats overlay, and closing restores the prior pause state. Game-over and pre-existing pause ownership prevent the inventory from opening over another modal screen.

The list refreshes when opened or when inventory signals arrive while visible. Changes received while closed only mark it dirty, so it rebuilds once on the next open rather than polling. Rows use catalog display names and icons, show total quantity, and show available and reserved quantities when stock is reserved. Empty inventories have an explicit message; unresolved IDs remain visible through an ID fallback and produce one consolidated warning per refresh.

For immediate debug verification, `PlayerInventoryComponent.development_add_sample_items` is an exported, disabled-by-default option. Debug builds can also call `add_development_sample_items()` once per component. It validates the current catalog and uses public inventory APIs to add the three sample slime items; it is not release or normal starting inventory.

The screen deliberately provides no item use, dropping, equipment, loot pickup, merchant, money, eating, recipe, crafting, sorting, drag-and-drop, or NPC inventory controls.

## Definitive NPC death loot

`SocialNpc.die()` is the canonical irreversible death path and runs only when HP reaches zero. It delegates once to `NpcInventoryDropComponent` before the existing disabled/dead state cleanup. Knockout and downed states remain recoverable and never call the drop component; sleep, hiding, scene exit, off-screen handoff, and registration rejection likewise do not drop inventory.

The component confirms that its owner is the accepted canonical live NPC. It initializes one `WorldLootContainer` from a reservation-free copy of the complete total quantities. Only after the container successfully owns that snapshot does it release every dead-owner reservation, clear the live NPC inventory through public APIs, and trigger the existing persistent-record capture. A local completion guard makes repeated death calls idempotent. Initialization or spawn failure leaves the NPC inventory unchanged and retryable.

The world container owns one `InventoryModel` and uses the existing `up` interaction action while a player is inside its `Area2D`. Collection transfers each complete item quantity through `InventoryTransactionService`; failed transfers are rolled back and remain in the container, while successful transfers enter the authoritative player inventory. The container removes itself only after all loot is collected. Unknown item IDs remain authoritative and transferable without requiring catalog metadata.

Dropped world containers are scene-local in this implementation. They do not survive a scene change or save/load because the project has no small persistent-world-object lifecycle to extend. Advanced loot-table features, merchants, money, item use, eating, recipes, equipment, travel behavior, and a full loot-selection UI remain deferred.

## Data-driven monster loot

`LootTableDefinition` contains typed `LootTableEntry` resources. Each entry supplies a catalog item ID, independent drop chance, and inclusive minimum/maximum quantity. Rolling accepts an optional local RNG, combines duplicate item results, omits zero quantities, and skips invalid entries with warnings without blocking valid entries. Weighted groups, rarity tiers, nested tables, conditions, and pity systems are not implemented.

Nonpersistent monsters can own a `MonsterLootComponent` alongside the existing inventory and death-drop components. The component rolls once during legitimate monster initialization, stages the complete result in a temporary `InventoryModel`, then atomically applies the validated snapshot to the authoritative monster inventory. Repeated initialization is a no-op. Any existing non-empty inventory is treated as restored or explicitly authored and wins over generated loot.

The canonical slime scene references one shared `slime_loot_table.tres`: slime gel is guaranteed at 1-3 units, and raw slime meat has a 45% chance at 1-2 units. Cooked meat is not a natural drop. Slimes are ordinary spawned, nonpersistent monsters, so each newly spawned instance is a new roll lifecycle; broad monster persistence was not added.

Monster death contains no generation logic. `Monster.die()` delegates the already-populated authoritative inventory to the existing death-drop component, after which the existing world-container and transaction-service collection flow applies unchanged. Nonlethal damage does not initialize again or create loot.
