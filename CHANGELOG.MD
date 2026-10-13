# Changelog
## Versions
## 0.82.2
### Aura (Modern) trigger
Changed
- **Dynamic Information set explicitly:** saving a display with an Aura (Modern) trigger now points Dynamic Information at that trigger’s number instead of trusting “first active trigger”, which resolved to another trigger whenever the aura trigger was not active and made the display ineligible (0.79.1).

### Aura (Modern) conditions
New
- **Aura Active (true / false):** Aura Present and Aura Missing are one check, “Aura Active”, with a True or False value, like Legacy’s “Trigger active”. It is offered on every Show On. Saved Aura Present / Aura Missing conditions migrate to Aura Active = True / False with their changes intact (0.80.0).
- **True styles the live aura:** Aura Active = True now offers the same look properties as False — Alpha, Color, Desaturate, Zoom, Border, Texts and the highlights — painted when the aura’s button is set up, in or out of combat. Icon stays False-only, since a live button’s icon is bound to the aura. Useful on Show On: Always to give the live aura and the missing icon different looks (0.81.0).

Changed
- **No clearing, no auto-changes:** conditions are never emptied and trigger settings are never changed to suit a condition. A check whose state is not drawn (for example Aura Active = False on Show On: Found without a fallback trigger) simply has nothing to paint (0.80.0).
- **Aura Missing on Found with a fallback:** with “When Aura (Modern) Filters Are Not Met, Use” set, the display draws while the aura is missing, so an Aura Active = False condition styles that look (0.79.2).
- **Status line:** the only remaining condition problem (a property an Aura (Modern) condition cannot apply, possible from imports only) shows as a red “Incompatible condition.” (0.79.2).

### New trigger
- **Spell → Spell in Range (Action Bar):** range of a spell that is on an action bar, against the current target, from the client’s own range-change event (`ACTION_RANGE_CHECK_UPDATE`); no per-frame polling and readable in combat. Enter the spell by name or ID (any rank on the bars counts unless Exact Spell ID is ticked); Show On: In Range, Out of Range or No Target. Spells inside macros are not seen. The existing Spell in Range and Range Check triggers are unchanged (0.82.0–0.82.2).

## 0.74.8
- LibSerialize update
- Default icon selection to "All Icons"

## 0.74.6
- SetPoint LUA error fix
- Re-fix broken spell cooldown from 0.74.4
Note: Heavy optimizations has caused a few previous updates to break Spell Cooldown; but now it's working, with the optimizations

## 0.74.4
- Global Cooldown trigger: a display that went active on the GCD stayed active after it ended; the trigger now ends itself (one scheduled check with readable timing, a brief public-flag poll in combat).
- Further performance improvements
- Modern Auras draw by slot instead of by group
- The Missing look of a Show On Always/Missing display is refreshed on unit changes again (regression from 0.74.0: icon vanishing after de-target, flicker on re-target).
- Re-fix certain Modern Aura trigger combinations after the large optimizations.

## 0.74.0
Performance
- Entering and leaving combat: the spell cooldown re-check that a restriction change triggers is now spread over several frames and starts the frame after the change, instead of refreshing every cooldown icon in the frame the client is already busy with. Spells with their own event (a cast) are still checked immediately.
- Cooldown data is read once per frame per spell and shared between the trigger, the swipe, the text and conditions (the cooldown APIs are slow on this client); the cache is invalidated by cooldown and wand events so a fresh cooldown shows immediately.
- Spell name and icon lookups are cached and refreshed when spells change.
- Talent data is cached instead of re-read from the trait tree on every query. This fixes the multi-second freeze when opening the Load tab of a large group.
- Display updates that only changed a load state or a unit now batch their dynamic-group re-sorting instead of re-sorting once per child.
- Aura data copies, condition templates and the loaded-events table are cached; duplicate client events in one frame (unit flags, usability, action bar updates) are handled once.
- Modern (native) aura displays redraw less: containers are only enabled, shown or re-parented when that actually changes, and the appearance refresh only touches displays whose state changed.
- Frame-anchored displays no longer re-parent, re-strata and re-level themselves on every update when nothing changed.
- Fewer per-frame refreshes from global cooldown updates out of combat.

Fixes
- GCD and wand Shoot text no longer appears on cooldown icons while wanding; GCD-length timers are classified by total duration with a haste- and wand-speed-aware threshold.
- A cooldown that starts during the global cooldown (Fire Blast after a cast) now updates immediately instead of after the GCD ends.
- Cooldown-ready events no longer fire for spells that merely came off the global cooldown, which stopped false “ready” pulses in combat.
- Login errors from an event registration that does not exist on this client.
- Minimap button icon fits its border.

## 0.72.4
- Fixed the Talent load option's picker piling icons together in rare situations: talents now sit on a tidy grid, separate trees side by side, with a dark background
- Add Humanoid Form
- Stance/Form/Aura has a new Form option that lists every class’s forms. You can build form triggers without knowing the forms yourself, and they work on any character.
- In that Form list, entries are grouped by class, and Bear Form also matches Dire Bear Form.
- The old option is now “Form (Bar Position)”. Imported auras no longer show an empty dropdown.
- Removed copies of FojjiCore icons from ForeverAuras, so the download is smaller.
- ForeverAuras now keeps loading when another addon ships a stricter shared library (e.g. the latest BugSack).
- If ForeverAuras can’t finish loading, it now says so once and leaves your auras untouched.
- Updated LibSharedMedia-3.0 to the latest release.
- Removed a sound that was listed but never included.

## 0.70.38
- Fix for Lib-SharedMedia update
- Removed a sound that was listed but never included

## 0.70.35
- Fixed clones of a display stacking on top of each other in Modern Aura Groups.

## 0.70.34
- Fixed auras in Modern Aura Groups drawing above other windows regardless of their strata setting.
- Fixed spell cooldown timer text sometimes showing blank with "Show GCD text" off.
- Fixed `%p` not showing on Aura (Modern) bars, progress textures and texts that use Total Duration or Remaining Time.
- Sorting Wording on Aura (Modern) Group
- Fixed timer text missing on buffs in Modern Aura Groups that sort across displays.
- Only auras that look identical are now drawn together when sorting across displays.

## 0.70.29
- Fixed spell cooldown timer text sometimes showing blank.
- Timer text now uses ForeverAuras' own formatting whenever the time is readable, which is always the case out of combat.
- A failed Blizzard text format now shows an empty text instead of erroring.
- Saved wand-shot timers are now cleared when entering or leaving combat.

## 0.70.28
- Fixed: in a centered Modern Aura Group, Aura (Modern) icons could sit 1 pixel off from other icons at some group positions.
- Fixed: in the options preview, Aura (Modern) icons in a centered Modern Aura Group could sit 1 pixel off with odd icon sizes.
- Fixed: a display removed from a sorted Modern Aura Group could keep the group’s merged filters until /reload.
- Fixed: Modern Aura Groups anchored to unit frames could try to move protected frames in combat.
- Fixed: a spell could be treated as still on cooldown after it was briefly unavailable.
- Fixed: border copies could follow the wrong border after elements were reordered.
- Fixed: a hidden helper frame could be recreated repeatedly when the game refused it.
- Fixed: turning off Limit in combat could hide the row until combat ended.

## 0.70.26
- Fixed: in a centered Modern Aura Group, Aura (Modern) icons could sit 1 pixel off from the other icons at some group positions.
- Fixed: Show On Cooldown spell displays could disappear when entering combat during a global cooldown.
- Fixed: Thrown was missing from the weapon item types in triggers and Load options.
- Fixed: Alpha and Color set by an already-true condition were reset to default after combat when the aura also had a Health or Power condition.
- Fixed: in a Modern Aura Group, displays with a Stack Count or Total Duration filter kept their place in the row even when hidden, which could push other icons past the Limit.
- Fixed: Aura (Modern) icons and normal icons in a Modern Aura Group could sit 1 pixel apart or look blurry, depending on the group’s position and how many icons were shown.
- Fixed: Show On Missing, Remaining Time, Total Duration and Stack Count icons could look blurry at some positions, including with Limit on.
- Fixed: pixel-perfect borders on normal icons in a Modern Aura Group are now drawn exactly like the icon’s own border.
- Removed: the "Secure frame detected" warning on displays in a Modern Aura Group that contains clickable displays.
- Improved: lower CPU use for spell cooldown displays in combat, cooldown event handling, Aura (Modern) unit events, and unit frame scanning.

## 0.70.12
- Possible Masque fix

## 0.70.11
- Performance Improvements
- Fix Offsets Appearing on Modern Groups
- Backend fixes

## 0.70.3
- Fix remaining time text condition coloring

## 0.70.1
- Normal auras (icons and texts) in Modern Aura Groups now line up anywhere in the row, in and out of combat, including with Centered growth.
- Clickable auras in Modern Aura Groups keep working.
- Limit now cuts off the whole row after that many icons, normal auras included, with every growth, in combat and in the options preview.
- Out-of-combat auras leaving as combat starts no longer push a centered row off-centre.
- Remaining Time conditions on cooldowns and casts can change Alpha and Color in combat.
- Timer texts can be coloured in several steps, and hidden or shown by Remaining Time, in combat too.
- Old and Modern Blizzard time formats now work on restricted timers.
- "Secret detected" is no longer shown for conditions that work in combat.
- Fixed duplicate text and "Aura is Off Screen" in Modern Aura Group previews.
- Fixed texts copied into a row being cut short with "...".
- Fixed several Lua errors and blocked actions in combat in Modern Aura Groups with Remaining Time or clickable auras.
- Less work when texts in a Modern Aura Group change size.

## 0.64.5
- Small fix for Previews in the Modern (Aura) Group

## 0.64.4
- Added Old Blizzard (2h | 3m | 10s) and Modern Blizzard (1h 3m | 3m 7s | 10s) time formats for %p on Aura (Modern) displays
- Round Up now applies to the Old Blizzard format
- Remaining Time Aura (Modern) icons now show their swipe

## 0.64.1
Modern Aura Group
- Displays hidden by other triggers no longer break the row. The row closes the gap, in and out of combat.
- Normal (non-Modern) auras can now be in a Modern Aura Group. They lead the row, followed by the Aura (Modern) displays.
- New Sort dropdown, like a Dynamic Group's: None, Ascending, Descending, plus Blizzard's own sort options. Any sort except None puts Aura(s) Found displays with the same unit and filters into one sorted row.
- Clearer warnings when an aura can't join the row.
- Remaining Time now works in a Modern Aura Group (except Grid): an icon only takes space in the row while its time-left condition is met, in and out of combat.

Power and Health
- Power and Health filters that can never work in combat are removed from the trigger, but they can still be used in Conditions.
- Conditions on Power and Health values can change Alpha and Color, in and out of combat.
- Max Health and Max Power filters work for the player.
- Combo Points filters work in combat.
- Power types now match WoW Forever classes only.
- Absorb, heal absorb and incoming heal overlays no longer draw wrong values.

Fixes
- Character Stats triggers now update in combat.
- Cooldown icons re-saturate when a cooldown ends in combat.
- Fixed a "script ran too long" error when opening options with many auras.
- Fixed the class icon showing twice in load conditions.
- Fixed Pixel Glow running counter-clockwise.
- A newly added Alpha condition change now has a default value.

## 0.60.2
- Character Stats trigger is now properly functional throughout
- Fixed Pixel Glow growing in the incorrect direction

## 0.59.1
- Fixed spells sharing cooldown updating slow
- Aura (Modern) now has Ignore Dead and Ignore Disconnected
- Health trigger has all its options back: Health, Health (%), Deficit, Max Health, Absorbs, Incoming Heal and the unit filters
- Health and Power triggers now show color-coded text for what you've selected: green works in combat, orange only out of combat (use a Condition), red never works on the trigger
- Health, Health (%) and Health Deficit can be used in Conditions to change Alpha and Color in combat

## 0.57.0
- Power and Health (%) can now be used in Conditions in combat, to change Alpha and Color.

**Note**: The game hides power and health values from addons in combat, so the trigger itself can't react to them but conditions can, and they keep the aura working the way you'd expect. Power filters on the trigger only work out of combat. For in-combat checks, use a Condition instead.

## 0.56.6
- Power and Health triggers now work in combat: filters fade the aura out instead of hiding it
- Power and Health conditions can now change Alpha and Color in combat
- Health trigger has Health (%) again
- Power and Health triggers show what works and doesn't work in combat, based on your settings
- Aura (Modern) extra textures now show with Remaining Time
- Modern Aura Groups now accept Progress Bars, Progress Textures and Texts
- Aura(s) Missing and Always now work on Smart Group, Party, Raid and nameplates when anchored to unit frames or nameplates
- Missing icons on unit frames now draw above the frame
- Aura (Modern) now has Include Pets (Players and Pets / Pets only)
- Fix Pixel Glow stuttering and reversing
- Faster login and /reload: Aura (Modern) displays now build right after the loading screen
- New /fa loadtime command shows what slowed down your login
- Fix spell cooldowns being checked constantly after combat
- Fix a possible error with Stagger in combat
- General fixes and performance improvements for logging in or reloading during combat
- Minor style changes

## 0.50.3
- Add Weapon Charges for Show Always Weapon Enchant Trigger
- Importing auras from other game versions kept talent data loaded in the backend. This will now retro-fix talent data stored with Auras, and properly clear them when importing from other versions.
- Fix Fire Totems not being picked up by the Totem Trigger
- You can now use a Modern Aura as a secondary trigger, and use its %s and %p text to display to another trigger
- Aura (Legacy) picks up name again
- You can now use Grid as an option in Modern Aura Groups.
- Adding **NON** Modern Aura trigger sources to Modern Aura Groups will now display a warning. It is only intended for purely Modern Aura driven triggers to be placed in Modern Aura groups.
- Icon changes

## 0.44.2
- Added Pixel Perfect Border option to Group Borders
- Pixel Perfect Borders is default on for New Auras
- When entering lots of spell IDs into a single Aura, we only display 20, with a "Show All" button. This improves performance throughout the addon window.

## 0.44.0
- Fix Health values being displayed as Text
- Totem Trigger is functional again, and works in Combat
- Backend tweaks

## 0.43.19
- Yet more wand fixes affecting other events
- Saturation wand fixes
- Multi-frame processing on combat drop for performance
- Allow ForeverAuras.SetSpellCooldownState
- Fix "Own Only" for Aura (Modern).
- Own Only: Include Vehicle -> Renamed to Own Only
- Previous Own Only -> Renamed to Cast by a Player

## 0.43.11
- Many backend optimizations
- Wand handling optimizations
- SPELL_COOLDOWN_READY fixes

## 0.43.7
- Fixed spell cooldown ready

## 0.43.5-BETA
- Add warnings to Player/Unit Info -> Cast triggers
- Fix Spell Cooldown Ready Event trigger. Now works in combat

## 0.43.0-BETA
- Add specific unit to Aura (Modern)

## 0.42.11
- Fixed centered horizontal anchoring for Auras that are not the same size
- Added Layout / Font settings to the top right, allowing you to change
- Linking Auras in Chat now reads the Information tab, takes the URL, and creates a shareable HREF with it. If no URL is present in Information, sharing is not possible.

## 0.41.11
- Performance optimizations for CDM / Modern Aura triggers

## 0.41.8
- Model fix for Tooltip
- Model fixes
- Nameplate edit optimizations
- Small wording improvements
- Added the ability to fallback to other Triggers for display and dynamic information purposes, when the filters for your Modern Aura are not met. This is big and re-enables many WeakAuras magic!
- Lots of fixes to Progress Bars, Textures
- Fix Stack Count Leak
- Enable Aura (Modern) on Text & Textures
- Fix Blizzard CDM Text _sometimes_ appearing at a strange anchored point.
- Fix Multi Rank Support for CDM
- Aura (Modern) fixes

## 0.35.1
- Added Stack Count, Remaining Time to Aura (Modern) for available triggers
- Lua Error fixes
- Condition improvements
- Add "Show if Unit Doesnt Exist" for Aura (Modern) for Target/Focus/Target of Target/Target of Focus
- Add new condition for Aura Missing for Aura (Modern) - Allows for desaturating
- Added warning when trying to use any other text other than hardcoded, %p, %s and %n on an Aura (Modern)
- Fix anchoring of Smart Group / Party / Raid for Modern Aura
- Fix Player/Unit Info Target Trigger firing when Secret

## 0.28.1
- Fix LUA error involving secretive text

## 0.28.0
- Add Spell - Spell in Range trigger

## 0.27.1
- Re-added range features

## 0.26.6
New: Modern Aura Group
- New group type for Aura (Modern) displays. Use this group when using Aura (Modern)
- Missing and Always displays keep their place in the flow
- Aura (Blizzard) renamed to Aura (Modern)
- Can be placed in Dynamic Groups again, with a warning that growth may be limited
- Swipe Color moved to the end of the Icon settings
- Aura (Modern) Settings are hidden inside a Modern Aura Group, which handles layout instead
- Aura (Modern) Settings and Swipe Color now apply to all selected displays
- Glow type and padding options now work when several displays are selected
- Paste Display now copies Aura (Modern) settings and sort
- Smoother combat end: queued updates are spread across frames
- Fewer unit refreshes on combat and restriction changes
- Modern Aura Group re-anchors once per event
- Sounds only re-register when changed
- Fewer rebuilds during combat
- Sliders no longer rebuild the whole options panel
- Fixed an error when anchoring Missing displays inside a group
- Fixed the group preview box appearing in the wrong spot
- Fixed off-centre layout in centered growth
- Fixed the anchor selector not being clickable

## 0.22.1
New
- **Show On:** Aura(s) Found, Aura(s) Missing or Always, laid out like Aura (Legacy). Missing and Always work on Icon displays for Player, Target, Focus, Pet, Target of Target and Target of Focus.
- **Remaining Time filter:** show the aura only while its time left is in a range (for example, less than 5 seconds). Icon displays only.
- **Total Duration filter** (=, <= or >=): filter auras by their full duration.
  - <= works on every display type and replaces the old Maximum Duration option. Existing settings carry over.
  - = and >= work on Icon displays only.
- **Approximate Match** for Debuffs on Player, Pet, Smart Group, Party and Raid, which Blizzard hides from spell ID filters in combat. Enable this to attempt to display filtered spell ID debuffs on the aforementioned units.
- **Dynamic Groups:** Aura (Blizzard) displays can now be placed in Dynamic Groups when they watch one unit. You still cannot place Smart Group, Party, Raid etc into dynamic groups, but you can Anchor to Unit Frames, Nameplates, and control their Growth direction under the Display tab.
- **Glow elements:** Action Button Glow, Pixel Glow, Autocast Shine and Proc Glow all animate on Aura (Blizzard) displays, in and out of combat.
- **Glow in the last seconds:** turn a Glow on with a "Remaining Time < X" condition, or with the Remaining Time filter.
- **Status line:** the trigger shows whether your selection works in combat.
  - Green: it works.
  - Orange: it works with a limit.
  - Red: it won't work, with the reason.
- **Desaturate while missing:** a new display option for the Missing icon.

Changed
- **Preview notice:** the "won't display in combat" notice only appears for selections Blizzard always refuses. It no longer appears for spells Blizzard never hides, or when Approximate Match is on.
- **Sounds note:** when spell ID filtering won't work, the status line says that sounds set in Actions still play.
- **Time inputs:** Remaining Time, Total Duration and Aura Duration accept a decimal comma (for example 1,5).

Known limitations
- With Total Duration = or >=, or Approximate Match on an Icon, the countdown text shows as the swipe's own countdown numbers. It keeps your text's font, colour, position and format.
- With Total Duration = or >=, auras that match are drawn on top of each other in one spot.
- Approximate Match can also match a different Debuff with the same duration and dispel type.

Fixes
- **Dynamic Group error:** fixed a Lua error when a Dynamic Group positioned an Aura (Blizzard) display.
- **Spanish (Mexico) error:** fixed a Lua error when opening a Stop Motion element's options on esMX clients.
- **Translations:** fixed Simplified Chinese, Traditional Chinese and Russian texts that left out a name they should show.

## 0.13.5
- Fixed Spell Cooldown conditions checking the wrong spell rank. Range, usability and insufficient-resource checks now follow the rank being tracked, even if you entered a higher rank you haven’t learned yet. Exact Spell ID settings are still respected.

## 0.13.4
- Combined Blizzard CDM Essential and Utility into one **Cooldown** trigger. Spells are detected in either category, and existing triggers convert automatically while preserving their settings.
- Fixed delayed GCD refreshes on **Spell → Cooldown/Charges/Count**.
- Fixed **Spell → Global Cooldown** trigger
- Added optional **class-pack CDM setup** function: ForeverAuras.SetupClassPackCDM
- When called, it enables CDM, populates Tracked Buffs, sets viewer visibility to Always, and enables ForeverAuras’ **Hide Blizzard’s CDM** option.
- Extended setup to restore hidden spell cooldowns to Essential or Utility while preserving already-displayed spell placements and excluding item entries from this step.
- Setup waits until out of combat, preserves unrelated settings, backs up the original configuration, and prompts for a reload when required.
- Added **Item → Ammo** trigger type.
- Supports count conditions and optional comma-separated item IDs. Leaving the filter blank counts all carried ammo; bank storage is excluded.
- Added restriction warnings for supported trigger checks and Legacy Aura spell IDs.
- Standardised the warning to one red line: **“Secret detected. Some features may be restricted in combat.”**
- Removed the old Health explanation and extra warning headings.
- Added progress texture support for restricted health, power and Blizzard Aura timers.
- Simplified spell ID tooltips and missing-rank messages.
- Fixed stale CDM state keeping removed or expired debuffs visible.
- Buff observers now attach when triggers are configured, before their first activation.
- Fixed valid spell cooldowns being skipped in “Not Displayed” because they contained buff-slot metadata.

## 0.8.6
- Fixed wand cooldown text and unwanted icon desaturation for Spell and CDM cooldown triggers. Enabled automatically.
- Improved temporary weapon-enchant and imbue detection, icons, equipment updates and expiry handling.
- Preserved observed weapon-enchant swipe duration through zoning.
- Added pulsing border and glow styles for supported Blizzard Aura highlight conditions.
- Added anchoring support for Ellesmere nameplate health bars.
- Fixed automatic text placement when text dimensions are restricted.
- Fixed restricted GUID handling in unit-name coloring.

## 0.7.1
Thanks [Anouhschka](https://github.com/Anouhschka)!
- Fixed errors when selecting invalid or forbidden frames as anchors.
- Fixed the frame picker confirming a previously hovered frame.
- Prevented the frame picker from selecting the ForeverAuras options window.
- Preserved texture and font-string anchoring when “Set Parent” is disabled.

## 0.7.0
- Dispel Type Indicator sub-element is now "Dispel Type Icon" and "Dispel Type Border", and the visuals on the border have been corrected.

## 0.6.21
- Performance Fixes
- Conditioning Aura Highlight fixes for Blizzard Aura
- Aspect Ratio / Zoom fixes for Blizzard Aura

## 0.6.12
- Fix GCD text issues once and for all, including in combat
- Fix Spell Cooldown "On Cooldown" conditioning
- Fix Debuffs via CDM on Target Swipe / Text showing "0"

## 0.6.0
- Fix Shadow Text Offsets
- Fix Dispel Indicator display for Blizzard Aura Trigger
- Add Spell -> Queued Action Trigger
- Add Condition for Spell Usable (when readable) to CDM Trigger
- Add Specialization Load condition for Forever - Note this is only activated when the last talent for each Specialization is known.

## 0.3.3
- Fix Spell ID Integration from iterating and causing crashes

## 0.2.1
- Fix previews of Blizzard CDM / Blizzard Aura Trigger
- Using the Blizzard Aura trigger, you can now add spell IDs using just one spell ID to match all names, similar to Aura (Legacy) logic
- Blizzard Aura Triggers "Force Perfect Pixel Border" is now usable
- Remove warning about being unable to save auras

## 0.1.217
- Added remaining time to CDM Buff/Debuff

## 0.1.212
- Fix Name multi matching Buff/Debuff CDM Trigger

## 0.1.210
- Fix CDM Trigger Combat handler
- Add Spell in Range condition

## 0.1.203
- Substantial performance fix for Blizzard CDM Trigger
- Fixed fonts not displaying on first click
- Fix multi select conditioning
- Fix group select -> conditions

## 0.1.196
Improved the functionality of the Aura (Blizzard) trigger
- Added Name(s) and Exact Spell ID filter options
- Added allowed conditions for Blizzard Auras
- Improved wording

Improved the functionality of the Blizzard Cooldown Manager Trigger
- GCD Features now properly work
- By default, adding a spell into CDM will not display if you do not know the spell
- Added "Disable Spell Known Check"
- Added Name(s) and Exact Spell ID filter options

Misc fixes
- Fix several backend APIs
- Fix text being blank on Client Notice

## 0.1.180
- Improved Blizzard Aura integration

## 0.1.168
- Minor fixes for CDM

## 0.1.165
- Minor fixes for CDM Previews
- Rename CDM Trigger Dropdowns

## 0.1.161
- Fix spell cost overlay ignoring borders

## 0.1.160
- Blizzard Cooldown Manager trigger fixes.
- No longer use AuraContainer at all.

## 0.1.148
- Added new Trigger type "Blizzard Cooldown Manager"
- Added option to Hide Blizzards CDM.
- Note, the Blizzard CDM needs to be enabled for the trigger to work. If using these triggers in your Aura, the intended design is to enable the Hide Blizzard CDM option.

## 0.1.114
First released version to Curseforge for WoW Forever Beta
- Change anchor prefix from `WeakAuras:` to `ForeverAuras:`
- Fix EnchantIDs for Weapons
- Add Client save warning
- Add ItemStatus.lua
- Spelling fixes

## 0.1.103
- Add function to check if a SpellID is secret
- Change addon icon
- Remove CC warnings for other addons

## 0.1.101
- Remove "Secret Aura" type and move Blizzard controlled auras under the regular auras section on the trigger tab

## 0.1.94
- Add Private Auras warnings for Blizzard controlled auras

## 0.1.90
- Initial Repo commit after fork and adjustment of [WeakAuras2](https://github.com/WeakAuras/WeakAuras2/releases/tag/5.22.0)