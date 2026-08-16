# NPC behaviour intent and commitment

This compatibility layer adds an observable decision identity above NPC primary
states without replacing the existing execution systems. It is deliberately a
foundation for later memory, not memory itself.

## Responsibilities

- `NpcBehaviorIntent` describes a request: requested primary state, logical
  action, semantic source, stable reason code, feedback text, originating
  value, priority, stable target ID, and existing action-session ID. It never
  owns a live target or execution.
- `NpcBehaviorController` remembers the accepted intent and applies the small
  commitment/hysteresis rule. Evaluation is separate from commit so rejected
  candidates cannot mutate actions, targets, or reservations.
- `NpcStateMachine` remains the transition boundary. Individual `can_exit_to()`
  methods remain the final state-specific safety checks.
- `NpcActionSession` remains authoritative for executable action identity and
  lifecycle, including reservation IDs.
- Existing target fields and `NpcLocations`/`NpcWorldSimulation` retain their
  compatibility, routing, and simulation responsibilities.
- `NpcSocialMemoryPolicy` may reject a newly considered NPC conversation
  candidate before submission. It cannot modify priorities, commitments,
  reservations, targets, or action sessions.
- `NpcTargetMemoryPolicy` may temporarily reject a newly considered ordinary
  activity spot after a matching terminal target failure. It is read-only and
  runs before the candidate becomes an intention or action session.

An intent answers "what is this NPC trying to do?", a primary state answers
"which implementation is running?", and an action session answers "which
executable action transaction is current?". `MoveToTarget` can therefore be the
primary state while `Eat` is the logical intent and action-session kind.

## Explicit producer metadata

Default value rules declare `behavior_source`, `behavior_reason_code`,
`behavior_feedback_text`, and `behavior_origin_value`. The live
world-simulation social-search path submits the same structured fields through
`request_behavior_intent()`. Human-readable request strings may change without
changing source or identity.

Old/custom rules and legacy assignment APIs still work. Their source is inferred
in one compatibility helper and their intent metadata is marked
`legacy_derived`. Action-session descriptor metadata and typed intentions always
win over this fallback. Remaining unmigrated categories include direct legacy
assignment helpers, perception/event callers outside the default rule table,
and old saved action descriptors without semantic metadata.

## Commitment policy

Only competing candidates sourced as `need` or `social_ai` are restricted.
During the first two real seconds of a committed intention, such a candidate
must reach the current priority plus the 15-point interruption margin. Matching
action-session IDs always continue the same intention. Without session IDs,
logical action, source, and stable target ID must all match.

Emergency, event-reaction, schedule, scripted, player, travel, manual, and
internal requests bypass the generic gate.

## Stable identity and lifecycle

An accepted intent keeps one `intent_id`, creation timestamp, action-session ID,
and commitment start throughout movement, arrival, same-state re-entry, and
descriptor refresh. Execution-facing fields are updated with a refreshed copy;
producer-owned objects are not mutated and refreshes do not emit replacement
events.

Lifecycle-only transitions describe execution housekeeping rather than goals.
Initial/bare Idle, state returns, reconciliation, stale recovery, cleanup, and
same-session phase transitions bypass commitment. A matching lifecycle phase may
refresh the current goal, but an unrelated lifecycle request cannot replace it.
Terminal callbacks clear only the intention whose session ID matches.

Talk remains an interaction overlay rather than a primary-state replacement, so
it stays outside this primary-intention gate.

## Memory-informed social eligibility

Recent explicit NPC-to-NPC refusal is an eligibility rule, not an intention
competitor. The requester queries its passive `NpcShortTermMemory` through
`NpcSocialMemoryPolicy` after ordinary candidate validation and before the social
planner reserves a pair or calls `request_behavior_intent()`. A suppressed
candidate therefore never produces `behavior_commitment_active` rejection
feedback, never restarts commitment time, and never creates a proposed action.

The default suppression lasts 0.25 authoritative game hours from the memory's
last update, independently of the longer memory lifetime. Other allowed
candidates retain their existing order. If all eligible NPC partners are
temporarily suppressed, normal non-social and scheduled fallbacks remain
available. Established approaches and Talk sessions are not reevaluated by this
policy; their existing action-session and pairing ownership stays authoritative.

The world-simulation social boundary always performs lightweight candidate
discovery at its normal cadence. The earliest refusal retry remains observable,
but no longer acts as a requester-only early-return cache; newly present or
newly available partners can be selected before another partner's delay expires.

## Memory-informed activity eligibility

Default live Eat, Rest, and Recreation need rules enumerate ordinary candidates
before submitting an intent. The same adapter supports ordinary `need`-sourced
Sleep and Work rules, although the project's current Sleep and Work producers
are authoritative/manual rather than default need rules.
`NpcTargetMemoryPolicy` skips only a candidate matched by unresolved, unexpired
`target_unavailable`, `movement_failed`, or `intention_target_lost` evidence.

The order is validity, read-only memory eligibility, commitment evaluation,
session creation, reservation, target installation, and state entry. A
suppressed target therefore cannot produce commitment rejection or restart the
current intention. An allowed alternative proceeds through the existing
pipeline once. If all candidates are suppressed, the current primary state,
need, accepted intention, and action ownership remain unchanged; no fake Idle
intent or failure memory is produced.

Active sessions are never continuously filtered. Movement and arrival refresh
the same accepted intention by session identity exactly as before.

## Transaction ownership and runtime hot paths

The following rules are performance contracts as well as correctness contracts:

- One gameplay cause produces at most one directed relationship transaction per
  owner/subject pair. Damage therefore commits its favor, anger, and fear changes
  together. Splitting one hit into several writes repeats identity resolution,
  relationship signaling, EventBus delivery, and presentation refresh on the main
  thread.
- A committed value change may propose a reaction, but the current primary state
  still owns interruption. The state machine checks the existing `can_exit_to()`
  contract before constructing reaction intent, action-session, and feedback work.
  Fight, Talk, emergency, and scripted protection are not weakened by this check.
- A persistent scheduled activity remains authoritative between live execution
  cycles, including the short interval after its live action is marked completed
  and before world simulation resumes or finishes the persistent record. A new
  `need` or `social_ai` session cannot erase that activity in this interval; the
  exact scheduled session can continue normally.
- If a higher-authority source such as emergency or scripted control legitimately
  supersedes a scheduled activity, the persistent record and its spot reservation
  change in the same operation. Periodic reservation repair is recovery for corrupt
  or old data, not a normal activity-lifecycle step.

The diagnostic signatures for violations are repeated
`ReactToEvent reason=cannot_exit_Fight`, a newly committed schedule immediately
following a stale autonomous callback, or `NPC reservation repair ... removed=1`
after a session replacement. These are symptoms of duplicated work or split
ownership at a transaction boundary. They can stall the main thread and make all
input and physics interactions feel rough even when the interaction subsystem is
not the source. The rope system is deliberately outside this contract and is not
modified by these fixes.

### Live-resume action cleanup

When a committed offscreen activity resumes on a live NPC, the state machine may
first cancel a stale need or social action. Cancellation publishes that old
session with a terminal status before the scheduled replacement becomes active.
The terminal publication is lifecycle cleanup; it is not an accepted replacement
owner and must not clear the separately committed activity or release its spot.

`NpcLocations.sync_live_action_descriptor()` therefore allows a different
session to supersede a committed activity only when the incoming descriptor is
`active`. A mismatching failed, completed, cancelling, or cleared descriptor is
ignored at the persistent ownership boundary. A genuinely active emergency or
scripted action still clears the activity and releases its claim atomically.

The former failure signature was:

```text
activity_superseded released=1
NPC action names a spot without owning it
LookForTalkTarget reason=moving_to_target
live_seek_rejected
new scheduled activity committed
```

In that sequence, social search was not the cause. The persistent activity had
already been deleted by the stale action's terminal callback, so the planner saw
an apparently idle record while the live state machine was still moving. It tried
social search, correctly received `moving_to_target`, then fell back to scheduling
the same routine again under a new session. The breadcrumb
`npc_locations:activity_preserved_on_action_cleanup` now records any protected
cleanup handoff without adding normal console noise. The focused regression lives
in `test_scheduled_activity_transaction_runtime.gd` and exercises the complete
stale-live-action to committed-schedule resume path.

## Developer feedback

The overhead label is formatted by `NpcBehaviorFeedbackFormatter`, which has no
gameplay authority. It prefers explicit feedback text, shows the logical action
behind movement, preserves `State + Talk`, updates visible commitment countdowns
four times per second, and exposes the same structured feedback descriptor for
a later presentation component.

## Future memory

Future utility selection and short-term memory can propose intents to this
controller, but must still let the state machine and action-session/reservation
contracts perform execution. Memory must consume stable reason codes and
immutable creation snapshots, never parse request strings or label text.

The live monotonic commitment timer is intentionally not serialized. Offscreen
simulation parity and persistent memory remain future work.

## Native tests

The project uses deterministic `SceneTree` runtime tests and no external test
framework. Former framework-dependent pure-system tests now inherit the small
native `test/native_scene_tree_test.gd` runner, exit nonzero on failure, and
retain their assertions and per-test cleanup. Behaviour policy, provenance,
identity, lifecycle, reservation safety, and feedback coverage live in
`test_npc_behavior_commitment_runtime.gd`.
