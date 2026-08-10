# NPC social planning

Autonomous social planning enumerates same-scene partners, applies every existing
hard eligibility rule, then ranks only the remaining candidates with
`NpcSocialCandidateScorer`.

```text
candidate
   |
   v
availability and memory eligibility
   |
   v
relationship-aware score
   |
   v
deterministic ranking
   |
   v
existing reservation/session/intention
```

## Eligibility before scoring

Identity, scene, availability, participant ownership, minimum relationship, and
`NpcSocialMemoryPolicy` checks remain hard gates. The memory policy recognizes
refusal (0.25 game hours), harm by the candidate (0.5), and completed conversation
(0.125). A rejected candidate receives no score and cannot be restored by another
component.

Filtering occurs before participant reservation, social-session creation,
intention submission, or talk-need payout. A blocked preferred
`social_visit_target_id` cannot override the filter, but its authored value is
retained and another allowed candidate can win normally.

## Directed relationship score

The score uses the requester's directed relationship row toward the candidate.
The candidate's opinion is not substituted. The existing bidirectional minimum-
favor eligibility check remains a separate hard gate for NPC candidates.

Every relationship input is clamped to `0..100`. Missing favor and trust are
neutral `50`; missing love, lust, shame, anger, fear, and suspicion are neutral
`0`. Version 3 relationship rows store all eight as canonical owner-to-subject
opinions. Love is therefore available to the scorer from real production rows.
Trust, lust, shame, and suspicion remain persistent story currencies and do not
affect this score yet.

```text
favor contribution = ((favor - 50) / 50) * 30    [-30, +30]
love contribution  = (love / 100) * 15           [  0, +15]
fear contribution  = -(fear / 100) * 15          [-15,   0]
anger contribution = -(anger / 100) * 30         [-30,   0]

relationship score = sum of those components     [-75, +45]
authored preference bonus                         +20
live distance penalty = -min(distance / 128, 10) [-10,   0]
final total is clamped                            [-100, +100]
```

The preference bonus can beat a modest relationship difference, while very low
favor or strong anger can still outweigh it. The bonus is applied only after
eligibility, never cleared when another target wins, and never grants eligibility.

Distance is a secondary live convenience factor. It applies only when requester
and candidate have meaningful live positions. It is capped at ten points, so a
clearly stronger relationship can beat a large distance difference. Offscreen
record positions do not count as live distance and contribute zero.

Allowed candidates sort by total score, then shorter live distance when present,
then lexicographic stable social candidate ID. The planner has no separate
candidate urgency tier, so no incidental dictionary, scene-child, creation, or
random order remains in the final tie.

## Player, diagnostics, and lifecycle

The player remains the social candidate `__player__`, while its relationship row
uses the relationship service's canonical identity for the live player actor.
The player gets no automatic bonus. Directed favor can rank it first, while
existing `__player__` harm or completion memory can remove it before scoring.
Player-initiated interaction remains separate.

When every candidate is blocked, the planner reports
`no_social_target_due_to_recent_memory` and the existing “Waiting before talking
again” cue remains sufficient. Ordinary behavior cues do not reveal numeric
scores. The pause menu's explicit Characters inspection page may show the saved
owner-to-subject metrics; developer descriptors expose copied score components,
allowed or blocked state, and the selected stable ID without retaining
relationship or memory objects.

Filtering and scoring apply only to new target selection. Accepted approaches,
reserved pairs, active Talk overlays, and active social action sessions are not
polled, rescored, retargeted, or cancelled. An explicit target already owned by a
social action session remains authoritative through completion.

World planning ranks live and offscreen candidates. Offscreen ranking uses
globally persistent relationship rows but no distance; memory filtering remains
unavailable without a live memory component. Fresh live `LookForTalkTarget`
selection uses the same scorer after its availability and memory gates. The world
descriptor can include blocked and scored candidates; the live descriptor
contains the already-eligible candidates presented to its scorer.

Completed conversation remains a short reset, not a positive episodic score.
Interpreting helpful or pleasant episodes as lasting preference is deferred.
Current positive ranking comes only from authored preference and directed
relationship data.

## Candidate-owned social acceptance

Requester selection and candidate acceptance are deliberately separate. The
requester ranks eligible partners using its own memories and its directed
relationship row. Immediately before a new autonomous mutual Talk commits, the
approached NPC evaluates a copied request context using its own execution state,
short-term memory, and directed relationship toward the requester.

```text
requester selects candidate
            |
            v
candidate execution availability
            |
            v
candidate social acceptance policy
       +----+----+
       |         |
       v         v
 temporary     social
 unavailable   decline
       |         |
       v         v
 no memory     refusal memory
```

The structured result is `accepted`, `temporarily_unavailable`,
`social_decline`, or `invalid_request`. Stable requester and candidate IDs and a
machine-readable reason accompany every decision. Availability is checked first:
stale identity/session data, scripted ownership, disabled or emergency state,
scene transition, an existing interaction or social session, protected task
priority, and the primary state's existing Talk compatibility remain hard state-
machine decisions. The stateless `NpcSocialAcceptancePolicy` does not duplicate
those rules and never requests a state, reserves a participant, creates a
session, or stores a Node.

Only a technically available candidate reaches private social evaluation. A
recent `harmed_by_actor` memory about the requester is a `social_decline` for the
existing 0.5-game-hour social harm delay. A recent completed conversation is
`temporarily_unavailable` for the existing 0.125-game-hour repeat delay. A prior
refusal is intentionally ignored here, preventing recursive self-reinforcement.
Conservative configurable relationship thresholds initially decline below 20
candidate-directed favor, at 70 or more anger, or at 80 or more fear. These use
the candidate-to-requester row, the opposite direction from requester scoring,
and do not request Fight or Flee. The older bidirectional minimum-favor gate
remains authoritative outside the policy.

Busy is not rejection. Temporary and invalid outcomes install no Talk overlay,
pay no Talk need, start no personal-refusal cooldown, and create no
`conversation_refused` memory. The request simply returns to the existing
requester-owned action and planner lifecycle. Provisional participant
reservations remain released by `NpcSocialPlanner.finish_session()` and action-
session rollback remains in the existing requester state/session owners; the
candidate policy has no cleanup authority and never starts an immediate search
for another target.

A genuine social decline creates one requester-owned `conversation_refused`
observation whose subject is the declining candidate. Its metadata copies both
`decision_kind = social_decline` and the stable `refusal_reason_code`. The
existing requester memory policy then prevents immediate retry of that partner
while leaving other candidates eligible. The private subtype is diagnostic, not
new player feedback; the existing concise recent-refusal presentation remains
sufficient.

Acceptance is a one-time pre-commit decision. Once both Talk overlays and the
shared action-session identity are accepted, changing relationships or adding a
memory does not poll or cancel the conversation. Damage, completion, payout, and
teardown retain their existing owners. Player interaction never calls candidate
social acceptance: menus, timed player Talk, dialogue, trade, and travel continue
through their existing interaction and harm-memory gates.
