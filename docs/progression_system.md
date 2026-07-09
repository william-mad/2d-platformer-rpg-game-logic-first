# Progression System

The progression system keeps two kinds of XP separate:

- Global XP is classic RPG XP. It raises the player's global level and exposes derived stat bonuses through `ProgressionSystem.get_damage_multiplier()`, `get_max_hp_bonus()`, and `get_max_mana_bonus()`.
- Skill XP is raw proficiency by domain, such as `magic`, `mana`, `work`, `class`, and `combat`. Skill XP does not create levels. It is used to unlock abilities and gate actions.

Static data lives in resources under `res://data/progression`. Save-specific data lives only in `ProgressionSystem` save data: global XP, global level, skill XP values, unlocked ability ids, claimed one-shot rewards, and pending time reward seconds.

Current gameplay rule: progression does not block dash, spells, or work actions. Ability definitions can describe future gates or menu entries, but player controls should only be wired to those gates once the gate is visible and testable in-session.

## Add A Skill Domain

Create a `SkillDomainDefinition` resource in `res://data/progression/skill_domains`.

Minimum fields:

```gdscript
id = &"crafting"
display_name = "Crafting"
```

Unknown domain ids warn once and are ignored by public XP APIs.

## Add An Ability

Create an `AbilityDefinition` resource in `res://data/progression/abilities`.

Important fields:

- `id`: stable id used in code.
- `required_global_level` and `required_global_xp`: global requirements.
- `required_skill_xp`: raw skill gates, for example `{ "magic": 100, "mana": 50 }`.
- `prerequisite_ability_ids`: abilities that must already be unlocked.
- `auto_unlock`: true if the ability should unlock as soon as requirements are met.
- `action_id` or `player_state_name`: optional metadata for player action gates.

Code can ask:

```gdscript
ProgressionSystem.is_ability_unlocked(&"basic_magic")
ProgressionSystem.get_locked_reason(&"basic_magic")
ProgressionSystem.unlock_ability(&"mana_focus")
```

## Add An XP Reward

Create an `XPRewardDefinition` resource in `res://data/progression/xp_rewards`.

Use `global_xp_amount` for global XP and `skill_xp_amounts` for domain XP:

```gdscript
id = &"enemy_kill.slime"
global_xp_amount = 10
skill_xp_amounts = { "combat": 5 }
```

For time rewards, set `per_second` or `per_minute`. The system batches elapsed seconds and only awards whole units.

## Award XP From Code

Instant reward:

```gdscript
ProgressionSystem.award_reward(&"enemy_kill.slime", {"attack_tags": ["magic"]})
```

Time reward:

```gdscript
ProgressionSystem.add_time_xp(&"class.magic_basics", delta)
```

The default slime reward grants 3 global level XP and 5 combat skill XP. If the kill context includes the `magic` tag, it also grants 3 magic skill XP.

The default level curve is editable in `res://data/progression/level_curve_default.tres`. It uses generated requirements by default: 50 XP for level 2, then each new level costs 2x the previous level-up step.

The magic lesson spot calls `add_time_xp(&"class.magic_basics", delta)` while the lesson is progressing. Player work spots call `add_time_xp(&"work_activity.basic", delta)` while the player is actively working.

## Save And Load

`SaveSystem` stores `ProgressionSystem.get_save_data()` under the top-level `progression` key and restores it through `apply_save_data()`. Resource files are never mutated at runtime, so changing tuning data does not rewrite player saves.

The progression save payload includes:

- `global_xp`
- `global_level`
- `summary`, used by save-file menus
- `skill_xp`
- `unlocked_ability_ids`
- `claimed_reward_ids`
- `time_reward_pending_seconds`

Save-file summaries show level and current-level XP when progression data exists, for example `File 1 - Lv 3 10/200 XP - Home 1`. Older saves without progression still load and keep the old summary format.

For quick inspection, call:

```gdscript
ProgressionSystem.debug_print_snapshot()
```
