# NPC social-state schema

The social model has three deliberately separate meanings. Code and UI must not
infer one meaning from a value name.

| Meaning | Owner | Subject | Persistence | UI rule |
| --- | --- | --- | --- | --- |
| Physical state and personal need | One NPC | None | `NpcLocations` record | Label as local to that character |
| Broad mood | One NPC | None | `NpcLocations` record | May be shown without a subject |
| Directed opinion | One character | Another character | `Relationships` row | Always show `OWNER -> SUBJECT` |

`NpcSocialStateSchema` is the canonical registry. Every displayed value declares
its scope, range/default, behavior consumers, persistence owner, decay policy,
and presentation metadata. New values are not eligible for the character/debug
UI until they are declared there.

## Local state

Physical values are health, knockout, and disabled state. Personal needs are
hunger, sleep need, tiredness, boredom, social need, and loneliness. Curiosity,
sadness, energy, bored, and undirected anger are broad moods. These values
describe the NPC itself; they never imply an opinion about the Player.

Broad anger remains available because existing behavior can use it as a general
reaction mood. Anger caused by a known attacker is different: that is written to
the directed relationship row for `NPC -> attacker`.

## Directed opinions

Each relationship row identifies both sides with stable IDs:

```text
owner_id -> other_id
favor, trust, love, lust, shame, anger, fear, suspicion
```

Favor affects social selection/acceptance and existing dialogue or trade paths;
love also contributes to social candidate scoring. Directed anger and fear
affect combat and avoidance. Trust and suspicion remain valid story currencies
even though no general-purpose behavior consumes them yet. They are kept because
authored story systems can use them later; their lack of a current consumer is
not treated as an error. Lust and shame are independent persistent axes with no
decay or behavior consumers yet.

Fight evaluates anger against its concrete player or NPC target. Directed anger
can start and sustain that fight. Player combat also retains the historical broad
anger fallback, using the greater of broad and player-directed anger; NPC-to-NPC
combat remains strictly directed. The same target-specific rule decides whether
the fight has calmed. Monster reactions remain owned by the separate monster-sight
policy and do not invent relationship opinions for monsters.

All eight metrics use the generic `Relationships` opinion API. Its first actor/ID
is always the opinion owner and its second actor/ID is always the subject.
ID-based snapshot reads return copies and never create, mark, or mutate a
relationship; node-based compatibility calls may only migrate a known legacy
alias to that node's stable identity.

## Compatibility boundary

Old saves and authored scenes can still contain undirected `favor`, `trust`,
`love`, or `suspicion` fields inside NPC-local dictionaries. Those fields remain
loadable so existing content is not destroyed, but they are hidden from the new
character pages and debug displays. Any event with an explicit actor routes its
opinion deltas to `NPC -> actor`; it is not mirrored back into the legacy local
field. Actor-less legacy/story calls retain their old hidden behavior rather than
guessing that the Player was the subject.

Damage follows the same rule. Player/NPC damage changes the victim's opinion of
that attacker. Environment or unknown-source damage may change health and broad
mood, but it cannot spend an ambiguous global favor value.

## Character browser

The pause menu roster contains stable characters connected to the Player by a
real `met` relationship. The selected character is the opinion owner. The Player
is the first subject, and left/right navigation expands over the other characters
known to the Player. A missing directed row is shown as “No opinion recorded”; it
is not presented as a fabricated neutral opinion. The in-world favor bar and
body tint are likewise hidden/reset until a real `NPC -> Player` row is marked
`met`; legacy local favor is never used as a player-opinion fallback.

Presentation metadata lives in an optional `NpcCharacterProfile` resource:
display name, role/subtitle, description, portrait, and accent color. A compact
snapshot is retained in `NpcLocations`, so the same character entry works while
the NPC is offscreen. Missing portraits use the designed placeholder area.

Episodic memory is intentionally absent from this first character page. Current
memory reads can prune expired entries and the memory repository does not yet
have the same durable save contract as relationships, so exposing it here would
make a read-only menu alter or misrepresent state.

## Adding a value safely

1. Declare the value in `NpcSocialStateSchema`, including scope, consumers,
   persistence, decay, and presentation.
2. For a directed opinion, write through `Relationships` with explicit owner and
   subject IDs/nodes. Never add it to an NPC-local display dictionary.
3. For local state, keep it in the NPC/location record and decide whether it is a
   personal need or a broad mood.
4. Add a save/migration test and a presentation test. Directed tests must verify
   that reversing owner and subject produces an independent value.
