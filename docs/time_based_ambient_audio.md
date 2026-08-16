# Time-based ambient audio

`WorldTimeAmbientAudio` keeps looping ambience synchronized to an in-game daily time window.
It reads the current `WorldTime` snapshot when entering a scene and reacts to hourly clock
boundaries, including explicit time skips.

`morning_birds.tscn` is one persistent autoload scoped to `realhometest` and `realtest1`:

- Active from `06:00` inclusive until `13:00` exclusive.
- Plays `sounds/birds.mp3` at `0.5` linear volume.
- Uses a slow `12`-second sine fade at both time boundaries and when entering the scene.
- Restarts the recording while the window remains active.
- Stops playback after the fade-out completes outside the window.
- Keeps the same playback alive, with no new fade, when transitioning between the home and yard.

`night_crickets.tscn` is a second persistent ambience across the same two scenes:

- Active from `19:00` inclusive, across midnight, until `05:00` exclusive.
- Plays `sounds/night cricket ambience.mp3` at `0.5` linear volume.
- Uses the same `12`-second fades, looping, and uninterrupted home/yard transitions.

Add another scene path to `allowed_scene_paths` to extend the same uninterrupted ambience
region. Create a separate configured player only when a different sound, time window, or
volume is required.
