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
ends an action, reserves a spot, or changes relationships or values. Separate,
stateless interpretation policies query this passive evidence while the producer
that already owns candidate enumeration makes its decision:

- `NpcSocialMemoryPolicy` interprets recent conversation refusal.
- `NpcTargetMemoryPolicy` interprets recent target-specific terminal failure.

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

The target-failure flow is:

```text
terminal target failure
        |
        v
structured short-term memory

future need-target selection
        |
        v
NpcTargetMemoryPolicy
        |
        v
candidate allowed or temporarily suppressed
        |
        v
existing reservation and intention pipeline
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

World simulation no longer treats the requester's cached refusal retry time as
authority to skip the whole candidate search. It re-enumerates at the existing
social-planning cadence. A partner that enters the scene, becomes socially
available, or replaces a removed partner is therefore visible immediately; the
policy still suppresses only the partner whose refusal memory matches.

## Target-failure retry policy

`NpcTargetMemoryPolicy` evaluates a stable activity candidate without mutating
memory, candidates, reservations, action sessions, intentions, needs, or states.
It interprets only:

- `target_unavailable`, matching target and logical action unless metadata
  explicitly marks the target generally unavailable.
- `movement_failed`, matching logical action, persistent target ID, and place ID
  when the failure contains a place.
- `intention_target_lost`, matching logical action and persistent target ID.

`action_failed` is deliberately excluded. It can represent invalid animation,
script cancellation, combat interruption, or another state error that says
nothing reliable about whether the target should be retried. Conversation
memories likewise have no activity-target authority. Resolved and expired
memories never suppress.

The configurable default retry delays are 0.25 game hours for
`target_unavailable`, 0.125 game hours for `movement_failed`, and 0.25 game hours
for `intention_target_lost`. Each begins at `last_updated_game_hours`, so a real
merged repeat restarts the short retry. These delays do not change the longer
memory expiry; a stored memory can remain observable after its behavioural
suppression ends.

Activity matching uses `NpcActivityIdentity.get_persistent_spot_id()`. Display
labels, node names, scene-tree paths, object instance IDs, and feedback wording
are not candidate identities. Replacing a node while retaining its persistent
spot ID retains temporary suppression; a similarly named different spot does
not. A candidate without the existing stable spot identity fails open. No new
identity system was added.

The live value-rule adapter covers ordinary `need`-sourced Eat, Rest,
Recreation, Sleep, and Work actions. In the default rule table this currently
migrates the Eat, Rest, and Recreation producers; custom ordinary need rules for
Sleep or Work use the same adapter. Eat preserves configured/assigned-first and
nearest-spot ordering, with inventory food as the existing targetless fallback.
Rest and Recreation preserve configured/assigned-first and weighted casual
selection; Rest-in-place remains a fail-open alternative. Filtering happens
after each spot's existing availability check and before behaviour-intention
evaluation, action-session creation, target installation, reservation, or
movement.

Combat, flee, player, NPC conversation partners, TravelFollow, scheduled or
scripted assignments, invitations, dialogue actors, meal-cycle ownership,
scene-route doors, and rope targets remain outside this adapter. RoutineTask is
also excluded because its principal current target producer is the authoritative
scheduled/exact-target pipeline.

If a preferred candidate is suppressed, enumeration continues and the first
allowed alternative uses the normal reservation and intention pipeline. A
suppressed candidate receives no reservation, proposed action, session, target,
or intention and never reaches commitment evaluation.

If every otherwise-valid candidate is suppressed, the adapter returns
`all_targets_recently_failed` with candidate and suppression counts, the earliest
retry game hour, and stable per-candidate reason codes. It creates no action-side
objects, changes no need, records no new failure, and leaves the current primary
state and intention unchanged. There is intentionally no second timer or broad
retry cache: normal need-rule cadence re-enumerates candidates, so candidate-set,
availability, reservation, and memory revisions are not hidden behind an old
retry timestamp. Emergency and authoritative schedule requests never enter this
filter.

The policy is consulted only when selecting a new target. An accepted session is
not polled each physics frame, so older memory cannot cancel its movement,
arrival, reservation, or commitment. A later authoritative terminal failure can
create or merge memory for a future selection. Successful-use memory resolution
is deferred: current completion hooks do not provide a uniformly safe,
target-and-place-specific match across all migrated state families, and retry
eligibility already returns independently when the short delay ends.

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
and earliest retry time. Target selection exposes a `target_selection`
descriptor with logical action, candidate count, suppression count, selected
stable ID, per-candidate reasons, and earliest retry.
`NpcBehaviorFeedbackFormatter` renders concise policy lines adjacent to memory.

```text
MoveToTarget -> Eat + Talk
Hungry · need · p50
social: waiting after refusal
Eat targets recently failed
remembers: Mom refused to talk
```

Selection prefers unresolved, higher-importance, and more recently updated
records. `memory_changed` refreshes the existing `StateLabel`; the memory
component does not display UI and the label is not rebuilt every frame. Its
0.5-second expiry check triggers another change only when something expires.
Policy lines are presentation-only, contain no raw memory IDs, are not shown
when an alternative is selected, and disappear when the retry boundary passes.
A memory change invalidates target-selection feedback so resolution, removal,
expiry, or merge cannot leave a stale all-suppressed label.

## Snapshot preparation

`NpcMemoryEvent.to_dict()` and `from_dict()`, plus
`NpcShortTermMemory.export_snapshot()` and `import_snapshot()`, prepare a stable
serialization boundary. Import tolerates malformed optional metadata, rejects
unknown event types, prunes expired entries, clamps values, preserves valid IDs,
keeps the first occurrence of a duplicate ID, and enforces capacity. It emits one
summarized `memory_changed` notification rather than one notification per row.

The optional `merge_existing` import mode is for runtime ownership transfer. It
combines cached and already-live observations through the normal structured
dedupe rules, makes the live copy authoritative for an identical memory ID,
enforces capacity, and still emits only one summarized change.

## Runtime scene continuity

`NpcMemoryRuntimeRepository` is an autoloaded runtime authority keyed only by an
authored stable NPC ID. It owns:

- Versioned cached snapshots with revision and capture-time metadata.
- One weak live-memory registration per stable NPC ID.
- Monotonic ownership generations and opaque ownership tokens.

```text
live NPC memory
      | unregister
      v
runtime snapshot repository
      | register
      v
replacement live NPC memory

repository stores observations
repository does not perform NPC decisions
```

It does not own behavior decisions or memory events. A focused
`NpcMemoryRuntimeBinding` beside `NpcShortTermMemory` registers the component
after the state machine resolves its NPC, and unregisters from its own
`_exit_tree()` lifecycle. The binding accepts authored location or relationship
IDs and rejects scene-tree paths and generated instance-ID fallbacks.

On ordinary removal, the current token captures the live snapshot and releases
ownership. A later instance with the same stable ID merges that fallback into
its existing live memory. During overlapping scene replacement, registering the
new component first captures the old owner, increments the generation, and
restores into the new owner. A delayed exit from the old instance has a stale
token and cannot overwrite or unregister the replacement. Registering the exact
same component twice is idempotent and does not import twice.

When an NPC is live, repository reads and runtime exports use that component
directly; the cache is fallback state only. Registrations hold `WeakRef`s, so
destroyed nodes cannot be retained accidentally. Dead registrations are cleaned
without inventing a new snapshot. Cached expiry is applied only when the cache
is read, restored, or exported, using authoritative total game hours. There is
no repository process loop and no offscreen memory reasoning.

`clear_all_runtime_memory()` clears both existing live components and cached
fallbacks. The title screen's authoritative Start action invokes it for a new
game. Stale generations still cannot repopulate the cleared cache.

`export_runtime_state()` and `import_runtime_state()` expose a defensive,
versioned runtime transfer format for future ownership integration. Import
replaces each supplied cached fallback and merges into a matching live owner.
These APIs are intentionally not included in `SaveSystem` save files.

## Persistence boundary

Memory snapshots are not fields in `NpcLocations` records and are not interpreted
by `NpcWorldSimulation`. Scene travel and companion restoration retain their
existing responsibilities; continuity follows stable NPC identity through the
binding/repository lifecycle. Disk persistence remains a future explicit
decision. Keep the same separation: storage imports/exports observations,
policies interpret live candidates, and producers retain selection and mutation
ownership. Do not turn memory importance into utility scoring.
