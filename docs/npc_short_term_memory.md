# Live NPC short-term memory

## Responsibility boundaries

Live NPC behavior now has three distinct forms of state:

- An **intention** is the accepted goal and commitment decision. `NpcBehaviorController`
  owns its identity, priority, and interruption policy.
- An **action session** is the authoritative execution transaction. It owns the
  action kind, target, phase, reservations, and terminal result.
- A **memory event** is a copied observation of an outcome that already happened.
  It has no authority over either of the first two.

`NpcShortTermMemory` never requests a state, selects a target, changes an intention,
ends an action, reserves a spot, or changes relationships or values. The first
memory-informed producer is the separate `NpcSocialMemoryPolicy`, which queries
this passive evidence while the existing social planner evaluates a candidate.

```text
gameplay outcome
      |
      v
memory observer
      |
      v
structured memory event
      |
      v
NpcShortTermMemory
      |-- dedupe / merge
      |-- expiry / eviction
      |-- query API
      `-- debug descriptor

NpcShortTermMemory does not call NpcStateMachine.
```

The refusal-to-retry flow is:

```text
conversation refusal
      |
      v
structured memory event
      |
      v
NpcShortTermMemory

next social candidate search
      |
      v
NpcSocialMemoryPolicy queries memory
      |
      v
candidate allowed or temporarily suppressed
      |
      v
NpcSocialPlanner selects among allowed candidates
      |
      v
existing intention/session pipeline
```

## Record model and role conventions

`NpcMemoryEvent` is a `RefCounted` data object. It stores:

- Stable memory, intention, and action-session IDs.
- Event type, source, reason code, and logical action.
- Subject, target, and place IDs.
- First-observed, last-updated, and absolute-expiry game hours.
- Importance, emotional valence, occurrence count, and resolved state.
- Deep-copied metadata.

It never stores a `Node`. `subject_id` means the actor central to the observed
event. `target_id` means the affected object or destination. For social memories,
the conversation partner is the subject and the remembering NPC is the target.
For an action failure, the remembering NPC is the subject and the action target
is the target.

For `conversation_refused`, the requester is the NPC that stores the memory,
`subject_id` is the refusing partner, and `target_id` is the requester. Both IDs
come from `NpcActionSession.get_persistent_id()`, which prefers
`get_npc_location_id()`. Display names, scene paths, and node references do not
participate in matching.

Memory IDs are runtime identities and do not depend on feedback text. Dedupe keys
use only structured event roles:

- Conversation outcomes: event type, subject, and remembering NPC.
- Action/target failures: event type, subject, target, and logical action.
- Movement failures: the same fields plus place.

## Policy ownership

`NpcMemoryPolicy` is the only owner of initial duration, importance, valence,
dedupe, merge, occurrence, lifetime, and debug-text policy:

| Event | Duration | Maximum lifetime | Importance | Valence | Dedupe window |
| --- | ---: | ---: | ---: | ---: | ---: |
| `conversation_refused` | 1.50 h | 3.00 h | 0.55 | -0.45 | 0.25 h |
| `conversation_completed` | 0.75 h | 1.50 h | 0.35 | +0.25 | 0.25 h |
| `action_failed` | 0.50 h | 1.00 h | 0.45 | -0.25 | 0.125 h |
| `target_unavailable` | 0.50 h | 1.00 h | 0.40 | -0.20 | 0.125 h |
| `movement_failed` | 0.50 h | 1.00 h | 0.50 | -0.30 | 0.125 h |
| `intention_target_lost` | 0.75 h | 1.50 h | 0.55 | -0.35 | 0.25 h |

Durations use total game hours from `WorldTime`. Pausing world progression pauses
memory age; accelerated time and large time jumps age memory deterministically.
The 0.5-second real-time check only decides when to inspect expiry.

## Dedupe, merge, expiry, and eviction

An insert validates the event, prunes expired records, finds the structured
dedupe key, and merges only inside that type's window. A merge preserves the
original memory ID and creation time, updates the last-observed time, increments
the capped occurrence count, and only fills missing metadata keys. It may refresh
expiry, but never beyond the policy's absolute maximum lifetime measured from the
first observation. Repeated path failures therefore cannot create an immortal
memory.

The default capacity is 24. Capacity enforcement is deterministic:

1. Expired records are removed first.
2. Resolved records are preferred for eviction.
3. Lower importance is removed next.
4. Older `last_updated_game_hours` breaks the next tie.
5. Lexicographic memory ID is the final tie-breaker.

Queries return duplicated events, including duplicated metadata, so callers
cannot mutate internal storage.

## Captured live outcomes

`NpcMemoryObserver` translates only these central, high-confidence outcomes:

- An NPC requester's intended NPC partner explicitly refuses the mutual Talk
  handshake.
- A real NPC-to-NPC Talk overlay reaches the existing normal completion path.
- The current matching action session reaches `failed` through
  `fail_active_action`.
- `missing_action_target`, `movement_target_missing`, and a missing scheduled
  routine spot become the canonical `target_unavailable` event.
- A terminal `movement_stuck` result becomes `movement_failed`.
- A goal-bearing, non-lifecycle intention loses its exact persistent target and
  its state actually exits because of that loss.

Other matching action failures become `action_failed`.

The current Talk handshake reports only `can_accept_talk_request == false`; it
does not expose the partner's private refusal subtype. The observer therefore
stores the stable `partner_refused_talk` result and does not infer a more specific
reason from label text or arbitrary strings.

## Refusal retry policy

`NpcSocialMemoryPolicy` is a stateless interpretation layer. It queries unresolved
`conversation_refused` events for one candidate's persistent ID and returns a
structured allow/suppress decision. Resolved refusal memories do not suppress.
Conversation completion, generic action failure, commitment rejection, player
dialogue cancellation, and candidate-discovery failure do not qualify.

The refusal memory lasts about 1.5 game hours, while the default behavioral retry
delay is only 0.25 game hours (about fifteen in-game minutes). The shorter delay
uses `last_updated_game_hours`, so a genuine merged repeat restarts the delay
without changing the memory's lifetime. Both use authoritative total game hours:
paused game time pauses them, accelerated time advances them, and large time
jumps resolve them deterministically.

The filter runs after ordinary identity, availability, relationship, and
same-scene checks, but before the planner reserves a pair or submits an intention.
Suppressed candidates are skipped without changing the order of allowed
candidates. Another eligible NPC or the player can still be selected.

If every otherwise-valid NPC candidate is suppressed, the planner returns
`no_social_target_due_to_recent_refusal`, creates no reservation or action
session, leaves social need and the current commitment unchanged, and records
the earliest game-hour retry boundary for the normal social-planning cadence.
Ordinary schedule and non-social fallback behavior can continue.

The same policy also filters the live `talk_to_seen_target` value-rule candidate
loop before its request is submitted. Offscreen simulation has no memory and is
unchanged. The policy is evaluated only during new candidate selection; accepted
approaches, Talk overlays, pair ownership, completion, emergency handling,
schedules, travel, and player interaction are not continuously reevaluated.

## Intentionally excluded outcomes

The observer does not record candidate inspection, target search with no actual
partner, behavior-commitment rejection, normal action completion, same-session
phase or intention refresh, accepted-intention replacement, temporary traversal
retry, player Talk cancellation, monster-search fallback, overlay start, or
scene teardown/lifecycle cleanup.

Cancellation is explicitly classified as failure, target unavailable, movement
failure, supersession, neutral cancellation, or lifecycle cleanup at the central
action terminal. Only failure classifications reach memory. The action session
must be current when terminal handling begins. A stale callback is rejected
before observation. The observer also keeps a small game-time terminal key cache
by session and event type, so duplicated cleanup routing creates one observation.

`intention_target_lost` requires a matching accepted non-lifecycle intention and
matching session and target IDs. It is not also emitted as
`target_unavailable` for the same outcome.

## Developer feedback

The state machine exposes an adjacent combined feedback descriptor containing the
existing intention/rejection/commitment section and a structured `memory`
section. An all-suppressed social search also exposes a `social_selection`
descriptor with considered/suppressed counts, selected candidate, stable reason,
and earliest retry time. `NpcBehaviorFeedbackFormatter` renders at most one
policy line and one memory.

```text
MoveToTarget -> Eat + Talk
Hungry · need · p50
social: waiting after refusal
remembers: Mom refused to talk
```

Selection prefers unresolved, higher-importance, and more recently updated
records. `memory_changed` refreshes the existing `StateLabel`; the memory
component does not display UI and the label is not rebuilt every frame. Its
0.5-second expiry check triggers another change only when something expires.
The social-policy line is presentation-only, contains no raw memory ID, is not
shown when an alternative or the player is selected, and disappears when the
retry boundary passes.

## Snapshot preparation

`NpcMemoryEvent.to_dict()` and `from_dict()`, plus
`NpcShortTermMemory.export_snapshot()` and `import_snapshot()`, prepare a stable
serialization boundary. Import tolerates malformed optional metadata, rejects
unknown event types, prunes expired entries, clamps values, preserves valid IDs,
keeps the first occurrence of a duplicate ID, and enforces capacity. It emits one
summarized `memory_changed` notification rather than one notification per row.

These snapshots are deliberately not connected to `SaveSystem`, `NpcLocations`,
scene travel, or offscreen simulation yet. The next persistence pass can own
those transfers without making this storage component depend on world records.

## Future behavior use

Later memory-informed behavior should follow the same pattern: add a focused,
stateless policy beside the producer that owns a decision, query duplicated
memory evidence, and return structured advice before mutation. Do not add
behavior-specific methods to `NpcShortTermMemory`, make memory request states, or
turn memory importance into behavior priority.
