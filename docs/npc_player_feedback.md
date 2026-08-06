# Player-facing NPC intention feedback

## Presentation boundary

Player feedback is a read-only presentation consumer. Existing behaviour systems
remain authoritative for intentions, priorities, commitment, state transitions,
targets, reservations, action sessions, needs, relationships, and memory.

```text
structured behaviour or memory event
              |
              v
       feedback catalog
              |
              v
       feedback presenter
              |
              v
       short visual cue

feedback never flows back into behaviour
```

The feedback layer never requests a state, evaluates a candidate, reserves a
target, creates an action session, or changes memory. It consumes signals that
are emitted only after those systems have made an authoritative decision.

## Components and ownership

`NpcFeedbackCue` is a lightweight `RefCounted` value. It contains stable cue,
intention, action-session, and memory identities; a stable localization key and
fallback text; category, icon key, priority, duration, cooldown, replacement
policy, creation time, bounded maximum lifetime, and copied metadata. The maximum
lifetime is clamped so it can never be shorter than the visible duration.
Metadata is sanitized so cues never retain `Node` references. Rendered text is
not cue identity.

`NpcFeedbackCatalog` is the only mapping from stable behaviour or memory codes
to player-facing defaults. Behaviour code does not contain presentation wording.
Each catalog entry supplies:

- `text_key` for future localization and a concise English fallback.
- Optional `icon_key`, which may remain unresolved without hiding the text.
- Category and priority.
- Visible display duration, absolute maximum lifetime, and cooldown.
- One of four explicit replacement policies: `replace_lower`, `queue`,
  `ignore_if_duplicate`, or `refresh_existing`.

`NpcFeedbackPresenter` owns the current cue, a queue of at most three, cooldowns,
timing, visibility, and one reusable visual instance. It never inspects NPC
behaviour. `NpcFeedbackAdapter` connects authoritative controller, memory, policy,
state, and scripted-control signals to catalog cues.

The canonical NPC state-machine scene contains both presenter and adapter beside
the memory components. The visual is attached once to the live NPC so it follows
the NPC's world transform naturally. Cue changes update the existing label and
optional texture slot; they do not rebuild the node tree.

## Initial mappings

The initial restrained mappings are:

| Structured code | Player fallback |
| --- | --- |
| `hunger_high` | Hungry |
| `tired_high` | Tired |
| `boredom_high` | Needs a break |
| `social_need_high` | Looking for company |
| `conversation_refused` | Recently refused |
| `harmed_by_actor` | Upset with you |
| `schedule_running_late` | Running late |
| `schedule_finishing_up` | Finishing up |
| `target_unavailable` | That place is unavailable |
| `movement_failed` | Can't reach that |
| `intention_target_lost` | Lost track of that |
| `all_social_candidates_suppressed` | Waiting before talking again |
| `all_targets_recently_failed` | Waiting before trying again |
| `trying_another_place` | Trying another place |
| `emergency` / `anger_high` | In danger |

The adapter uses `reason_code`, source, logical action, policy result codes, and
event type. It does not parse legacy request strings, developer feedback text, or
the `StateLabel`.

## Intention event rules

A cue is submitted once for a genuinely accepted or meaningfully replaced:

- Need-sourced Eat with `hunger_high`.
- Need-sourced Rest with `tired_high`.
- Need-sourced Recreation with `boredom_high`.
- Social-AI Talk search with `social_need_high`.
- An explicit emergency source, using a known emergency reason code or the safe
  generic emergency mapping.

The adapter deliberately ignores same-session refresh, MoveToTarget arrival
phase changes, commitment countdowns, lifecycle-only intentions, internal Idle,
reconciliation, repeated value evaluation, routine Work, Sleep, travel, schedule,
scripted, and manual intentions. The controller's existing
`intention_refreshed` signal is not connected to player feedback.

Late schedule feedback uses a stricter boundary than accepted intention. A live
scheduled travel intention can be accepted before its persistent activity record
is committed, so `NpcWorldSimulation.scheduled_activity_committed` is emitted
only after `NpcLocations` stores the authoritative activity. The adapter requires
the matching live NPC, `schedule_phase == "late"`, a stable occurrence key, and
a new session before submitting `schedule_running_late`. Candidate inspection,
grace deferral, on-time starts, failed reservations/routes/state requests,
same-session refresh, restored records, and offscreen-only execution remain
silent. This committed signal is copied observability and cannot affect behavior.

Overtime feedback uses a separate live boundary signal. The world simulator emits
`scheduled_activity_entered_overtime` only when an already observed live activity
crosses its captured absolute window end while the same `finish_current` session
may still continue. The adapter verifies that the live state machine still owns
that session and submits `schedule_finishing_up` once. Offscreen transitions,
restored historical overtime, expired overtime, stale sessions, and legacy
stop-at-end schedules remain silent. The feedback signal does not decide whether
work continues.

Candidate inspection remains silent. For an ordinary live need action, the state
machine emits `activity_target_selection_committed` only after all normal gates
have accepted an alternative: an earlier target was suppressed by target-failure
memory, a later stable target was selected, reservation and state change
succeeded, and the accepted active session and intention both identify that
target. The adapter then maps that copied outcome to `trying_another_place`.

No outcome is emitted for blocked-all selection, an unsuppressed first choice,
rejected commitment or state transition, reservation failure, a missing or
mismatched session, repeated observation of the same session, or scheduled,
scripted, manual, social, combat, travel, and player-driven requests. Movement
and arrival phases of the accepted session do not emit again. This signal is
observability after commitment; it cannot influence the selection or request.

## Memory and policy event rules

A new live `conversation_refused`, `target_unavailable`, `movement_failed`, or
`intention_target_lost` memory can submit a cue. A new live `harmed_by_actor`
memory also submits a cue only when its subject ID matches a currently live
player's stable identity. NPC-on-NPC harm is silent in this first player-facing
mapping, so it can never falsely render actor-directed wording. Raw actor IDs are
never rendered. An active cue may refresh when the same memory merges; otherwise
its identity-aware cooldown prevents repeated planning passes from spamming it.

Conversation completion, memory expiry, eviction, resolution, removal, generic
action failure, and internal diagnostics are not presented.

Snapshot import emits only the memory component's summarized `memory_changed`
signal. The adapter listens to `memory_added` and `memory_merged`, so repository
restoration cannot replay historical observations. A later new live observation
is presented normally. Presenter state is absent from repository snapshots and a
current cue is intentionally not transferred across scene replacement.

The state machine emits a copied presentation signal when its existing structured
policy descriptor changes. The blocked final outcomes
`no_social_target_due_to_recent_memory` and
`all_targets_recently_failed` create blocked-all cues. Candidate inspection,
allowed candidates, and repeated unchanged descriptors do not. Successful
alternative selection uses the separate post-commit outcome described above,
never this pre-request policy descriptor. The social cue keeps its generic text
and carries aggregate suppression counts by structured reason; it does not expose
candidate identities or emit one cue per candidate.

## Arbitration, queues, and cooldowns

Problems and emergencies outrank routine needs and social intentions. A movement
failure can replace Hungry; Hungry cannot replace a current movement failure.
The priority-75 harm-memory cue can replace routine needs but cannot replace the
priority-100 emergency cue. An emergency can replace any ordinary cue.

Duplicate identity is based on structured codes and source IDs. Cooldown keys add
subject, target, or logical-action identity where required. They are never shown
to the player. The three-entry queue is ordered deterministically by priority,
creation time, and cue ID. When full, a lower queued cue may be discarded for a
more valuable one, but a routine cue cannot displace a queued problem or
emergency. Queued cues keep their original creation time and are pruned against
their explicit maximum lifetime before they can become current. Queue expiry has
the structured reason `queued_lifetime_expired`. Cooldown storage is capped.

## Visibility and suppression

A selected current cue is not yet a presented cue. `cue_started` means the
presenter selected it; `cue_presented` means the attached visual actually became
visible to the player. A newly selected cue checks visibility immediately, while
subsequent distance checks use the configured 0.2-second cadence. Suppression
changes also reevaluate immediately. `cue_visibility_changed` is emitted only
when the visible state changes.

The panel appears only while its visual is attached, its NPC is live, the cue is
current, player feedback is enabled, the player is in the active scene and
within the configured 280-pixel distance, and no suppression source is active.
Player discovery is cached.

Each current cue has two clocks. Visible elapsed time advances only while the
attached visual is actually visible and pauses while distant or suppressed.
Absolute elapsed time advances whenever the cue is current. If visibility
returns before the maximum lifetime, the remaining visible duration resumes. A
cue that was presented finishes after its visible duration, or with
`maximum_lifetime_elapsed` if its absolute bound arrives first. A cue that never
became visible finishes with `unseen_lifetime_expired`.

Cooldown begins exactly once, on first actual presentation. Selecting, queueing,
or expiring a cue unseen does not create a cooldown, so a later opportunity to
show that information is not blocked by something the player never saw.
Repeated hide/show transitions and refresh of an already presented cue do not
restart cooldown bookkeeping.

`refresh_existing` preserves the active cue's original `cue_id`,
`created_at_usec`, maximum-lifetime value, and absolute elapsed clock. It may
replace copied metadata such as `occurrence_count` and, after the cue has already
been presented, reset only visible elapsed time so the updated content can be
seen. An unseen refresh preserves both clocks. Refresh never emits
`cue_presented` again or restarts cooldown, and repeated refreshes cannot move the
original absolute expiry anchor. A later cue accepted after normal completion
and cooldown receives a new identity and lifetime normally.

Ordinary cues pause visible time, while retaining their bounded absolute
lifetime, during:

- Modal dialogue.
- Scripted NPC control.
- Timed Talk overlays.
- Downed, collapsed, or dead presentation.
- Scene loading and teardown.

The visual has no collision or input behavior and all controls ignore mouse
input.

## Developer feedback remains independent

`player_feedback_enabled` controls the compact player panel.
`developer_state_label_enabled` separately controls the existing detailed
`StateLabel`. The label keeps its intention, rejection, commitment, memory, and
policy diagnostics and does not feed the player presenter.

## Performance and extension points

The catalog is static. Adapters are signal-driven. The presenter stops processing
when current and queued feedback are empty, maintains only a three-item queue and
a capped cooldown map, caches the player reference, and updates label text only
when a cue changes. Routine need/social and alternative cues use conservative
four-second maximum lifetimes, problem/failure cues use six seconds, and
emergencies use four seconds.

Final art can be added by assigning textures to stable `icon_key` values without
changing behaviour code. Localization can add translations for
`npc_feedback.<cue_code>` while retaining current fallbacks. Neither extension
changes cue identity, policy, or gameplay authority.
