# Architecture, efficiency, and test audit

**Project:** 2D Platformer RPG — logic first  
**Audit date:** 2026-08-27  
**Engine used:** Godot 4.6.2 stable  
**Branch:** `main`  
**Scope:** Read-only review of runtime architecture, project configuration, deployment configuration, documentation, static code shape, startup behavior, and all discoverable runtime tests. No game code was changed as part of this first pass.

## Executive summary

The project has a strong systems foundation: gameplay content is substantially data-driven, inventory and save operations are designed transactionally, the NPC simulation has explicit ownership concepts, and there is an unusually broad runtime-test inventory for a project at this stage. The project imports, exports, and reaches both the title screen and a gameplay scene under Godot 4.6.2.

The main risk is no longer lack of systems; it is integration complexity. NPC behavior, world simulation, identity, scheduling, animation, reservations, and scene travel now meet in a few very large and dynamically coupled modules. The two largest production scripts contain almost 13,800 lines between them, and several current test failures occur at precisely those subsystem boundaries.

Current verification result across 92 discovered runtime tests:

- **85 passed** in their correct script or scene harness.
- **6 test files have reproducible failures.** These contain a mix of genuine behavioral regressions and outdated expectations; they are classified individually below.
- **1 scene test is broken/inconclusive** because its coroutine accesses a freed object and then never terminates.
- A large portion of otherwise green runs emit shutdown leak/resource warnings, which makes the suite noisy and can hide new warnings.

The highest-priority actions are to restore a trustworthy one-command test runner, resolve NPC identity semantics, fix behavior-arbitration regressions around same-state retargeting and monster reacquisition, and make the loot exclusion clock deterministic. Architectural decomposition should follow those correctness fixes, guided by tests rather than performed as a broad rewrite.

## Audit constraints and snapshot status

The repository was actively changing while this audit ran. At the final inventory point the working tree contained **157 status entries: 92 tracked changes and 65 untracked entries**. Godot also saved project files during the test window. One route-arrival test failed during the original suite and passed when rerun after those saves; it is therefore not listed as a reproducible defect.

This report is a snapshot of the workspace as observed on 2026-08-27. The large uncommitted change set was preserved. It is not itself treated as a code defect, but it limits exact reproducibility and increases integration risk.

## Architecture overview

The runtime is organized around a conventional Godot scene/component layer plus a large global service graph:

```text
WorldTime / EventBus
        |
        v
NpcWorldSimulation <-> NpcLocations <-> NpcSceneRoutes
        |                    |
        |                    v
        +------------> live SocialNpc instances
                              |
                              v
                  NpcStateMachine -> state nodes
                       |       |       |
                       v       v       v
                  behavior   action   animation / movement
                  intents     session

Player / NPC inventory -> transactional services -> trade / food / equipment
SaveSystem <-> progression, relationships, NPC location/simulation, inventories
```

There are **22 autoloads**, including world simulation, locations, routes, relationships, time, save, progression, dialogue, UI, ambient audio, diagnostics, and player runtime. This makes the application convenient to address globally, but also means every isolated runtime test boots most of the game.

Static inventory at the end of the audit:

- 342 GDScript files and approximately 122,735 GDScript lines including tests.
- 249 non-test scripts and approximately 85,773 production GDScript lines.
- 69 `_process`/`_physics_process` callbacks found in the earlier static scan.
- 358 direct `/root/...` lookups, 860 `has_method` checks, and 1,932 dynamic `.call(...)` sites found in that scan.
- The largest production files are:

| File | Lines |
|---|---:|
| `scenes/creatures/npc/npc_state_machine.gd` | 7,698 |
| `scripts/systems/npc_world_simulation.gd` | 6,089 |
| `scripts/systems/npc_locations.gd` | 2,504 |
| `scripts/creatures/social_npc.gd` | 2,465 |
| `scripts/systems/npc_meal_cycle_runtime.gd` | 1,946 |
| `player/scripts/npc_talk_interactor.gd` | 1,735 |
| `scripts/things/rope.gd` | 1,567 |
| `scripts/creatures/npc_platform_traversal.gd` | 1,556 |
| `scripts/instances/npc_work_spot.gd` | 1,494 |
| `scripts/systems/relationships.gd` | 1,460 |
| `player/scripts/player.gd` | 1,451 |

Line count alone is not a defect. In this case, however, the largest files also own many distinct policies and use extensive dynamic dispatch, so size is a useful indicator of responsibility and change-risk concentration.

## Verification performed

| Check | Result | Notes |
|---|---|---|
| Godot project import | Pass | Clean headless import with Godot 4.6.2. |
| Windows export-pack build | Pass | Produced a valid pack of approximately 26.6 MB. |
| Title-screen smoke run | Pass | 360 headless iterations, no project warnings/errors. |
| `realtest1` gameplay smoke run | Pass with warnings | Scene remained alive for 360 iterations; Dad, Maid, and Bob rejected `idle` animation because their inherited blueprint has no `AnimationPlayer`. |
| Runtime-test discovery | 92 found | 89 script-driven tests and 3 scene-driven tests. |
| Runtime-test execution | 85 pass / 6 fail / 1 broken | Corrected for tests that require their `.tscn` harness rather than direct script execution. |
| Existing performance evidence | Needs follow-up | Historical watchdog log shows stable 60 FPS between spikes, but repeated 37–150 ms spikes. The watchdog is currently disabled, so this is indicative rather than a current benchmark. |

The first complete script pass took approximately **9 minutes 46 seconds** because almost every test launches a separate Godot process and boots the full autoload graph. There is no repository-level CI workflow or authoritative one-command test manifest, so correct scene-versus-script invocation had to be inferred.

## Detailed findings

Priority meanings used here:

- **P1:** correctness or delivery-confidence issue to address before the next integration/release checkpoint.
- **P2:** material architecture, performance, presentation, or maintainability issue for the next focused iteration.
- **P3:** cleanup or process improvement that reduces future risk.

### F-01 — P1 — Behavior arbitration rejects valid retarget/reacquisition transitions

**Evidence**

`test_activity_identity_runtime.gd` reproducibly fails these expectations:

- Same-state work request can retarget.
- An accepted same-state request commits the new work target.
- An ambiguous rejection leaves the active target unchanged.

`test_talk_behavior_runtime.gd` also reproducibly fails to find and fight the next monster after the current target changes.

The evidence points to the boundary between behavior commitment and state identity. In `npc_state_machine.gd`, `_request_state_direct` evaluates a behavior candidate before handling same-state identity/re-entry. A currently committed behavior can therefore reject an equal-priority retarget before the state gets a chance to decide whether the new target is a legitimate re-entry. `LookForMonster` to `Fight` appears to encounter the same lifecycle-versus-new-intent ambiguity.

**Impact**

NPCs can remain committed to an outdated work or combat target, and a caller may receive a rejection after part of the intended target lifecycle has already changed.

**Recommendation**

Define one atomic transition contract for `(state, activity identity, target, source, priority)`. Same-state identity changes and action-lifecycle transitions should be classified before generic commitment rejection. Add assertions that a rejected request is side-effect free, and cover equal-priority retarget, higher-priority retarget, target deletion, and monster reacquisition.

### F-02 — P1 — NPC canonical ID and relationship ID contracts have diverged

**Evidence**

`test_npc_social_candidate_scorer_runtime.gd` reproducibly fails the shared directed-ranking formula and the combined actor/perception candidate ranking.

`NpcIdentity.get_stable_actor_id` prioritizes `get_npc_location_id()` before `get_relationship_id()`. `Relationships.get_relationship_id()` now delegates to that canonical actor ID. The failing fixture, however, stores directed relationship data under explicit relationship IDs such as `live_seeker_rel` and `liked_rel`, while location IDs are `live_seeker` and `liked`. The relationship lookup therefore misses the directed graph and neutral distance scoring wins.

**Impact**

Social choice can silently ignore favor/relationship data when saved or authored keys follow the older relationship-ID contract. This is particularly risky because the result remains plausible rather than crashing.

**Recommendation**

Choose and document one authoritative key:

1. If canonical actor/location ID is authoritative, migrate relationship save data and authored fixtures, remove or deprecate the separate relationship-ID surface, and version the save migration.
2. If relationship ID is intentionally distinct, make relationship code request it explicitly and use canonical actor ID only for location/simulation ownership.

Add a contract test that round-trips IDs through live actors, off-screen records, relationship save data, and candidate scoring.

### F-03 — P1 — The test suite is not yet a trustworthy automation gate

**Evidence**

The repository has no single runner or manifest for its mixed harness. Of the 92 tests:

- 32 use the native scene-tree harness.
- 57 directly extend `SceneTree`.
- 3 extend `Node` and must be run through a corresponding scene.

`test_loot_magnet_runtime.tscn` is currently broken. Its test loop calls `loot.is_queued_for_deletion()` after the loot instance has already been freed. The coroutine aborts before `_finish()` can quit the tree, so an unconstrained run hangs. A frame-limited Godot invocation can then exit with code 0 despite the script error, creating a false green result.

The initial suite also contained at least 54 green runs with warnings, commonly `ObjectDB instances leaked` and resources still in use at exit. Some warning/error output is intentionally exercised validation, but it shares the same channel as unexpected engine diagnostics.

**Impact**

Automation can hang, pass after script errors, or hide new lifecycle warnings in existing noise. A contributor cannot reliably reproduce the full result with one documented command.

**Recommendation**

- Add a test manifest that records script versus scene entry points and a runner that enforces per-test timeouts.
- Require an explicit success sentinel as well as exit code 0, and fail on `SCRIPT ERROR`, engine `ERROR`, or timeout unless whitelisted by the test.
- Fix the loot test by checking `is_instance_valid(loot)` before any method call and by guaranteeing tree shutdown in a failure/finalization path.
- Free test-owned nodes and disconnect retained callables so green tests end cleanly.
- Run the suite in CI on every integration branch.

### F-04 — P2 — Loot pickup exclusion mixes wall-clock time with game-time behavior

**Evidence**

`test_inventory_dump_runtime.tscn` reproducibly fails because a dumped player never becomes eligible after the test advances beyond the exclusion duration. `world_loot_container.gd` stores and compares exclusion expiry with `Time.get_ticks_msec()`, while the loot node otherwise participates in scene/game processing and the test advances a `SceneTreeTimer`.

In a fast headless run, game time can advance farther than wall time, so the exclusion has not expired. In gameplay, the inverse policy issue also exists: wall-clock exclusion continues expiring while the pausable game tree is paused.

**Impact**

The cooldown is nondeterministic under tests, pause, time scale, and frame scheduling.

**Recommendation**

Use one explicit time domain. For a gameplay cooldown, decrement remaining seconds from processed delta or use a game-clock service that respects pause/time scale. If real elapsed time is intentional, document it, name it accordingly, and test with an injected clock rather than a real delay.

### F-05 — P2 — Scripted NPC movement does not establish the expected walk presentation

**Evidence**

`test_npc_scripted_control_runtime.gd` confirms that scripted control enters `MoveToTarget` and reports `scripted_event` as its source, but the active animation is neither `walk` nor `walk_1`.

**Impact**

Cutscenes or scripted NPC actions can move with idle or missing animation even though their logical state is correct.

**Recommendation**

Trace the animation request from `request_scripted_state` through state entry and the shared animation controller. Make the movement state expose a stable semantic animation key and let the NPC-specific animation profile resolve variants such as `walk_1`.

### F-06 — P2 — Three live NPCs produce animation configuration warnings on gameplay startup

**Evidence**

The `realtest1` smoke run reports `AnimationPlayer_missing` for Dad, Maid, and Bob when requesting `idle`. Their scenes inherit `blueprint_social_npc.tscn` and provide procedural polygon visuals, but no `AnimationPlayer`.

**Impact**

The gameplay log starts noisy, and missing presentation configuration can be overlooked because the scene continues running.

**Recommendation**

Either add the intended animations, or explicitly configure these placeholder NPCs as non-animated so the controller does not treat absence as an exceptional condition. Keep a startup smoke assertion that unexpected engine/project warnings fail the build.

### F-07 — P2 — NPC state and world simulation are concentrated into two god objects

**Evidence**

`npc_state_machine.gd` is 7,698 lines; `npc_world_simulation.gd` is 6,089. Together they cover state transition policy, behavior intents, activity identity, action sessions, reservations, combat, social scoring, scripted control, animation routing, schedules, off-screen travel, meals, simulated locations, and restoration. The state machine alone contained 357 functions in the earlier static scan; the world simulation contained 239.

The current failures in F-01 and F-02 are cross-domain failures inside these modules, not isolated leaf-state bugs.

**Impact**

Changes have a large regression radius, merge conflicts are likely, dynamic invariants are difficult to prove, and narrow tests still require large fixtures.

**Recommendation**

Decompose incrementally behind existing APIs:

- Behavior arbitration and activity identity.
- Action/session lifecycle and reservations.
- Perception/social candidate collection and scoring.
- Schedule/travel planning and off-screen progression.
- Meal-cycle policy.
- Animation/presentation routing.

Keep `NpcStateMachine` as a coordinator, not the owner of every policy. Extract one seam at a time only after the failing boundary tests are green.

### F-08 — P2 — Global service lookup and dynamic dispatch weaken dependency contracts

**Evidence**

The earlier static scan found 22 autoloads, 358 `/root` string lookups, 860 `has_method` checks, and 1,932 dynamic `.call(...)` sites. The heaviest root dependencies were `NpcLocations`, `WorldTime`, `NpcWorldSimulation`, `GameplayFlow`, `DialogueController`, and `Relationships`.

**Impact**

Dependencies are implicit, misspellings and signature drift move from parse time to runtime, tests boot or fake the whole tree, and ownership boundaries are difficult to identify.

**Recommendation**

Use typed references or small typed interfaces for core gameplay paths. Inject service references into scene-level coordinators and reserve root lookup/dynamic capability detection for genuinely optional integrations. A practical first target is the relationship/identity/scoring path exposed by F-02.

### F-09 — P2 — Every test process boots the full 22-autoload application graph

**Evidence**

Even small unit-like runs load save, time, NPC routes and world simulation, relationship data, HUD scenes, ambient audio, progression catalogs, diagnostics, and player runtime. A single process commonly takes about 5–7 seconds before completing; the full first pass took nearly ten minutes.

**Impact**

Feedback is slow, failures inherit unrelated global state, and lifecycle cleanup becomes harder.

**Recommendation**

Introduce a minimal test project/profile or a single-process batch runner with explicit reset hooks. Separate pure policy tests from full-scene integration tests. Autoload only infrastructure required for a given tier, and keep a smaller number of deliberate full-application smoke tests.

### F-10 — P2 — Item catalog construction and validation are repeated across consumers

**Evidence**

`ItemCatalog.new()` plus `load_definitions()` appears in player inventory/equipment, merchant, processing, food, cooking, trade UI, inventory UI, meal simulation, loot-table validation, and NPC-spot validation. Verbose test startup shows the same item resources requested repeatedly. Godot's resource cache reduces physical decoding, but directory enumeration, validation, and dictionary construction still repeat.

**Impact**

Extra startup/test work, duplicated error handling, and multiple catalog instances that can disagree if reload behavior changes.

**Recommendation**

Provide one immutable runtime catalog or a static cached index with an explicit editor invalidation/reload path. Pass the catalog to services that need it. Keep validation as a dedicated import/build check rather than repeating full validation in every consumer instance.

### F-11 — P2 — Export presets package development tests and fixtures

**Evidence**

Both Windows and Web presets use `export_filter="all_resources"` with no exclusions. The Windows export cache contains runtime test scenes including inventory dump, loot magnet, and trade policy tests. The produced pack is approximately 26.6 MB.

**Impact**

Release packages include unnecessary test code/data, expose internal fixtures, and make it harder to know which resources are actually required by runtime content.

**Recommendation**

Exclude root `test_*` scripts, `test/`, test-only scenes/fixtures, development logs, and other diagnostics from release presets. Prefer a dependency-based resource export where practical, with explicit includes for data loaded dynamically by path.

### F-12 — P2 — Existing performance data shows intermittent frame spikes, but no current controlled benchmark

**Evidence**

The tracked historical `performance_watchdog.log` contains 29 spike records ranging from roughly 36.6 ms to 150 ms; 21 exceed 50 ms and 12 exceed 100 ms. Some coincide with scene changes, but others occur periodically in `realtest1`. Between spikes, samples are generally near 16.7 ms / 60 FPS. The watchdog is currently disabled, so the log does not establish current performance after the active changes.

**Impact**

Visible hitching is plausible, especially during transitions and periodic simulation work, but optimization based only on the old log could target the wrong code.

**Recommendation**

Create a repeatable profiling scenario with fixed save data, scene, NPC count, and simulated duration. Record frame-time percentiles and profiler hotspots before changing code. Profile time advancement, NPC need/schedule evaluation, scene activation, catalog setup, and save restoration first. Set a concrete budget such as p95/p99 frame time rather than optimizing by line count.

### F-13 — P2 — Trade UI schedules focus on controls that may be rebuilt before the deferred call

**Evidence**

`test_trade_service_runtime.gd` emits Godot's `grab_focus` error because the target is no longer inside the tree. `TradeScreen._focus_first_slot()` defers `grab_focus()` on a dynamically built inventory slot. Inventory signals can immediately call `_refresh()`, which queues the old slot for deletion and rebuilds the grid before the deferred focus executes.

**Impact**

Rapid inventory updates can produce engine errors and unreliable controller/keyboard focus.

**Recommendation**

Defer a method on the stable screen, then resolve the current slot at execution time. Guard with `is_instance_valid`, `is_inside_tree`, and visibility/focus-mode checks. Avoid retaining ephemeral slot nodes across a refresh.

### F-14 — P3 — Trade service test expectations are stale relative to current design and UI copy

**Evidence**

The same trade test expects cooked meat to sell to the player at base value 4, but `docs/economy_inventory_foundation.md` specifies directed, favor-adjusted NPC-to-player pricing. The current neutral-favor policy returns 5, and `test_trade_policy_runtime.tscn` passes with that expectation. The test also expects `Your gold: ...`, while the UI now intentionally displays `Your available gold: ...`.

**Impact**

Legitimate behavior is reported as a product regression, reducing trust in the suite.

**Recommendation**

Update the test to use the same policy contract and current copy, or assert numeric values through a view-model accessor rather than exact label prose. Retain separate tests for base value, favor multiplier, rounding, and available-versus-total currency.

### F-15 — P3 — Diagnostics configuration, documentation, and output location disagree

**Evidence**

- `DEBUG_TROUBLESHOOTING_STEPS.md` describes troubleshooting, watchdog, breadcrumbs, and preload-disable switches as current defaults, while `debug_tools_config.gd` currently disables them and enables the character-stats overlay.
- `performance_watchdog.gd` defaults its output to `res://performance_watchdog.log`; `res://` can be read-only inside an exported package.
- `.gitignore` lists `performance_watchdog.log`, but the file is already tracked, so new runtime samples can dirty or overwrite repository history.

**Impact**

Troubleshooting instructions are misleading, and release diagnostics may fail to write or modify a tracked development artifact.

**Recommendation**

Describe switch purpose instead of volatile “current defaults,” write runtime output to `user://`, and remove the already tracked log from version control after preserving any useful benchmark evidence elsewhere.

### F-16 — P3 — Project onboarding and test operation are undocumented

**Evidence**

The root `README.md` is only 38 characters and contains the title. It does not specify Godot version, startup scene, controls, directory map, data-authoring workflow, save location, export process, or test command. Detailed subsystem documents exist, but there is no entry-point map or CI configuration.

**Impact**

Architecture knowledge is discoverable only by reading code and scattered documents; future contributors can easily use the wrong test harness or violate system ownership.

**Recommendation**

Add a concise README that links to the detailed documents and records the authoritative setup/test/export commands. Add a short architecture decision record for NPC identity and behavior-transition ownership.

### F-17 — P3 — Line-ending policy is incomplete for a cross-platform Godot repository

**Evidence**

Git repeatedly warns that LF files will be replaced by CRLF when touched. `.gitattributes` only uses general text auto-detection, and `.editorconfig` does not set `end_of_line`.

**Impact**

Godot text resources can accumulate noisy diffs and merge conflicts unrelated to functional changes.

**Recommendation**

Choose one repository convention—normally LF for `.gd`, `.tscn`, `.tres`, `.godot`, and Markdown—and encode it in `.gitattributes` and `.editorconfig`. Normalize in a dedicated commit so it is not mixed with gameplay changes.

## Positive findings worth preserving

- **Data-driven content:** dialogue, NPC routes, spots, items, recipes, progression, and simulation locations use resources rather than being entirely hard-coded.
- **Transactional economy:** inventory operations, reservations, trade, processing, and save application use result objects and rollback/atomicity concepts. Failure-path coverage is substantial.
- **Explicit world ownership:** documentation and code distinguish live NPCs from off-screen simulation and identify location/route authorities.
- **Save-system care:** temporary/backup behavior and subsystem snapshots show attention to recoverability and versionable state.
- **Broad behavioral coverage:** 92 runtime tests cover inventories, trade, progression, NPC scheduling, routes, combat, dialogue, activities, ropes, loot, meals, and save-related behavior.
- **Build viability:** the current project imports and exports successfully under Godot 4.6.2, and both the title screen and a main gameplay scene survive headless smoke runs.
- **No obvious repository asset crisis:** tracked project size is modest for a game, and Godot's generated `.godot` directory is ignored.
- **Existing diagnostic thinking:** the performance watchdog and subsystem documents provide a useful basis for controlled profiling once their configuration and output path are cleaned up.

## Recommended order of work

### Phase 1 — Restore correctness and signal quality

1. Build the authoritative mixed-harness test manifest/runner and fix the hanging loot-magnet test.
2. Decide and migrate the canonical NPC/relationship identity contract.
3. Fix behavior arbitration for same-state retargeting and monster reacquisition.
4. Make loot exclusion use an explicit, injectable time domain.
5. Repair scripted animation routing and trade-screen deferred focus.
6. Update stale trade expectations and eliminate green-test shutdown leaks.

### Phase 2 — Reduce integration risk

1. Extract behavior arbitration/activity identity behind tests.
2. Extract social candidate collection/scoring with a typed identity dependency.
3. Isolate off-screen schedule/travel and meal policy from the world-simulation coordinator.
4. Add a shared immutable item catalog.
5. Reduce full-application autoload use in unit-like tests.

### Phase 3 — Establish a performance and release baseline

1. Create a deterministic gameplay benchmark and record frame-time percentiles.
2. Profile before optimizing the 69 frame callbacks or periodic NPC work.
3. Add release export exclusions and verify dynamically loaded resources.
4. Move diagnostics to `user://`, clean tracked logs, and align troubleshooting docs.
5. Add CI, README onboarding, and a consistent line-ending policy.

## Suggested acceptance criteria for the next checkpoint

- All 92 tests have declared entry points, finish within a bounded timeout, and cannot pass after a script/engine error.
- No reproducible test failures remain, with stale expectations updated only after the relevant contract is documented.
- Title and representative gameplay smoke runs emit no unexpected project warnings.
- NPC identity round-trips through live, simulated, saved, and relationship contexts.
- Same-state retarget and target-deletion transitions are atomic and covered.
- Release exports exclude test-only resources.
- A controlled benchmark records current p50, p95, p99, and worst frame times before architecture optimization begins.

## Final assessment

The project is viable and meaningfully tested, but it is at an architectural inflection point. The immediate need is not a wholesale rewrite. It is to restore deterministic integration tests and make identity and behavior-transition contracts explicit. Once those contracts are green, the very large NPC coordinators can be split safely along observed failure boundaries. That sequence will improve correctness, iteration speed, and performance visibility without discarding the strong data-driven and transactional foundations already present.
