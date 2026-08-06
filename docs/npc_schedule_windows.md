# NPC schedule-window policy

`NpcScheduleWindowPolicy` interprets ordinary `NpcSpotDefinition.active_time_windows`
before `NpcActivitySelector` sends a candidate into the existing activity pipeline.
It is read-only: it does not reserve spots, create action sessions, request states,
start travel, change records, mutate definitions, or display feedback.

```text
schedule window
      ↓
schedule policy
      ↓
on-time grace or late decision
      ↓
existing availability/reservation/session pipeline
      ↓
committed late activity
      ↓
presentation-only feedback
```

## Hard and flexible starts

Every window still requires `start_hour` and `end_hour`. The optional fields are:

```gdscript
{
    "start_policy": "flexible", # default: "hard"
    "grace_game_minutes": 30.0, # default: 0
    "late_priority_bonus": 10,  # default: 0
}
```

A legacy window has the implicit `hard` policy and therefore retains the old
binary behavior: it is eligible from its inclusive start until its exclusive end,
and it may immediately ask the live state's established scheduled-interruption
check. `flexible` changes only the start boundary. During its grace period the
candidate remains eligible, but it cannot interrupt a different busy live primary
activity. An Idle NPC, an exact same-activity continuation, or a free offscreen NPC
may start immediately. After grace, the phase becomes `late` and the existing
availability and per-state interruption ownership applies again. Talk, scripted
control, and emergency ownership remain protected.

Meal-cycle-managed definitions keep their dedicated meal timing and deliberately
bypass this policy. The first authored opt-in is the two `mom_work` windows; Mom's
meals, lesson, shower, and sleep retain their prior configuration.

## Completion policy and bounded overtime

Start policy answers whether a new activity may commit while the window is open.
Completion policy answers how an already committed occurrence behaves when that
window closes. Its optional fields are:

```gdscript
{
    "completion_policy": "finish_current",       # default: "stop_at_window_end"
    "maximum_overtime_game_minutes": 30.0,       # default: 0, safe maximum: 240
}
```

`stop_at_window_end` is the legacy behavior. `finish_current` never reopens
candidate selection after the exclusive window end; it only lets the same
committed activity and action session continue until normal completion or its
absolute overtime deadline. Spot exhaustion, satisfied values, emergencies,
scripted ownership, cancellation, invalid targets, and the existing terminal
paths remain authoritative. No reservation is extended or replaced—the existing
session continues to own its existing reservation until normal cleanup.

The activity stores `schedule_completion_policy`,
`schedule_maximum_overtime_game_hours`, and
`schedule_overtime_end_total_hours`. Continuation evaluates these captured fields
and the captured occurrence key rather than recalculating identity from a later
daily window. This is especially important for cross-midnight occurrences and
large clock jumps.

## Absolute occurrences and priority

Decisions use total game hours. A window occurrence is calculated from its absolute
start day, supports midnight crossings, normalizes hour 24 to 0, and uses a stable
key containing the spot ID, occurrence-start day, and window index. Starts are
inclusive; ends are exclusive. This makes multiple windows, large clock jumps, and
cross-midnight occurrences deterministic.

A flexible decision is `on_time` through the exact grace end, then `late` until the
window closes. While late, its priority bonus is linearly interpolated from zero at
grace end to the authored bonus at window end. Candidate ordering is effective
priority, existing urgency, then stable spot ID. The resource's base `priority` is
never changed. Effective priority is copied consistently into social-seek blocking,
live availability, pending travel, the activity descriptor, action session, and
state request. Existing emergency and non-interruptible state ownership is not
replaced by the policy.

## Live, offscreen, and metadata behavior

For a busy live NPC in flexible grace, the world simulator returns before calling
availability, reservation, route preparation, activity commit, action-session, or
state-request APIs. Developer inspection is available through
`get_schedule_decision_debug_descriptor(npc_id)`, including phase, occurrence,
current state, effective priority, remaining grace, and whether grace caused the
deferral. Stale descriptors are removed when selection/window ownership changes,
an authoritative activity or route takes over, an emergency/scripted owner takes
over, or the activity commits.

Offscreen NPCs have no live primary state. The existing simulator calls schedule
selection only when their record has no activity or pending route, so a free
offscreen NPC may start at window opening while an existing authoritative action
continues unchanged.

Committed activities contain copied `schedule_*` fields for phase, occurrence,
window boundaries, lateness, completion, overtime deadline, base priority, and
effective priority. The same copied values live in action-session metadata and
reach the accepted behavior intention. They do not participate in session
identity. Same-session refresh retains the original occurrence key, and no Node
references are stored.

Live work remains in its existing state when it crosses into allowed overtime;
there is no replacement request or new commitment. Offscreen work uses the same
continuation decision. When a large jump crosses the overtime deadline, elapsed
activity and spot progress is first clamped to the permitted absolute endpoint,
then the existing finish path runs. Progress beyond the deadline is never applied.

Scheduling ownership is gameplay state, not presentation. The world simulator
uses `NpcStateMachine.get_scheduled_activity_ownership_gate()`, which directly
inspects scripted claims, interaction ownership, primary emergency state, active
action, and the structured current intention. It never reads
`get_feedback_descriptor()`, `StateLabel`, formatted strings, or player cues.

## Lateness feedback and deferred missed schedules

`schedule_running_late` displays **Running late** only after `NpcLocations` has
committed the activity record and `NpcWorldSimulation` publishes that definitive
commit. Candidate inspection, grace deferral, availability/reservation/route/state
failure, on-time commits, restored records, same-session refresh, and offscreen-only
execution are silent. The feedback adapter filters to the matching live NPC and
only submits a presentation cue; it changes no schedule or behavior state.

`schedule_finishing_up` displays **Finishing up** once when the matching live,
authoritative session crosses from its window into allowed `finish_current`
overtime. It is distinct from **Running late**, which describes the initial late
commit. Offscreen crossings, restored activity already in historical overtime,
legacy completion, stale sessions, repeated updates, and activities completed
before the boundary are silent. The overtime event remains one-way presentation
observability and cannot authorize continuation.

Missed-window consequences are intentionally deferred. A later pass should consume
closed occurrence records from an authoritative occurrence/history owner rather
than infer failure from a selector poll, because no persistence field currently
proves that a particular occurrence was expected but never committed.
