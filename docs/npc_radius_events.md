# NPC radius events

`EventBus` remains the authority for scoped world events. A local event carries a
world `position`, a per-occurrence `radius`, and `has_position = true`. NPCs only
receive it when they are inside that emitted radius. An NPC reaction rule may cap
the radius for compatibility, but cannot make one occurrence travel farther than
the emitter authored.

`NpcRadiusEventEmitter` is a small reusable scene component for sound-like events.
It can provide local NPC-value deltas, explicitly directed Relationship-opinion
deltas, an existing state request, priority, and semantic tags. Directed deltas
are only applied when the event names a valid responsible `actor`; the physical
`source` can be a separate prop such as a bell.

## Monster bell

`MonsterBell` is an indestructible `attack_target` using the normal
`Damage_Area.take_damage()` contract. Player attacks and monster touch damage
therefore ring it through the same entry point. A short hit cooldown prevents one
continuous attack overlap from producing duplicate rings.

On `monster_bell_rung`, an in-radius NPC searches the current scene for a live
monster accepted by its existing monster-target configuration:

- With a monster present, the NPC calls its existing `request_monster_reaction()`.
  Mom's authored reaction is Fight; NPCs configured to flee, scream, or ignore
  retain those choices.
- Without a monster, the NPC briefly uses its existing `ReactToEvent` response.
  If the responsible actor is the Player, the false alarm applies one directed
  Mom-to-Player opinion batch (`favor -2`, `trust -1`, `anger +2`) and offers the
  event to the existing reprimand coordinator. Mom then uses the normal Talk
  approach and contextual dialogue path.
- A monster-triggered ring never blames the Player and never schedules a Player
  reprimand.

No new NPC state, combat authority, global commitment rule, or parallel dialogue
system is introduced. Off-radius NPCs receive nothing, and changing the emitter's
`radius` changes the audible reach without changing receiver code.
