# Player Attack Resources

The standing light combo now uses Resource data instead of separate hardcoded attack scripts.

## Replaced Files

The old hitbox scripts were removed:

- `player/scripts/attack_1.gd`
- `player/scripts/attack_2.gd`
- `player/scripts/attack_3.gd`

The old per-step state scripts were also removed:

- `player/states/attack_1.gd`
- `player/states/attack_2.gd`
- `player/states/attack_3.gd`

They were replaced by:

- `player/scripts/player_attack_hitbox.gd`
- `player/states/player_combo_attack.gd`
- `player/combat/attack_definition.gd`
- `player/combat/combo_definition.gd`

## Current Resources

Attack definitions live in `player/combat/attacks/`:

- `light_1.tres`
- `light_2.tres`
- `light_3.tres`
- `crouch_attack.tres`

Combo definitions live in `player/combat/combos/`:

- `standing_light_combo.tres`
- `crouch_combo.tres`

## Standing Combo Mapping

`standing_light_combo.tres` maps to the old combo like this:

- Step 1: `light_1.tres`
- Step 2: `light_2.tres`
- Step 3: `light_3.tres`

The values were copied from the old scene/script setup:

- damage and knockout values come from the old `Attack_1`, `Attack_2`, and `Attack_3` scripts
- hitbox size and offset come from the old `Attack_1`, `Attack_2`, and `Attack_3` scene nodes
- state duration and combo windows come from the old attack state scripts

## Editing An Attack

Open an `AttackDefinition` Resource and edit:

- `damage`
- `knockout_damage`
- `hitbox_size`
- `hitbox_offset`
- `active_seconds`
- `state_duration`
- `combo_window_seconds`
- `animation_name`
- `move_speed_multiplier`
- `collision_mask`
- `tags`

The hitbox script only applies the selected Resource values. It does not decide combo damage or which combo step is active.

## Crouch Attack

`crouch_attack.tres` is a low melee attack with no knockout damage. It uses the same generic hitbox and combo state as the standing combo.

When the crouch attack finishes:

- if the crouch button is still held and the player is on the floor, the player returns to crouch
- otherwise the player returns to idle or fall

## Adding More Attacks

To add another standing, crouched, or airborne attack:

1. Create a new `AttackDefinition` Resource.
2. Add it to a `ComboDefinition`, or make a new combo Resource.
3. Assign that combo/index to a `PlayerComboAttackState` node in the player scene.
4. Only write a new script when the attack has behavior the generic hitbox cannot represent.
