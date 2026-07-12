# Economy inventory foundation

This foundation separates immutable item descriptions from mutable inventory state. `ItemDefinition` resources contain catalog metadata such as names, tags, values, stack hints, weight, and food properties. `InventoryModel` stores only runtime quantities and reservations; it does not modify definition resources.

## Food consumption and basic processing

Hunger is a need value where `0` is fully satisfied and `100` is maximum hunger. Player and NPC hunger naturally grows upward, so food applies a negative hunger delta. Existing `ItemDefinition.edible` and `hunger_reduction` fields are the authoritative food metadata: raw slime meat is edible and reduces hunger by 10; cooked slime meat reduces hunger by 30; slime gel and gold remain non-edible. `ItemCatalog.is_food()` and `get_food_value()` treat unknown definitions as non-food and keep UI and services free of item-ID effect checks.

`FoodConsumptionService` coordinates one inventory item with one public hunger mutation. It rejects missing owners/inventories, unknown or non-edible items, non-positive food values, satisfied or definitively dead characters, noncanonical NPC instances, reserved player food, and missing NPC eating reservations. It applies the clamped hunger reduction first, removes or consumes the one-item reservation through `InventoryModel`, and restores the exact previous hunger through the same public need API if inventory mutation fails. The player inventory details panel exposes a focusable Consume button only for edible items, shows the food value and current hunger, preserves item selection through signal-driven refreshes, and remains operable under the existing inventory pause modal.

Live NPCs use the existing `Eat` state. A stocked meal/work spot remains the sole source for that action and retains its existing gradual food-point depletion; NPC inventory is not touched, preventing double consumption. For an Eat action without a stocked spot, the state selects the highest `hunger_reduction` among available unreserved NPC-owned food, then display name and item ID as deterministic tie-breakers. It reserves one item as `eat:<npc_id>` across movement and talk overlays, consumes it through `FoodConsumptionService` only when the existing eat timer completes, and releases it after cancellation or interruption. Missing food starts a 10-second retry delay and does not fabricate stock or reduce hunger. Live inventory capture later persists successful consumption. Existing off-screen meal-spot simulation is unchanged; general off-screen mutation of NPC inventory remains deferred.

`ProcessingRecipeDefinition` stores a stable recipe ID, display name, positive input quantities, and positive output quantities. `InventoryProcessingService.process(inventory, recipe, batches)` validates every catalog ID and available unreserved input, stages the full operation in a snapshot-backed `InventoryModel`, removes all inputs, adds all outputs, and commits once. Any input/output failure leaves the authoritative inventory and its unrelated reservations unchanged. `cook_slime_meat.tres` defines one raw slime meat into one cooked slime meat with no gold cost.

The home scene contains one stove using the existing Up interaction and `PauseSystem` modal convention. Its event-driven panel shows recipe icons, the 1→1 flow, maximum processable batches, a keyboard/controller-focusable quantity selector and Process button, and concise feedback. It revalidates on Process and refreshes only on open, inventory/reservation signals, quantity changes, and completed processing. Player inventory persistence stores consumed inputs and cooked outputs through the existing save block; player hunger already uses the same player save path; NPC lifecycle capture persists live consumption. No save version change is required because food and recipe metadata live in resources.

Recipe discovery, crafting trees, cooking skill, buffs, poisoning, spoilage, equipment, farming, cooking animations, advanced meal planning, travel rations, merchant restocking, and automatic NPC food purchasing are not implemented.

## Implemented inventory, loot, and trade update

World loot now uses its existing `Area2D` as a 160-pixel attraction zone. Body enter/exit events track only nearby `InventoryPickupReceiver` components; there is no per-frame scene-tree or group scan. The shared player and persistent `SocialNpc` scenes each expose that thin receiver contract over their existing authoritative inventory. A player must be live in the tree. An NPC must additionally be alive, not queued for removal, and be the canonical live instance accepted by `NpcLocations`; rejected duplicates, wrong-scene instances, off-screen records, dead NPCs, and the dead loot source are ineligible.

The nearest eligible receiver is selected by squared distance with receiver ID as the deterministic tie-break. The current target is retained until a candidate is at least 12 pixels closer, avoiding rapid switching. Loot starts at 90 px/s, accelerates at 900 px/s², caps at 420 px/s, and collects within 18 pixels. Collection transfers each complete stack through `InventoryTransactionService`. Successful quantities leave the container; failures remain world-owned; the container is freed only when empty. NPC pickups enter the live NPC inventory and therefore follow the normal later record capture, trade, and definitive-death-drop lifecycle.

Every accepted ordinary `SocialNpc` has the shared `MerchantComponent` and exposes `Talk`, `Trade`, and `Cancel` through the existing interaction menu. Its actual persistent inventory is its stock and wallet. A new persistent record initializes authored profile items, then adds 20 `gold_coin` only when no authored gold exists. This happens only in the new-record branch; restoration always wins and never refills gold or stock. Mom's authored profile remains the override with 100 gold and five cooked slime meat.

Pricing uses directed `NPC → Player` favor from `Relationships`, falling back to the NPC's configured default and clamping to 0–100. The charge multiplier is piecewise linear through `(0, 2.0)`, `(50, 1.25)`, `(100, 0.9)`; the payment multiplier is piecewise linear through `(0, 0.25)`, `(50, 0.5)`, `(100, 0.75)`. Final price is `max(1, roundi(base_value * multiplier))`; Godot rounds positive halfway values away from zero. Gold, non-tradable definitions, zero-value definitions, unavailable stock, and reserved items/gold are excluded. Policy validation precedes the existing atomic two-inventory exchange.

Item definitions now carry `tradable`, `trade_group`, `minimum_favor_to_buy`, and `minimum_favor_to_sell`. Empty NPC group filters accept ordinary tradable groups. `slime_gel` is unrestricted material; `raw_slime_meat` requires 10 favor to buy and 0 to sell; `cooked_slime_meat` requires 35 to buy and 15 to sell; `gold_coin` is currency and never appears as a product. Favor-locked Buy stock remains visible with its icon, quantity, lock overlay, required favor, and current favor. Items the NPC refuses to buy are consistently hidden from Sell.

Player inventory and both trade sides use `inventory_item_slot.tscn` inside scrollable `GridContainer`s. Slots display assigned icons, quantities, reservation markers, prices, locks, and a clear focus/hover border. Built-in Control focus provides keyboard/controller arrow navigation; mouse hover and focus both update the shared details area. Grids rebuild only on open, bound inventory signals, trade-partner/favor changes, completed trades, or dumps. Selection is restored by item ID when still valid, and each empty section has an explicit message.

The four catalog definitions are assigned once to existing `gpticons` textures: `slime_gel.png`, `slime_meat.png` for both raw and cooked slime meat, and `coin.png` for gold. No runtime filename search, artwork generation, rename, or overwrite occurs. All item definitions have a match; the remaining icon assets are currently unused catalog candidates. Unknown runtime IDs or future definitions without an icon use the existing `book.png` as a stable fallback.

The inventory details area can dump one, a chosen quantity, or the full available unreserved stack. Gold follows the same general rule and may be dumped. The screen validates the world parent and quantity, creates and initializes one ordinary `WorldLootContainer`, then removes the exact quantity through the public inventory API; initialization or removal failure frees the staged node and leaves player ownership unchanged. Successful loot spawns 76 pixels beside and 24 pixels above the player. A 0.75-second receiver-ID exclusion prevents only the dumping player from immediately reclaiming it, while eligible nearby NPCs remain able to collect it. The receiver stays tracked during the cooldown and becomes eligible automatically when it expires.

World loot, including dumped stacks, remains scene-local and does not survive save/load or scene changes. Crafting trees, advanced recipes, equipment, travel, dynamic markets, debt, taxes, bargaining, theft/ownership rights, manual slot rearrangement, and persistent world drops remain deferred.

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

## Reservation example for future timed processing

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

The implemented stove processing is immediate and therefore does not need a long-lived reservation. A future timed processing activity could use this reservation lifecycle; the inventory itself intentionally remains unaware of recipes.

## Gold and merchant trading

Gold is the ordinary catalog item `gold_coin`, stored as an integer quantity in the same authoritative `InventoryModel` as every other item. There is no wallet or parallel currency state. The configured Mom NPC uses her existing persistent NPC inventory for both stock and gold; the player uses the existing persistent player inventory.

Positive `ItemDefinition.base_value` plus the explicit trade metadata mark ordinarily tradable items. `MerchantComponent` is the single pricing and item-access source; the exact directed-favor curve and rounding rule are documented above. Zero-value items and gold itself are excluded from ordinary item trading.

`TradeService` stages the complete item and gold exchange in inventory snapshots before applying either authoritative result. Buying moves merchant item to player and player gold to merchant; selling reverses both legs. Invalid quantity or price, overflow, insufficient stock or gold, destination overflow, and any failed staged leg leave both live inventories untouched. If an authoritative apply unexpectedly fails, both exact pre-trade snapshots are restored. Only available quantities may move, so reservations protect stock and gold from trading.

Mom's starting profile supplies 100 gold and 5 cooked slime meat only when `NpcLocations` creates her persistent record for the first time. Existing records always restore their saved stock and reservations, so scene changes and save/load do not refill the shop. The existing definitive-death drop path treats merchant gold and stock like all other inventory items; knockout still does not drop inventory.

The signal-driven trade screen opens through the existing NPC interaction action, uses the HUD's established modal pause ownership, and refreshes on inventory and reservation signals without polling. The player development component offers a separate disabled-by-default `development_add_trade_gold` option that adds 50 gold once in a debug build.

Dynamic market simulation, timed restocking, bargaining dialogue, taxes, credit, debt, multiple currencies, protected merchant items, crafting trees, advanced recipes, equipment, and non-food item use remain deferred. Directed-favor pricing is implemented as documented above.

## Persistent NPC ownership

Each live persistent `SocialNpc` has one `NpcInventoryComponent`, which owns its one mutable `InventoryModel`. While the NPC is live, that component is authoritative. The NPC's persistent location record contains only the most recently captured JSON-safe snapshot returned by `InventoryModel.get_save_data()`.

When the NPC is off-screen, the nested record block is authoritative and has the same versioned `version`, `quantities`, and `reservations` fields as an ordinary inventory save. No off-screen `InventoryModel` is instantiated or retained. Unrelated world-simulation updates copy and commit complete records, preserving the inventory block without interpreting it.

After a scene-authored NPC passes wrong-scene and duplicate-instance registration checks, an existing valid record inventory is restored atomically into the live component exactly once. A new record captures the accepted scene component's inventory. The reverse handoff uses the canonical live-record capture path reached by unregister, travel, scene exit, simulation synchronization, and save preparation.

Old records with no `inventory` field are normalized to a fresh valid empty block and restore as empty. If a present block fails `InventoryModel` validation, no partial data is applied: a warning identifies the NPC and failure, the valid live inventory is preserved, and the record's malformed block is replaced by a fresh live snapshot. Reservations persist through capture, scene changes, off-screen storage, and save/load.

The persistence layer remains the authority handoff used by universal trading, automatic loot pickup, inventory-based eating, and definitive death drops. It does not add arbitrary stock generation, wallets, advanced recipes, equipment, travel behavior, or a separate NPC inventory UI.

## Persistent player inventory and screen

The canonical player scene has one `PlayerInventoryComponent`, which owns the live player's single mutable `InventoryModel`. Its versioned snapshot is stored under `inventory` inside the existing player node save block. `PlayerRuntime` carries that same block through scene transitions, while normal save loading reaches the same `Player.apply_save_data()` restoration path. Missing old-save inventory resets to a valid empty inventory; malformed data is rejected atomically and preserves current valid state.

The autoloaded `PlayerHud` binds the current player's model to the read-only `PlayerInventoryScreen`. The existing `inventory` input action (`I`) toggles the screen. Opening pauses through `PauseSystem` without displaying the ordinary pause-stats overlay, and closing restores the prior pause state. Game-over and pre-existing pause ownership prevent the inventory from opening over another modal screen.

The icon grid refreshes when opened or when inventory signals arrive while visible. Changes received while closed only mark it dirty, so it rebuilds once on the next open rather than polling. Slots and the details panel expose catalog names/icons plus total, available, and reserved quantities. Empty inventories have an explicit message and unresolved IDs remain stable through an ID fallback.

For immediate debug verification, `PlayerInventoryComponent.development_add_sample_items` is an exported, disabled-by-default option. Debug builds can also call `add_development_sample_items()` once per component. It validates the current catalog and uses public inventory APIs to add the three sample slime items; it is not release or normal starting inventory.

The screen deliberately provides no non-food item use, equipment, crafting tree, drag-and-drop rearrangement, or direct NPC inventory controls beyond the shared trade screen.

## Definitive NPC death loot

`SocialNpc.die()` is the canonical irreversible death path and runs only when HP reaches zero. It delegates once to `NpcInventoryDropComponent` before the existing disabled/dead state cleanup. Knockout and downed states remain recoverable and never call the drop component; sleep, hiding, scene exit, off-screen handoff, and registration rejection likewise do not drop inventory.

The component confirms that its owner is the accepted canonical live NPC. It initializes one `WorldLootContainer` from a reservation-free copy of the complete total quantities. Only after the container successfully owns that snapshot does it release every dead-owner reservation, clear the live NPC inventory through public APIs, and trigger the existing persistent-record capture. A local completion guard makes repeated death calls idempotent. Initialization or spawn failure leaves the NPC inventory unchanged and retryable.

The world container owns one `InventoryModel` and automatically attracts the nearest eligible receiver as documented above. Collection transfers each complete item quantity through `InventoryTransactionService`; failed transfers are rolled back and remain in the container, while successful transfers enter the receiver's authoritative inventory. The container removes itself only after all loot is collected. Unknown item IDs remain authoritative and transferable without requiring catalog metadata.

Dropped world containers are scene-local in this implementation. They do not survive a scene change or save/load because the project has no small persistent-world-object lifecycle to extend. Advanced loot-table features, merchants, money, item use, eating, recipes, equipment, travel behavior, and a full loot-selection UI remain deferred.

## Data-driven monster loot

`LootTableDefinition` contains typed `LootTableEntry` resources. Each entry supplies a catalog item ID, independent drop chance, and inclusive minimum/maximum quantity. Rolling accepts an optional local RNG, combines duplicate item results, omits zero quantities, and skips invalid entries with warnings without blocking valid entries. Weighted groups, rarity tiers, nested tables, conditions, and pity systems are not implemented.

Nonpersistent monsters can own a `MonsterLootComponent` alongside the existing inventory and death-drop components. The component rolls once during legitimate monster initialization, stages the complete result in a temporary `InventoryModel`, then atomically applies the validated snapshot to the authoritative monster inventory. Repeated initialization is a no-op. Any existing non-empty inventory is treated as restored or explicitly authored and wins over generated loot.

The canonical slime scene references one shared `slime_loot_table.tres`: slime gel is guaranteed at 1-3 units, and raw slime meat has a 45% chance at 1-2 units. Cooked meat is not a natural drop. Slimes are ordinary spawned, nonpersistent monsters, so each newly spawned instance is a new roll lifecycle; broad monster persistence was not added.

Monster death contains no generation logic. `Monster.die()` delegates the already-populated authoritative inventory to the existing death-drop component, after which the existing world-container and transaction-service collection flow applies unchanged. Nonlethal damage does not initialize again or create loot.
