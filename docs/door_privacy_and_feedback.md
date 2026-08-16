# Private door access and feedback

Mom's bedroom and the occupied bathroom keep access policy in the existing door APIs.
Presentation is handled separately by `locked_door_feedback.gd`.

## Access ownership

- `MomBedroomDoor.owner_ids` controls Player access to the bedroom. Its `route_edge`
  remains the independent authority for scheduled NPC travel.
- `HallBathroomInteriorDoor.allow_player` is updated only after Mom's
  `passage_completed` event, with her position relative to the door determining the side.
- Bathroom state is reconciled from the live Mom node. It is not saved independently.

## Locked feedback component

Each private door has a `LockedDoorFeedback` scene node configured with:

- `door_path`: the access-authoritative door.
- `interaction_area_path`: the area used to track nearby Players.
- `feedback_text`: the floating message shown after an attempted locked interaction.

The component registers as a normal interaction candidate but is eligible only while the
door denies the Player. It consumes the attempted interaction, creates one world-space
label above the Player, then rises, fades, and frees that label. It never grants passage
or changes door access.

The complete text-and-sound presentation lives in the reusable `LockedDoorCue` helper. Any
gameplay interaction can show the same cue with:

`LockedDoorCue.show(player)`

It plays only the first `0.5` seconds of `sounds/locked door.mp3` and replaces any cue already
attached to that Player.
`show_custom()` exposes the message, offset, size, color, duration, hold time, rise distance,
sound, and volume without duplicating presentation code. The lower-level
`FloatingPlayerFeedback.show()` remains available for messages that should not play a sound.

When supporting another door implementation, extend only `_door_is_locked_for()` and keep
the door itself authoritative. Do not duplicate access state in the feedback component.

## Narrative side-room door

The unused painted door immediately before the bathroom is represented by
`LockedSideRoomDoor`. Its `fake_scene_door.gd` interaction deliberately has no scene target:
it starts the shared modal dialogue `locked_side_room` and leaves the current scene intact.
The interacting Player is attached to that dialogue session, so the shared `ui_only` control
claim blocks movement and combat until the line closes. The same interaction also calls the
shared floating feedback helper with `Door locked.` The interaction area is aligned to the
background door at `(528, 368)`.
